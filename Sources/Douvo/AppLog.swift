import Foundation

enum AppLog {
    private static let writer = AppLogWriter()

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Logs/Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var fileURL: URL {
        let directory = directoryURL
        return directory.appendingPathComponent("douvo.log")
    }

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(level: String, message: String) {
        writer.write(level: level, message: message)
    }
}

private final class AppLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Douvo.AppLogWriter", qos: .utility)
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?
    private var isUsingFallbackHandle = false

    func write(level: String, message: String) {
        queue.async { [self] in
            let timestamp = formatter.string(from: Date())
            let line = "\(timestamp) [\(level)] \(message)\n"
            print(line, terminator: "")

            guard let data = line.data(using: .utf8) else { return }
            let handle = logHandle()
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                closeHandle()
            }
        }
    }

    private func logHandle() -> FileHandle {
        if let handle {
            return handle
        }

        let url = AppLog.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            self.handle = handle
            isUsingFallbackHandle = false
            return handle
        }

        let fallback = FileHandle.standardError
        handle = fallback
        isUsingFallbackHandle = true
        return fallback
    }

    private func closeHandle() {
        guard let handle, !isUsingFallbackHandle else {
            self.handle = nil
            isUsingFallbackHandle = false
            return
        }
        try? handle.close()
        self.handle = nil
        isUsingFallbackHandle = false
    }
}
