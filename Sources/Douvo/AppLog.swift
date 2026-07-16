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
    // 单个日志文件上限为 1 MB，超出后触发轮转
    private static let maxFileBytes: UInt64 = 1 * 1024 * 1024
    private static let maxArchivedFiles = 3

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
            do {
                rotateIfNeeded(pendingByteCount: data.count)
                let handle = logHandle()
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

    private func rotateIfNeeded(pendingByteCount: Int) {
        guard !isUsingFallbackHandle else { return }
        let url = AppLog.fileURL
        let size = fileSize(at: url)
        guard size > 0, size + UInt64(pendingByteCount) > Self.maxFileBytes else { return }

        closeHandle()
        rotateFiles()
    }

    private func rotateFiles() {
        let fileManager = FileManager.default

        for index in stride(from: Self.maxArchivedFiles, through: 1, by: -1) {
            let sourceURL = rotatedFileURL(index)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            if index == Self.maxArchivedFiles {
                try? fileManager.removeItem(at: sourceURL)
            } else {
                let destinationURL = rotatedFileURL(index + 1)
                try? fileManager.removeItem(at: destinationURL)
                try? fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        let currentURL = AppLog.fileURL
        guard fileManager.fileExists(atPath: currentURL.path) else {
            fileManager.createFile(atPath: currentURL.path, contents: nil)
            return
        }

        if let data = tailData(from: currentURL) {
            try? data.write(to: rotatedFileURL(1), options: .atomic)
        }
        try? fileManager.removeItem(at: currentURL)
        fileManager.createFile(atPath: currentURL.path, contents: nil)
    }

    private func rotatedFileURL(_ index: Int) -> URL {
        AppLog.directoryURL.appendingPathComponent("douvo.\(index).log")
    }

    private func fileSize(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private func tailData(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let readSize = min(size, Self.maxFileBytes)
            try handle.seek(toOffset: size - readSize)
            return try handle.read(upToCount: Int(readSize)) ?? Data()
        } catch {
            return nil
        }
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
