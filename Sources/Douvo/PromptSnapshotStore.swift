import Foundation

actor PromptSnapshotStore {
    static let shared = PromptSnapshotStore()

    private var lastSignature: String?
    private let maxSnapshots = 3

    private var directoryURL: URL {
        let directory = AppLog.directoryURL.appendingPathComponent("PromptSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func saveIfChanged(systemPrompt: String, userPrompt: String) {
        let signature = "\(systemPrompt)\n\u{1E}\n\(userPrompt)"
        guard signature != lastSignature else {
            return
        }
        lastSignature = signature

        let timestamp = Self.timestamp()
        let fileURL = directoryURL.appendingPathComponent("\(timestamp).txt")
        let content = """
        # Effective System Prompt

        \(systemPrompt)

        # Effective User Prompt

        \(userPrompt)
        """

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            pruneSnapshots()
            AppLog.info("Local LLM prompt snapshot saved path=\(fileURL.path)")
        } catch {
            AppLog.error("Local LLM prompt snapshot failed error=\(error.localizedDescription)")
        }
    }

    private func pruneSnapshots() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let snapshots = urls
            .filter { $0.pathExtension == "txt" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for url in snapshots.dropFirst(maxSnapshots) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
