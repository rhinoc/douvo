import Foundation

final class RecentAudioRecorder {
    private static let sampleRate = 16_000
    private static let channelCount = 1
    private static let bitsPerSample = 16
    private static let maxRecordingCount = 3

    private let lock = NSLock()
    private let fileURL: URL
    private let handle: FileHandle
    private var audioByteCount = 0
    private var isFinished = false

    static var directoryURL: URL {
        AppLog.directoryURL.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func start() -> RecentAudioRecorder? {
        let directory = directoryURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(filenameTimestamp()).wav")
            FileManager.default.createFile(atPath: url.path, contents: wavHeader(dataByteCount: 0))
            let handle = try FileHandle(forUpdating: url)
            try handle.seekToEnd()
            AppLog.info("Audio debug recording started path=\(url.path)")
            return RecentAudioRecorder(fileURL: url, handle: handle)
        } catch {
            AppLog.error("Audio debug recording start failed error=\(error.localizedDescription)")
            return nil
        }
    }

    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        do {
            try handle.write(contentsOf: pcm)
            audioByteCount += pcm.count
        } catch {
            AppLog.error("Audio debug recording write failed error=\(error.localizedDescription)")
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let byteCount = audioByteCount
        lock.unlock()

        do {
            if byteCount == 0 {
                try handle.close()
                try? FileManager.default.removeItem(at: fileURL)
                AppLog.info("Audio debug recording discarded empty path=\(fileURL.path)")
                return
            }

            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(dataByteCount: byteCount))
            try handle.close()
            Self.pruneOldRecordings()
            AppLog.info("Audio debug recording saved path=\(fileURL.path) bytes=\(byteCount)")
        } catch {
            try? handle.close()
            AppLog.error("Audio debug recording finish failed path=\(fileURL.path) error=\(error.localizedDescription)")
        }
    }

    private init(fileURL: URL, handle: FileHandle) {
        self.fileURL = fileURL
        self.handle = handle
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func pruneOldRecordings() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "wav" }

            let sorted = urls.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent > rhs.lastPathComponent
                }
                return lhsDate > rhsDate
            }

            for url in sorted.dropFirst(maxRecordingCount) {
                try FileManager.default.removeItem(at: url)
                AppLog.info("Audio debug recording pruned path=\(url.path)")
            }
        } catch {
            AppLog.error("Audio debug recording prune failed error=\(error.localizedDescription)")
        }
    }

    private static func wavHeader(dataByteCount: Int) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let chunkSize = 36 + dataByteCount

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.appendUInt32LE(UInt32(chunkSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(UInt16(channelCount))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(UInt16(blockAlign))
        data.appendUInt16LE(UInt16(bitsPerSample))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.appendUInt32LE(UInt32(dataByteCount))
        return data
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
