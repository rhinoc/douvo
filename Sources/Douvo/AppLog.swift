import Foundation

enum AppLog {
    private static let lock = NSLock()

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Logs/Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("douvo.log")
    }

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"
        print(line, terminator: "")

        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }
}
