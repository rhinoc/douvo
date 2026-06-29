import Foundation

enum LogExportStore {
    private static let maxExportCount = 5

    static var directoryURL: URL {
        let directory = AppLog.directoryURL.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func export() throws -> URL {
        let fileManager = FileManager.default
        let stamp = timestamp()
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent("douvo-log-export-\(stamp)", isDirectory: true)
        let zipURL = directoryURL.appendingPathComponent("douvo-logs-\(stamp).zip")

        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        try copyLogs(to: stagingURL)
        try copyDirectoryContentsIfPresent(
            from: AppLog.directoryURL.appendingPathComponent("Traces", isDirectory: true),
            to: stagingURL.appendingPathComponent("Traces", isDirectory: true),
            allowedExtensions: ["json"]
        )
        try copyDirectoryContentsIfPresent(
            from: ASRErrorDiagnosticStore.directoryURL,
            to: stagingURL.appendingPathComponent("ASRErrors", isDirectory: true),
            allowedExtensions: ["json"]
        )
        try copyBundledDemoAudio(to: stagingURL.appendingPathComponent("DemoAudio", isDirectory: true))
        try writeDiagnostics(to: stagingURL)
        try writeManifest(to: stagingURL, createdAt: stamp)

        try? fileManager.removeItem(at: zipURL)
        try zipDirectory(stagingURL, to: zipURL)
        pruneOldExports()
        AppLog.info("Log export created path=\(zipURL.path)")
        return zipURL
    }

    private static func copyLogs(to stagingURL: URL) throws {
        let fileManager = FileManager.default
        let destination = stagingURL.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let urls = (try? fileManager.contentsOfDirectory(
            at: AppLog.directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls where isAppLogFile(url) {
            try copyFile(url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }

    private static func copyDirectoryContentsIfPresent(
        from source: URL,
        to destination: URL,
        allowedExtensions: Set<String>
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let urls = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for url in urls where allowedExtensions.contains(url.pathExtension.lowercased()) {
            try copyFile(url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }

    private static func writeDiagnostics(to stagingURL: URL) throws {
        let webDebugInfo = ASRParamsStore.loginDebugInfo() ?? """
        Douvo Login Debug Info
        hasRequiredAuthCookies: false
        paramsPath: missing
        logPath: \(AppLog.fileURL.path)
        """
        let diagnostics = [
            webDebugInfo,
            DoubaoAndroidCredentialStore.debugInfo()
        ].joined(separator: "\n\n")
        try diagnostics.data(using: .utf8)?.write(
            to: stagingURL.appendingPathComponent("login-diagnostics.txt"),
            options: .atomic
        )
    }

    private static func copyBundledDemoAudio(to destination: URL) throws {
        guard let source = Bundle.module.url(forResource: "ASRDemo", withExtension: "aiff") else { return }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyFile(source, to: destination.appendingPathComponent(source.lastPathComponent))
    }

    private static func writeManifest(to stagingURL: URL, createdAt: String) throws {
        let payload: [String: Any] = [
            "created_at": isoTimestamp(),
            "export_id": createdAt,
            "app_version": appVersion,
            "selected_asr_provider": ASRProviderStore.selected.rawValue,
            "included": [
                "Logs/douvo.log and rotated douvo.*.log files",
                "Traces/*.json",
                "ASRErrors/*.json",
                "DemoAudio/*.aiff synthetic demo clips",
                "login-diagnostics.txt"
            ],
            "excluded": [
                "Recordings audio files",
                "PromptSnapshots prompt/transcript snapshots",
                "credential secret values and raw cookies"
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: stagingURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func zipDirectory(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "Douvo.LogExport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Failed to create log export zip"]
            )
        }
    }

    private static func pruneOldExports() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "zip" }

            let sorted = urls.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent > rhs.lastPathComponent
                }
                return lhsDate > rhsDate
            }

            for url in sorted.dropFirst(maxExportCount) {
                try FileManager.default.removeItem(at: url)
                AppLog.info("Log export pruned path=\(url.path)")
            }
        } catch {
            AppLog.error("Log export prune failed error=\(error.localizedDescription)")
        }
    }

    private static func copyFile(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func isAppLogFile(_ url: URL) -> Bool {
        if url.lastPathComponent == "douvo.log" { return true }
        return url.lastPathComponent.hasPrefix("douvo.") && url.pathExtension.lowercased() == "log"
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [version, build].compactMap { $0 }.joined(separator: " ")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
