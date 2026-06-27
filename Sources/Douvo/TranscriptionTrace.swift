import Foundation

struct TraceTiming: Sendable {
    let name: String
    let milliseconds: Int
    let metadata: [String: String]

    init(
        name: String,
        milliseconds: Int,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.milliseconds = milliseconds
        self.metadata = metadata
    }
}

struct LocalLLMPostprocessResult: Sendable {
    let text: String
    let timings: [TraceTiming]
    let metadata: [String: String]
    let debugInfo: LocalLLMPostprocessDebugInfo
}

struct LocalLLMPostprocessDebugInfo: Sendable {
    let systemPrompt: String?
    let userPrompt: String?
    let rawResponse: String?
    let cleanedResponse: String?
}

@MainActor
final class TranscriptionTrace {
    private struct Event {
        let name: String
        let elapsedMilliseconds: Int
        let metadata: [String: String]
    }

    private let id = UUID().uuidString
    private let startedAt = Date()
    private let startedAtUptime = ProcessInfo.processInfo.systemUptime
    private var metadata: [String: String] = [:]
    private var spanStarts: [String: TimeInterval] = [:]
    private var timings: [TraceTiming] = []
    private var events: [Event] = []
    private var isFinished = false

    func set(_ key: String, _ value: CustomStringConvertible?) {
        guard let value else { return }
        metadata[key] = String(describing: value)
    }

    func event(
        _ name: String,
        metadata: [String: String] = [:]
    ) {
        guard !isFinished else { return }
        events.append(Event(
            name: name,
            elapsedMilliseconds: Self.milliseconds(since: startedAtUptime),
            metadata: metadata
        ))
    }

    func startSpan(_ name: String) {
        guard !isFinished else { return }
        spanStarts[name] = ProcessInfo.processInfo.systemUptime
    }

    func finishSpan(
        _ name: String,
        metadata: [String: String] = [:]
    ) {
        guard !isFinished, let started = spanStarts.removeValue(forKey: name) else { return }
        addTiming(name, milliseconds: Self.milliseconds(since: started), metadata: metadata)
    }

    func addTiming(
        _ name: String,
        milliseconds: Int,
        metadata: [String: String] = [:]
    ) {
        guard !isFinished else { return }
        timings.append(TraceTiming(name: name, milliseconds: milliseconds, metadata: metadata))
    }

    func addTimings(_ timings: [TraceTiming]) {
        for timing in timings {
            addTiming(timing.name, milliseconds: timing.milliseconds, metadata: timing.metadata)
        }
    }

    func finish(
        outcome: String,
        metadata finishMetadata: [String: String] = [:]
    ) {
        guard !isFinished else { return }
        for (name, started) in spanStarts {
            timings.append(TraceTiming(
                name: name,
                milliseconds: Self.milliseconds(since: started),
                metadata: ["unfinished": "true"]
            ))
        }
        spanStarts.removeAll()
        isFinished = true

        var payloadMetadata = metadata
        for (key, value) in finishMetadata {
            payloadMetadata[key] = value
        }

        let payload: [String: Any] = [
            "trace_id": id,
            "type": "transcription",
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "outcome": outcome,
            "duration_ms": Self.milliseconds(since: startedAtUptime),
            "metadata": payloadMetadata,
            "timings": timings.map(Self.payload(for:)),
            "events": events.map(Self.payload(for:))
        ]

        if let traceURL = TraceFileStore.write(payload: payload, prefix: "transcription") {
            AppLog.info("TRACE transcription file=\(traceURL.path)")
        }
        AppLog.info("TRACE transcription \(Self.jsonString(payload))")
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func payload(for timing: TraceTiming) -> [String: Any] {
        [
            "name": timing.name,
            "duration_ms": timing.milliseconds,
            "metadata": timing.metadata
        ]
    }

    private static func payload(for event: Event) -> [String: Any] {
        [
            "name": event.name,
            "at_ms": event.elapsedMilliseconds,
            "metadata": event.metadata
        ]
    }

    private static func jsonString(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

enum TraceFileStore {
    static var directoryURL: URL {
        let directory = AppLog.directoryURL.appendingPathComponent("Traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(payload: [String: Any], prefix: String) -> URL? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }

        let fileURL = directoryURL.appendingPathComponent("\(timestamp())-\(prefix).json")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            AppLog.error("Trace file write failed path=\(fileURL.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
