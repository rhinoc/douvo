import Foundation

enum AndroidASRResponseType {
    case taskStarted
    case sessionStarted
    case sessionFinished
    case recognition(ASRRecognitionResult)
    case heartbeat
    case error(String, [String: String])
    case unknown
}

struct AndroidASRResponse {
    let type: AndroidASRResponseType
}

final class DoubaoAndroidASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum State: String, Sendable {
        case idle
        case connecting
        case open
        case finishing
        case finished
        case disconnected
        case failed
    }

    private static let webSocketURL = URL(string: "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws")!
    private static let webSocketHost = webSocketURL.host ?? "unknown"
    private static let aid = "401734"
    private static let userAgent = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
    private static let frameDurationMillis: Int64 = 20
    private static let finishSessionDrainQuietMillis = 300
    private static let finishSessionDrainMaxMillis = 1_200

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var state: State = .idle
    private var credentials: DoubaoAndroidCredentials?
    private var requestID = ""
    private var pendingAudio: [Data] = []
    private var queuedAudio: [Data] = []
    private var isSendingAudio = false
    private var finishRequested = false
    private var finishFramesSent = false
    private var drainingResultsBeforeFinishSession = false
    private var finishSessionSent = false
    private var finishSessionDrainQuietWork: DispatchWorkItem?
    private var finishSessionDrainMaxWork: DispatchWorkItem?
    private var frameIndex: Int64 = 0
    private var startedAtMillis: Int64 = 0
    private var receivedMessageCount = 0
    private var recognitionMessageCount = 0
    private var queuedAudioCount = 0
    private var pendingAudioCount = 0
    private var summaryLogged = false
    private var pendingAudioSamples: [String] = []
    private var queuedAudioSamples: [String] = []
    private var sentFrameSamples: [String] = []
    private var recognitionSamples: [String] = []
    private var transcriptAssembler = AndroidASRTranscriptAssembler()
    private let lock = NSLock()
    private static let maxSummarySamples = 12

    var onOpen: (() -> Void)?
    var onResult: ((ASRRecognitionResult) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((Error?) -> Void)?
    var onAuthError: (() -> Void)?

    func connect(credentials: DoubaoAndroidCredentials) {
        var components = URLComponents(url: Self.webSocketURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: Self.aid),
            URLQueryItem(name: "device_id", value: credentials.deviceId)
        ]
        guard let url = components.url else {
            onError?(nil)
            return
        }

        requestID = UUID().uuidString
        startedAtMillis = Self.currentTimeMillis()

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")
        // URLSessionWebSocketTask owns the protocol handshake headers
        // (Connection, Upgrade, Sec-WebSocket-*). Keep these client-visible
        // headers aligned with the Web ASR request shape.
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 8

        let socket = session.webSocketTask(with: request)
        lock.lock()
        self.credentials = credentials
        task = socket
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        isSendingAudio = false
        finishRequested = false
        finishFramesSent = false
        drainingResultsBeforeFinishSession = false
        finishSessionSent = false
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainQuietWork = nil
        finishSessionDrainMaxWork?.cancel()
        finishSessionDrainMaxWork = nil
        frameIndex = 0
        receivedMessageCount = 0
        recognitionMessageCount = 0
        queuedAudioCount = 0
        pendingAudioCount = 0
        summaryLogged = false
        pendingAudioSamples.removeAll(keepingCapacity: true)
        queuedAudioSamples.removeAll(keepingCapacity: true)
        sentFrameSamples.removeAll(keepingCapacity: true)
        recognitionSamples.removeAll(keepingCapacity: true)
        transcriptAssembler.reset()
        state = .connecting
        lock.unlock()

        AppLog.info("Android ASR connect begin deviceIdSet=\(!credentials.deviceId.isEmpty)")
        socket.resume()
        receive()
        sendStartTask()
    }

    func sendAudio(_ data: Data) {
        lock.lock()
        if finishFramesSent {
            lock.unlock()
            return
        }

        if state == .open || state == .finishing {
            queuedAudio.append(data)
            queuedAudioCount += 1
            if Self.shouldSampleProgress(queuedAudioCount) {
                Self.appendSummarySample("\(queuedAudioCount):queued=\(queuedAudio.count):bytes=\(data.count)", to: &queuedAudioSamples)
            }
            let shouldStartSending = !isSendingAudio
            lock.unlock()
            if shouldStartSending {
                sendNextAudio()
            }
        } else if state == .connecting {
            pendingAudio.append(data)
            pendingAudioCount += 1
            if Self.shouldSampleProgress(pendingAudioCount) {
                Self.appendSummarySample("\(pendingAudioCount):bytes=\(data.count)", to: &pendingAudioSamples)
            }
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    func finishSending() {
        lock.lock()
        finishRequested = true
        if state == .connecting {
            let pendingCount = pendingAudio.count
            lock.unlock()
            AppLog.info("Android ASR finish deferred until session opens pendingAudio=\(pendingCount)")
            return
        }
        if state == .open {
            state = .finishing
        }
        movePendingAudioToQueueLocked()
        let shouldStartSending = !isSendingAudio && (state == .open || state == .finishing)
        lock.unlock()

        if shouldStartSending {
            sendNextAudio()
        }
    }

    func disconnect() {
        lock.lock()
        state = .disconnected
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        isSendingAudio = false
        finishRequested = false
        finishFramesSent = false
        drainingResultsBeforeFinishSession = false
        finishSessionSent = false
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainQuietWork = nil
        finishSessionDrainMaxWork?.cancel()
        finishSessionDrainMaxWork = nil
        lock.unlock()

        task?.cancel(with: .normalClosure, reason: "1000-".data(using: .utf8))
        task = nil
        AppLog.info("Android ASR disconnected")
        logSummary(reason: "disconnect")
    }

    private func sendStartTask() {
        guard let task, let credentials else { return }
        let payload = AndroidASRProtobuf.request(
            token: credentials.token,
            methodName: "StartTask",
            payload: "",
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        task.send(.data(payload)) { [weak self] error in
            if let error {
                AppLog.error("Android ASR StartTask send failed error=\(error.localizedDescription)")
                self?.markFailed(error)
            }
        }
    }

    private func sendStartSession() {
        guard let task, let credentials else { return }
        let config: [String: Any] = [
            "audio_info": [
                "channel": 1,
                "format": "speech_opus",
                "sample_rate": 16000
            ],
            "enable_punctuation": true,
            "enable_speech_rejection": false,
            "extra": [
                "app_name": "com.android.chrome",
                "cell_compress_rate": 8,
                "did": credentials.deviceId,
                "enable_asr_threepass": true,
                "enable_asr_twopass": true,
                "input_mode": "tool"
            ]
        ]
        let payloadData = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        let payload = String(data: payloadData, encoding: .utf8) ?? "{}"
        let message = AndroidASRProtobuf.request(
            token: credentials.token,
            methodName: "StartSession",
            payload: payload,
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        task.send(.data(message)) { [weak self] error in
            if let error {
                AppLog.error("Android ASR StartSession send failed error=\(error.localizedDescription)")
                self?.markFailed(error)
            }
        }
    }

    private func markOpen() {
        lock.lock()
        if state == .connecting {
            state = finishRequested ? .finishing : .open
        }
        let flushedCount = movePendingAudioToQueueLocked()
        let finishWasRequested = finishRequested
        let shouldStartSending = !isSendingAudio && (state == .open || state == .finishing)
        lock.unlock()

        AppLog.info("Android ASR session opened flushedAudio=\(flushedCount) finishRequested=\(finishWasRequested)")
        onOpen?()
        if shouldStartSending {
            sendNextAudio()
        }
    }

    @discardableResult
    private func movePendingAudioToQueueLocked() -> Int {
        let count = pendingAudio.count
        guard count > 0 else { return 0 }
        queuedAudio.append(contentsOf: pendingAudio)
        pendingAudio.removeAll()
        return count
    }

    private func sendNextAudio() {
        lock.lock()
        guard !isSendingAudio, (state == .open || state == .finishing), let socket = task else {
            lock.unlock()
            return
        }

        guard !queuedAudio.isEmpty else {
            let shouldSendFinish = finishRequested && !finishFramesSent
            if shouldSendFinish {
                finishFramesSent = true
            }
            lock.unlock()
            if shouldSendFinish {
                sendFinishFrames(socket: socket)
            }
            return
        }

        let audio = queuedAudio.removeFirst()
        let isFirst = frameIndex == 0
        let timestamp = startedAtMillis + frameIndex * Self.frameDurationMillis
        frameIndex += 1
        isSendingAudio = true
        let message = AndroidASRProtobuf.request(
            token: "",
            methodName: "TaskRequest",
            payload: #"{"extra":{},"timestamp_ms":\#(timestamp)}"#,
            audioData: audio,
            requestID: requestID,
            frameState: isFirst ? 1 : 3
        )
        lock.unlock()

        socket.send(.data(message)) { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.error("Android ASR audio send failed error=\(error.localizedDescription)")
                self.markFailed(error)
                return
            }
            self.lock.lock()
            self.isSendingAudio = false
            let sentFrameCount = self.frameIndex
            if Self.shouldSampleProgress(Int(sentFrameCount)) {
                Self.appendSummarySample("\(sentFrameCount)", to: &self.sentFrameSamples)
            }
            self.lock.unlock()
            self.sendNextAudio()
        }
    }

    private func sendFinishFrames(socket: URLSessionWebSocketTask) {
        guard let credentials else { return }
        let timestamp = startedAtMillis + frameIndex * Self.frameDurationMillis
        let lastFrame = AndroidASRProtobuf.request(
            token: "",
            methodName: "TaskRequest",
            payload: #"{"extra":{},"timestamp_ms":\#(timestamp)}"#,
            audioData: Data(repeating: 0, count: 100),
            requestID: requestID,
            frameState: 9
        )
        socket.send(.data(lastFrame)) { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.error("Android ASR last frame send failed error=\(error.localizedDescription)")
                self.markFailed(error)
                self.logSummary(reason: "last_frame_failed")
                return
            }
            self.beginFinishSessionResultDrain(socket: socket, credentials: credentials)
        }
    }

    private func beginFinishSessionResultDrain(
        socket: URLSessionWebSocketTask,
        credentials: DoubaoAndroidCredentials
    ) {
        lock.lock()
        guard state == .finishing, !finishSessionSent else {
            lock.unlock()
            return
        }
        drainingResultsBeforeFinishSession = true
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainMaxWork?.cancel()
        let quietWork = DispatchWorkItem { [weak self] in
            self?.sendFinishSessionIfNeeded(
                socket: socket,
                credentials: credentials,
                reason: "result_drain_quiet"
            )
        }
        let maxWork = DispatchWorkItem { [weak self] in
            self?.sendFinishSessionIfNeeded(
                socket: socket,
                credentials: credentials,
                reason: "result_drain_max"
            )
        }
        finishSessionDrainQuietWork = quietWork
        finishSessionDrainMaxWork = maxWork
        lock.unlock()

        AppLog.info("Android ASR final frame sent; draining results before FinishSession quietMs=\(Self.finishSessionDrainQuietMillis) maxMs=\(Self.finishSessionDrainMaxMillis)")
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.finishSessionDrainQuietMillis),
            execute: quietWork
        )
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.finishSessionDrainMaxMillis),
            execute: maxWork
        )
    }

    private func rescheduleFinishSessionDrainQuietIfNeeded() {
        lock.lock()
        guard let socket = task,
              let credentials,
              state == .finishing,
              drainingResultsBeforeFinishSession,
              !finishSessionSent else {
            lock.unlock()
            return
        }
        finishSessionDrainQuietWork?.cancel()
        let quietWork = DispatchWorkItem { [weak self] in
            self?.sendFinishSessionIfNeeded(
                socket: socket,
                credentials: credentials,
                reason: "result_drain_quiet"
            )
        }
        finishSessionDrainQuietWork = quietWork
        lock.unlock()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.finishSessionDrainQuietMillis),
            execute: quietWork
        )
    }

    private func sendFinishSessionIfNeeded(
        socket: URLSessionWebSocketTask,
        credentials: DoubaoAndroidCredentials,
        reason: String
    ) {
        lock.lock()
        guard state == .finishing,
              drainingResultsBeforeFinishSession,
              !finishSessionSent else {
            lock.unlock()
            return
        }
        drainingResultsBeforeFinishSession = false
        finishSessionSent = true
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainQuietWork = nil
        finishSessionDrainMaxWork?.cancel()
        finishSessionDrainMaxWork = nil
        lock.unlock()

        AppLog.info("Android ASR sending FinishSession reason=\(reason)")
        let finish = AndroidASRProtobuf.request(
            token: credentials.token,
            methodName: "FinishSession",
            payload: "",
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        socket.send(.data(finish)) { [weak self] error in
            if let error {
                AppLog.error("Android ASR FinishSession send failed error=\(error.localizedDescription)")
                self?.logSummary(reason: "finish_session_failed")
                self?.markFailed(error)
            } else {
                AppLog.info("Android ASR FinishSession sent")
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.lock()
                self.receivedMessageCount += 1
                let count = self.receivedMessageCount
                self.lock.unlock()

                if case .data(let data) = message {
                    self.handleResponse(AndroidASRProtobuf.parseResponse(data), count: count)
                }
                self.receive()
            case .failure(let error):
                if !self.isExpectedClose(error) {
                    AppLog.error("Android ASR receive failed error=\(error.localizedDescription)")
                    self.logSummary(reason: "receive_failed")
                    self.onError?(self.asrError(error, stage: "receive_failed"))
                } else {
                    self.logSummary(reason: "receive_ended")
                }
            }
        }
    }

    private func handleResponse(_ response: AndroidASRResponse, count: Int) {
        switch response.type {
        case .taskStarted:
            AppLog.info("Android ASR TaskStarted")
            sendStartSession()
        case .sessionStarted:
            markOpen()
        case .sessionFinished:
            markFinished()
            AppLog.info("Android ASR SessionFinished")
            logSummary(reason: "finish")
            onFinish?()
        case .recognition(let result):
            let assembledResult = transcriptAssembler.update(with: result)
            lock.lock()
            recognitionMessageCount += 1
            let recognitionCount = recognitionMessageCount
            if Self.shouldSampleProgress(recognitionCount) {
                Self.appendSummarySample(
                    "\(count):chars=\(assembledResult.text.count):kind=\(assembledResult.kind):segments=\(assembledResult.segmentCount):assembled=\(assembledResult.metadata["android_assembled_segments"] ?? "0")",
                    to: &recognitionSamples
                )
            }
            lock.unlock()
            onResult?(assembledResult)
            if assembledResult.isFinal {
                sendFinishSessionAfterPreFinishFinalIfNeeded()
            } else {
                rescheduleFinishSessionDrainQuietIfNeeded()
            }
        case .heartbeat:
            break
        case .error(let message, let responseMetadata):
            markFailed(nil, notify: false)
            AppLog.error("Android ASR error message=\(message)")
            logSummary(reason: "server_error")
            if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("token") {
                onAuthError?()
            } else {
                onError?(asrError(
                    description: message,
                    code: 3,
                    stage: "server_error",
                    responseMetadata: responseMetadata
                ))
            }
        case .unknown:
            break
        }
    }

    private func markFinished() {
        lock.lock()
        state = .finished
        drainingResultsBeforeFinishSession = false
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainQuietWork = nil
        finishSessionDrainMaxWork?.cancel()
        finishSessionDrainMaxWork = nil
        lock.unlock()
    }

    private func markFailed(_ error: Error?, notify: Bool = true) {
        lock.lock()
        state = .failed
        isSendingAudio = false
        drainingResultsBeforeFinishSession = false
        finishSessionDrainQuietWork?.cancel()
        finishSessionDrainQuietWork = nil
        finishSessionDrainMaxWork?.cancel()
        finishSessionDrainMaxWork = nil
        lock.unlock()
        if notify {
            onError?(asrError(error, stage: "transport_failed"))
        }
    }

    private func asrError(_ error: Error?, stage: String) -> Error? {
        guard let error else { return nil }
        let nsError = error as NSError
        var metadata = diagnosticMetadata(stage: stage)
        metadata["source_domain"] = nsError.domain
        metadata["source_code"] = String(nsError.code)
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: nsError.localizedDescription,
                TranscriptionErrorMetadata.userInfoKey: metadata
            ]
        )
    }

    private func asrError(
        description: String,
        code: Int,
        stage: String,
        responseMetadata: [String: String]
    ) -> Error {
        var metadata = diagnosticMetadata(stage: stage)
        for (key, value) in responseMetadata {
            metadata[key] = value
        }
        return NSError(
            domain: "Douvo.AndroidASR",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: description.isEmpty ? "Android recognition server error" : description,
                TranscriptionErrorMetadata.userInfoKey: metadata
            ]
        )
    }

    private func diagnosticMetadata(stage: String) -> [String: String] {
        lock.lock()
        let currentState = state.rawValue
        let currentRequestID = requestID
        let pendingCount = pendingAudio.count
        let queuedCount = queuedAudio.count
        let sentFrames = frameIndex
        let receivedCount = receivedMessageCount
        let recognitionCount = recognitionMessageCount
        lock.unlock()

        return [
            "android_stage": stage,
            "android_endpoint_host": Self.webSocketHost,
            "android_request_id": currentRequestID,
            "android_state": currentState,
            "android_pending_audio_count": String(pendingCount),
            "android_queued_audio_count": String(queuedCount),
            "android_sent_frames": String(sentFrames),
            "android_received_messages": String(receivedCount),
            "android_recognition_messages": String(recognitionCount)
        ]
    }

    private func sendFinishSessionAfterPreFinishFinalIfNeeded() {
        lock.lock()
        guard let socket = task,
              let credentials,
              state == .finishing,
              drainingResultsBeforeFinishSession,
              !finishSessionSent else {
            lock.unlock()
            return
        }
        lock.unlock()

        sendFinishSessionIfNeeded(
            socket: socket,
            credentials: credentials,
            reason: "server_final"
        )
    }

    private func isExpectedClose(_ error: Error) -> Bool {
        lock.lock()
        let currentState = state
        lock.unlock()
        if currentState == .finished || currentState == .disconnected { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func logSummary(reason: String) {
        lock.lock()
        guard !summaryLogged else {
            lock.unlock()
            return
        }
        summaryLogged = true
        let state = state.rawValue
        let pendingCount = pendingAudio.count
        let queuedCount = queuedAudio.count
        let pendingTotal = pendingAudioCount
        let queuedTotal = queuedAudioCount
        let sentFrames = frameIndex
        let receivedCount = receivedMessageCount
        let recognitionCount = recognitionMessageCount
        let pendingSamples = Self.formatSamples(pendingAudioSamples)
        let queuedSamples = Self.formatSamples(queuedAudioSamples)
        let sentSamples = Self.formatSamples(sentFrameSamples)
        let resultSamples = Self.formatSamples(recognitionSamples)
        lock.unlock()

        AppLog.info("Android ASR summary reason=\(reason) state=\(state) pending=\(pendingCount) queued=\(queuedCount) pendingAudio=\(pendingTotal) queuedAudio=\(queuedTotal) sentFrames=\(sentFrames) receivedMessages=\(receivedCount) recognitionMessages=\(recognitionCount) pendingSamples=\(pendingSamples) queuedSamples=\(queuedSamples) sentSamples=\(sentSamples) recognitionSamples=\(resultSamples)")
    }

    private static func shouldSampleProgress(_ count: Int) -> Bool {
        count == 1 || count % 50 == 0
    }

    private static func appendSummarySample(_ sample: String, to samples: inout [String]) {
        if samples.count < Self.maxSummarySamples {
            samples.append(sample)
        } else {
            samples[Self.maxSummarySamples - 1] = "...\(sample)"
        }
    }

    private static func formatSamples(_ samples: [String]) -> String {
        "[\(samples.joined(separator: ","))]"
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct AndroidASRTranscriptAssembler {
    private var committedSegments: [ASRRecognitionSegment] = []
    private var activeSegment: ASRRecognitionSegment?
    private var activeRewriteCount = 0
    private var activeCommitCount = 0
    private var overlappedSegmentUpdateCount = 0

    mutating func reset() {
        committedSegments.removeAll(keepingCapacity: true)
        activeSegment = nil
        activeRewriteCount = 0
        activeCommitCount = 0
        overlappedSegmentUpdateCount = 0
    }

    mutating func update(with result: ASRRecognitionResult) -> ASRRecognitionResult {
        guard !result.segments.isEmpty else { return result }

        for segment in result.segments.sorted(by: segmentSort) {
            if segment.isFinal {
                handleFinal(segment)
            } else {
                handleInterim(segment)
            }
        }

        var visibleSegments = committedSegments
        if let activeSegment {
            visibleSegments.append(activeSegment)
        }
        var metadata = result.metadata
        metadata["android_assembled_segments"] = String(visibleSegments.count)
        metadata["android_assembled_segment_ids"] = visibleSegments.map(\.id).joined(separator: ",")
        metadata["android_assembled_segment_final_count"] = String(committedSegments.count)
        metadata["android_ime_committed_segments"] = String(committedSegments.count)
        metadata["android_ime_active_segment_id"] = activeSegment?.id ?? ""
        metadata["android_ime_active_range"] = segmentRange(activeSegment)
        metadata["android_ime_active_chars"] = String(activeSegment?.text.count ?? 0)
        metadata["android_ime_committed_chars"] = String(joinedSegmentText(committedSegments.map(\.text)).count)
        metadata["android_ime_active_rewrite_count"] = String(activeRewriteCount)
        metadata["android_ime_active_commit_count"] = String(activeCommitCount)
        metadata["android_overlapped_segment_update_count"] = String(overlappedSegmentUpdateCount)

        return .android(
            text: joinedSegmentText(visibleSegments.map(\.text)),
            kind: result.kind,
            segmentCount: result.segmentCount,
            isFinal: result.isFinal,
            metadata: metadata,
            segments: visibleSegments
        )
    }

    private mutating func handleInterim(_ incoming: ASRRecognitionSegment) {
        guard let active = activeSegment else {
            activeSegment = incoming
            return
        }

        if isSlidingForward(existing: active, incoming: incoming) {
            activeSegment = segmentWithID(mergedSlidingWindow(existing: active, incoming: incoming), id: active.id)
            activeRewriteCount += 1
            if active.id != incoming.id {
                overlappedSegmentUpdateCount += 1
            }
            return
        }

        if isSameActiveWindow(active, incoming) {
            activeSegment = segmentWithID(preferredActiveSegment(existing: active, incoming: incoming), id: active.id)
            activeRewriteCount += 1
            if active.id != incoming.id {
                overlappedSegmentUpdateCount += 1
            }
            return
        }

        if isAfterOrAdjacent(incoming, active) {
            commitActive()
            activeSegment = incoming
            return
        }

        activeSegment = preferredActiveSegment(existing: active, incoming: incoming)
        activeRewriteCount += 1
    }

    private mutating func handleFinal(_ incoming: ASRRecognitionSegment) {
        guard let active = activeSegment else {
            commit(incoming)
            return
        }

        if isSlidingForward(existing: active, incoming: incoming) {
            commit(segmentWithID(mergedSlidingWindow(existing: active, incoming: incoming), id: active.id))
            activeSegment = nil
            if active.id != incoming.id {
                overlappedSegmentUpdateCount += 1
            }
            return
        }

        if isSameActiveWindow(active, incoming) {
            let finalSegment = preferredFinalSegment(existing: active, incoming: incoming)
            commit(segmentWithID(finalSegment, id: active.id))
            activeSegment = nil
            if active.id != incoming.id {
                overlappedSegmentUpdateCount += 1
            }
            return
        }

        if isAfterOrAdjacent(incoming, active) {
            commitActive()
            commit(incoming)
            return
        }

        if active.text.count > incoming.text.count * 2 {
            commitActive()
            commit(incoming)
        } else {
            commit(incoming)
            activeSegment = nil
        }
    }

    private mutating func commitActive() {
        guard let activeSegment else { return }
        commit(activeSegment)
        self.activeSegment = nil
    }

    private mutating func commit(_ segment: ASRRecognitionSegment) {
        committedSegments.append(segmentWithID(segment, id: segment.id))
        activeCommitCount += 1
    }

    private func isSlidingForward(
        existing: ASRRecognitionSegment,
        incoming: ASRRecognitionSegment
    ) -> Bool {
        guard isSameIndexedTimeline(existing, incoming),
              significantOverlap(existing, incoming) != nil,
              let existingStart = existing.startTime,
              let existingEnd = existing.endTime,
              let incomingStart = incoming.startTime,
              let incomingEnd = incoming.endTime else {
            return false
        }
        return incomingStart > existingStart && incomingEnd > existingEnd
    }

    private func isSameActiveWindow(
        _ existing: ASRRecognitionSegment,
        _ incoming: ASRRecognitionSegment
    ) -> Bool {
        if existing.id == incoming.id { return true }
        guard isSameIndexedTimeline(existing, incoming) else { return false }
        return significantOverlap(existing, incoming) != nil
    }

    private func isAfterOrAdjacent(
        _ incoming: ASRRecognitionSegment,
        _ existing: ASRRecognitionSegment
    ) -> Bool {
        guard let existingEnd = existing.endTime,
              let incomingStart = incoming.startTime else {
            return false
        }
        return incomingStart >= existingEnd
    }

    private func isSameIndexedTimeline(
        _ existing: ASRRecognitionSegment,
        _ incoming: ASRRecognitionSegment
    ) -> Bool {
        switch (existing.index, incoming.index) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func significantOverlap(
        _ existing: ASRRecognitionSegment,
        _ incoming: ASRRecognitionSegment
    ) -> Int? {
        guard let existingStart = existing.startTime,
              let existingEnd = existing.endTime,
              let incomingStart = incoming.startTime,
              let incomingEnd = incoming.endTime,
              existingEnd > existingStart,
              incomingEnd > incomingStart else {
            return nil
        }

        let overlap = min(existingEnd, incomingEnd) - max(existingStart, incomingStart)
        guard overlap > 0 else { return nil }

        let shorterDuration = min(existingEnd - existingStart, incomingEnd - incomingStart)
        guard shorterDuration > 0 else { return nil }
        return overlap * 2 >= shorterDuration ? overlap : nil
    }

    private func preferredActiveSegment(
        existing: ASRRecognitionSegment,
        incoming: ASRRecognitionSegment
    ) -> ASRRecognitionSegment {
        if existing.isFinal { return existing }
        if incoming.text.count >= existing.text.count { return incoming }
        return existing
    }

    private func preferredFinalSegment(
        existing: ASRRecognitionSegment,
        incoming: ASRRecognitionSegment
    ) -> ASRRecognitionSegment {
        if incoming.startTime == existing.startTime { return incoming }
        if incoming.text.count * 10 >= existing.text.count * 6 { return incoming }
        return existing
    }

    private func mergedSlidingWindow(
        existing: ASRRecognitionSegment,
        incoming: ASRRecognitionSegment
    ) -> ASRRecognitionSegment {
        ASRRecognitionSegment(
            id: existing.id,
            text: mergedSlidingText(existing.text, incoming.text),
            index: existing.index ?? incoming.index,
            startTime: existing.startTime ?? incoming.startTime,
            endTime: incoming.endTime ?? existing.endTime,
            isFinal: incoming.isFinal
        )
    }

    private func mergedSlidingText(_ existing: String, _ incoming: String) -> String {
        if existing.contains(incoming) { return existing }
        if incoming.contains(existing) { return incoming }

        let existingChars = Array(existing)
        let incomingChars = Array(incoming)
        let maxOverlap = min(existingChars.count, incomingChars.count)
        guard maxOverlap > 0 else {
            return appendSegment(incoming, to: existing)
        }

        for overlap in stride(from: maxOverlap, through: 4, by: -1) {
            if Array(existingChars.suffix(overlap)) == Array(incomingChars.prefix(overlap)) {
                return String(existingChars + incomingChars.dropFirst(overlap))
            }
        }

        return appendSegment(incoming, to: existing)
    }

    private func segmentWithID(_ segment: ASRRecognitionSegment, id: String) -> ASRRecognitionSegment {
        ASRRecognitionSegment(
            id: id,
            text: segment.text,
            index: segment.index,
            startTime: segment.startTime,
            endTime: segment.endTime,
            isFinal: segment.isFinal
        )
    }

    private func segmentRange(_ segment: ASRRecognitionSegment?) -> String {
        guard let segment,
              let start = segment.startTime,
              let end = segment.endTime else {
            return ""
        }
        return "\(start)-\(end)"
    }

    private func segmentSort(_ lhs: ASRRecognitionSegment, _ rhs: ASRRecognitionSegment) -> Bool {
        switch (lhs.index, rhs.index) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        default:
            break
        }

        switch (lhs.startTime, rhs.startTime) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        default:
            break
        }

        switch (lhs.endTime, rhs.endTime) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        default:
            return lhs.id < rhs.id
        }
    }

    private func joinedSegmentText(_ segments: [String]) -> String {
        segments.reduce("") { output, segment in
            appendSegment(segment, to: output)
        }
    }

    private func appendSegment(_ segment: String, to output: String) -> String {
        guard !output.isEmpty else { return segment }
        guard let last = output.last, let first = segment.first else {
            return output + segment
        }
        if last.isWhitespace || first.isWhitespace || Self.sentenceEndingCharacters.contains(last) {
            return output + segment
        }
        if isCJK(last), isCJK(first) {
            return output + segment
        }
        return output + " " + segment
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static let sentenceEndingCharacters = Set<Character>("。！？.!?")
}

enum AndroidASRProtobuf {
    static func request(
        token: String,
        methodName: String,
        payload: String,
        audioData: Data,
        requestID: String,
        frameState: Int
    ) -> Data {
        var data = Data()
        if !token.isEmpty {
            appendString(token, fieldNumber: 2, to: &data)
        }
        appendString("ASR", fieldNumber: 3, to: &data)
        appendString(methodName, fieldNumber: 5, to: &data)
        if !payload.isEmpty {
            appendString(payload, fieldNumber: 6, to: &data)
        }
        if !audioData.isEmpty {
            appendBytes(audioData, fieldNumber: 7, to: &data)
        }
        appendString(requestID, fieldNumber: 8, to: &data)
        if frameState != 0 {
            appendVarint(UInt64(frameState), fieldNumber: 9, to: &data)
        }
        return data
    }

    static func parseResponse(_ data: Data) -> AndroidASRResponse {
        var messageType = ""
        var statusMessage = ""
        var resultJSON = ""
        var fieldNumbers = Set<Int>()
        var unknownFieldNumbers = Set<Int>()
        var index = data.startIndex

        while index < data.endIndex {
            guard let key = readVarint(data, index: &index) else { break }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)
            fieldNumbers.insert(fieldNumber)
            switch (fieldNumber, wireType) {
            case (4, 2):
                messageType = readString(data, index: &index) ?? ""
            case (6, 2):
                statusMessage = readString(data, index: &index) ?? ""
            case (7, 2):
                resultJSON = readString(data, index: &index) ?? ""
            default:
                unknownFieldNumbers.insert(fieldNumber)
                skip(wireType: wireType, data: data, index: &index)
            }
        }

        let responseMetadata = [
            "android_response_bytes": String(data.count),
            "android_response_message_type": messageType,
            "android_response_status_chars": String(statusMessage.count),
            "android_response_result_json_bytes": String(resultJSON.utf8.count),
            "android_response_fields": fieldNumbers.sorted().map(String.init).joined(separator: ","),
            "android_response_unknown_fields": unknownFieldNumbers.sorted().map(String.init).joined(separator: ",")
        ]

        switch messageType {
        case "TaskStarted":
            return AndroidASRResponse(type: .taskStarted)
        case "SessionStarted":
            return AndroidASRResponse(type: .sessionStarted)
        case "SessionFinished":
            return AndroidASRResponse(type: .sessionFinished)
        case "TaskFailed", "SessionFailed":
            return AndroidASRResponse(type: .error(statusMessage, responseMetadata))
        default:
            break
        }

        guard !resultJSON.isEmpty else {
            return AndroidASRResponse(type: .unknown)
        }

        guard let recognition = parseRecognitionResultJSON(resultJSON) else {
            return AndroidASRResponse(type: .heartbeat)
        }

        return AndroidASRResponse(type: .recognition(recognition))
    }

    static func parseRecognitionResultJSON(_ resultJSON: String) -> ASRRecognitionResult? {
        guard let jsonData = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }

        var segments: [ASRRecognitionSegment] = []
        var resultKeys = Set<String>()
        var indices: [String] = []
        var startTimes: [String] = []
        var endTimes: [String] = []
        var timeRanges: [String] = []
        var interimCount = 0
        var finalCount = 0
        var vadFinishedCount = 0
        var vadFinished = false
        var nonstreamResult = false
        for result in results {
            resultKeys.formUnion(result.keys)
            if let value = result["text"] as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let index = intValue(result["index"])
                    let startTime = intValue(result["start_time"])
                    let endTime = intValue(result["end_time"])
                    indices.append(index.map { String($0) } ?? "-")
                    startTimes.append(startTime.map { String($0) } ?? "-")
                    endTimes.append(endTime.map { String($0) } ?? "-")
                    if let startTime, let endTime {
                        timeRanges.append("\(startTime)-\(endTime)")
                    } else {
                        timeRanges.append("-")
                    }
                    let isSegmentFinal = result["is_interim"] as? Bool == false
                    segments.append(ASRRecognitionSegment(
                        id: segmentID(index: index, startTime: startTime, endTime: endTime, fallbackIndex: segments.count),
                        text: text,
                        index: index,
                        startTime: startTime,
                        endTime: endTime,
                        isFinal: isSegmentFinal
                    ))
                }
            }
            if result["is_interim"] as? Bool == false {
                finalCount += 1
            } else {
                interimCount += 1
            }
            if result["is_vad_finished"] as? Bool == true {
                vadFinishedCount += 1
                vadFinished = true
            }
            if let extra = result["extra"] as? [String: Any],
               extra["nonstream_result"] as? Bool == true {
                nonstreamResult = true
            }
        }

        let text = joinedSegmentText(segments.map(\.text))
        let isFinal = nonstreamResult || (finalCount > 0 && finalCount == results.count && vadFinished)
        let kind = isFinal ? "final" : "interim"
        let metadata: [String: String] = [
            "android_result_segments": String(results.count),
            "android_text_segments": String(segments.count),
            "android_interim_segments": String(interimCount),
            "android_final_segments": String(finalCount),
            "android_vad_finished_segments": String(vadFinishedCount),
            "android_nonstream_result": String(nonstreamResult),
            "android_result_keys": resultKeys.sorted().joined(separator: ","),
            "android_segment_ids": segments.map(\.id).joined(separator: ","),
            "android_segment_indices": indices.joined(separator: ","),
            "android_segment_start_times": startTimes.joined(separator: ","),
            "android_segment_end_times": endTimes.joined(separator: ","),
            "android_segment_time_ranges": timeRanges.joined(separator: ",")
        ]
        return .android(
            text: text,
            kind: kind,
            segmentCount: results.count,
            isFinal: isFinal,
            metadata: metadata,
            segments: segments
        )
    }

    private static func segmentID(
        index: Int?,
        startTime: Int?,
        endTime: Int?,
        fallbackIndex: Int
    ) -> String {
        if let startTime {
            return "start:\(startTime)"
        }
        if let index {
            return "index:\(index)"
        }
        if let endTime {
            return "end:\(endTime)"
        }
        return "ordinal:\(fallbackIndex)"
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func joinedSegmentText(_ segments: [String]) -> String {
        segments.reduce("") { output, segment in
            appendSegment(segment, to: output)
        }
    }

    private static func appendSegment(_ segment: String, to output: String) -> String {
        guard !output.isEmpty else { return segment }
        guard let last = output.last, let first = segment.first else {
            return output + segment
        }
        if last.isWhitespace || first.isWhitespace || sentenceEndingCharacters.contains(last) {
            return output + segment
        }
        if isCJK(last), isCJK(first) {
            return output + segment
        }
        return output + " " + segment
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func appendString(_ value: String, fieldNumber: Int, to data: inout Data) {
        appendBytes(Data(value.utf8), fieldNumber: fieldNumber, to: &data)
    }

    private static func appendBytes(_ value: Data, fieldNumber: Int, to data: inout Data) {
        appendRawVarint(UInt64(fieldNumber << 3 | 2), to: &data)
        appendRawVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendVarint(_ value: UInt64, fieldNumber: Int, to data: inout Data) {
        appendRawVarint(UInt64(fieldNumber << 3), to: &data)
        appendRawVarint(value, to: &data)
    }

    private static func appendRawVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex && shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func readString(_ data: Data, index: inout Data.Index) -> String? {
        guard let length = readVarint(data, index: &index) else { return nil }
        let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) ?? data.endIndex
        defer { index = end }
        return String(data: data[index..<end], encoding: .utf8)
    }

    private static func skip(wireType: Int, data: Data, index: inout Data.Index) {
        switch wireType {
        case 0:
            _ = readVarint(data, index: &index)
        case 1:
            index = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
        case 2:
            guard let length = readVarint(data, index: &index) else { return }
            index = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) ?? data.endIndex
        case 5:
            index = data.index(index, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
        default:
            index = data.endIndex
        }
    }

    private static let sentenceEndingCharacters = Set<Character>("。！？.!?")
}
