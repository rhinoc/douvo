import Foundation

enum ASRErrorDiagnosticStore {
    private static let maxFiles = 3

    static var directoryURL: URL {
        let directory = AppLog.directoryURL.appendingPathComponent("ASRErrors", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(payload: [String: Any], provider: String, reason: String) -> URL? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            AppLog.error("ASR error diagnostic skipped: invalid payload")
            return nil
        }

        let safeProvider = filenameSegment(provider)
        let safeReason = filenameSegment(reason)
        let fileURL = directoryURL.appendingPathComponent("\(timestamp())-\(safeProvider)-\(safeReason).json")

        do {
            try data.write(to: fileURL, options: .atomic)
            pruneOldFiles()
            AppLog.info("ASR error diagnostic saved path=\(fileURL.path)")
            return fileURL
        } catch {
            AppLog.error("ASR error diagnostic write failed path=\(fileURL.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func pruneOldFiles() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }

            let sorted = urls.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent > rhs.lastPathComponent
                }
                return lhsDate > rhsDate
            }

            for url in sorted.dropFirst(maxFiles) {
                try FileManager.default.removeItem(at: url)
                AppLog.info("ASR error diagnostic pruned path=\(url.path)")
            }
        } catch {
            AppLog.error("ASR error diagnostic prune failed error=\(error.localizedDescription)")
        }
    }

    private static func filenameSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let segment = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return segment.isEmpty ? "unknown" : String(segment.prefix(48))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
