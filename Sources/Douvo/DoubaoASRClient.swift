import Foundation

enum DoubaoClient {
    /// Shared between the login WebView and the ASR WebSocket so the server sees a
    /// consistent browser identity for the same cookies.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
}

final class DoubaoASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum State: String, Sendable {
        case idle
        case connecting
        case open
        case finishing
        case finished
        case disconnected
        case failed
    }

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var state: State = .idle
    private var pendingAudio: [Data] = []
    private var queuedAudio: [Data] = []
    private var isSendingAudio = false
    private var finishRequested = false
    private var finishFrameSent = false
    private var sentAudioCount = 0
    private var completedSendCount = 0
    private var receivedMessageCount = 0
    private var resultMessageCount = 0
    private var openCallbackSent = false
    private var summaryLogged = false
    private var bufferedAudioSamples: [String] = []
    private var queuedAudioSamples: [String] = []
    private var completedSendSamples: [String] = []
    private var resultMessageSamples: [String] = []
    private var connectionTimeout: DispatchWorkItem?
    private let lock = NSLock()
    private static let maxSummarySamples = 12
    private static let webSocketHost = "ws-samantha.doubao.com"

    var onOpen: (() -> Void)?
    var onResult: ((ASRRecognitionResult) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((Error?) -> Void)?
    var onAuthError: (() -> Void)?

    func connect(params: DoubaoASRParams) {
        AppLog.info("ASR connect begin cookieCount=\(params.cookies.count) hasAuthCookies=\(params.hasRequiredAuthCookies) deviceIdSet=\(!params.deviceId.isEmpty) webIdSet=\(!params.webId.isEmpty)")
        var components = URLComponents(string: "wss://ws-samantha.doubao.com/samantha/audio/asr")!
        components.queryItems = [
            URLQueryItem(name: "version_code", value: "20800"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "aid", value: "497858"),
            URLQueryItem(name: "real_aid", value: "497858"),
            URLQueryItem(name: "pkg_type", value: "release_version"),
            URLQueryItem(name: "device_id", value: params.deviceId),
            URLQueryItem(name: "pc_version", value: "3.23.10"),
            URLQueryItem(name: "web_id", value: params.webId),
            URLQueryItem(name: "tea_uuid", value: params.webId),
            URLQueryItem(name: "region", value: "CN"),
            URLQueryItem(name: "sys_region", value: "CN"),
            URLQueryItem(name: "samantha_web", value: "1"),
            URLQueryItem(name: "web_platform", value: "browser"),
            URLQueryItem(name: "use-olympus-account", value: "1"),
            URLQueryItem(name: "web_tab_id", value: UUID().uuidString),
            URLQueryItem(name: "format", value: "pcm"),
        ]

        guard let url = components.url else {
            AppLog.error("ASR URL creation failed")
            onError?(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        // Match the browser session used at login so risk control sees a consistent client.
        request.setValue(DoubaoClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 6

        let socket = session.webSocketTask(with: request)
        lock.lock()
        task = socket
        queuedAudio.removeAll()
        isSendingAudio = false
        finishRequested = false
        finishFrameSent = false
        sentAudioCount = 0
        completedSendCount = 0
        receivedMessageCount = 0
        resultMessageCount = 0
        openCallbackSent = false
        summaryLogged = false
        bufferedAudioSamples.removeAll(keepingCapacity: true)
        queuedAudioSamples.removeAll(keepingCapacity: true)
        completedSendSamples.removeAll(keepingCapacity: true)
        resultMessageSamples.removeAll(keepingCapacity: true)
        state = .connecting
        lock.unlock()
        socket.resume()
        receive()
        startConnectionTimeout()
        socket.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.error("ASR ping failed error=\(error.localizedDescription)")
                return
            }
            AppLog.info("ASR ping succeeded; socket considered open")
            self.markOpen(reason: "ping")
        }
    }

    func sendAudio(_ data: Data) {
        lock.lock()
        if finishFrameSent {
            lock.unlock()
            AppLog.info("ASR audio dropped after finish bytes=\(data.count)")
            return
        }

        if (state == .open || state == .finishing), task != nil {
            queuedAudio.append(data)
            sentAudioCount += 1
            let queuedCount = queuedAudio.count
            let count = sentAudioCount
            if Self.shouldSampleProgress(count) {
                Self.appendSummarySample("\(count):queued=\(queuedCount):bytes=\(data.count)", to: &queuedAudioSamples)
            }
            let shouldStartSending = !isSendingAudio
            lock.unlock()
            if shouldStartSending {
                sendNextAudio()
            }
        } else if state == .connecting {
            pendingAudio.append(data)
            let pendingCount = pendingAudio.count
            if Self.shouldSampleProgress(pendingCount) {
                Self.appendSummarySample("\(pendingCount):bytes=\(data.count)", to: &bufferedAudioSamples)
            }
            lock.unlock()
        } else {
            let currentState = state
            lock.unlock()
            AppLog.info("ASR audio dropped state=\(currentState.rawValue) bytes=\(data.count)")
        }
    }

    func finishSending() {
        lock.lock()
        finishRequested = true
        if state == .connecting || state == .open {
            state = .finishing
        }
        let pendingCount = pendingAudio.count
        movePendingAudioToQueueLocked()
        let queuedCount = queuedAudio.count
        let shouldStartSending = !isSendingAudio
        lock.unlock()
        cancelConnectionTimeout()
        if shouldStartSending {
            sendNextAudio()
        }
        AppLog.info("ASR finish requested pending=\(pendingCount) queued=\(queuedCount) sentAudioCount=\(sentAudioCount) completedSendCount=\(completedSendCount)")
    }

    func disconnect() {
        cancelConnectionTimeout()
        lock.lock()
        state = .disconnected
        let pendingCount = pendingAudio.count
        let queuedCount = queuedAudio.count
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        isSendingAudio = false
        finishRequested = false
        finishFrameSent = false
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: "1000-".data(using: .utf8))
        task = nil
        AppLog.info("ASR disconnected pendingDropped=\(pendingCount) queuedDropped=\(queuedCount) sentAudioCount=\(sentAudioCount)")
        logSummary(reason: "disconnect")
    }

    private func markOpen(reason: String) {
        lock.lock()
        if state == .connecting {
            state = .open
        }
        let currentState = state
        let flushedCount = movePendingAudioToQueueLocked()
        let queuedCount = queuedAudio.count
        let shouldStartSending = !isSendingAudio
        lock.unlock()

        AppLog.info("ASR flushing buffered audio state=\(currentState.rawValue) count=\(flushedCount) queued=\(queuedCount)")
        if shouldStartSending {
            sendNextAudio()
        }

        guard !openCallbackSent else { return }
        openCallbackSent = true
        AppLog.info("ASR transport opened reason=\(reason)")
        onOpen?()
    }

    private func startConnectionTimeout() {
        connectionTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let hasTask = self.task != nil
            let state = self.state
            let completedSendCount = self.completedSendCount
            let receivedMessageCount = self.receivedMessageCount
            let sentAudioCount = self.sentAudioCount
            self.lock.unlock()
            guard hasTask, completedSendCount == 0, receivedMessageCount == 0 else { return }
            AppLog.error("ASR connection timeout state=\(state.rawValue) completedSendCount=0 receivedMessageCount=0 sentAudioCount=\(sentAudioCount)")
            self.onError?(NSError(
                domain: "Douvo.ASR",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition did not accept audio within 8 seconds"]
            ))
        }
        connectionTimeout = timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func cancelConnectionTimeout() {
        connectionTimeout?.cancel()
        connectionTimeout = nil
    }

    @discardableResult
    private func movePendingAudioToQueueLocked() -> Int {
        let count = pendingAudio.count
        guard count > 0 else { return 0 }
        queuedAudio.append(contentsOf: pendingAudio)
        sentAudioCount += pendingAudio.count
        pendingAudio.removeAll()
        return count
    }

    private func sendNextAudio() {
        lock.lock()
        guard !isSendingAudio else {
            lock.unlock()
            return
        }

        guard (state == .open || state == .finishing), let socket = task else {
            lock.unlock()
            return
        }

        guard !queuedAudio.isEmpty else {
            let shouldSendFinish = finishRequested && !finishFrameSent
            if shouldSendFinish {
                finishFrameSent = true
            }
            let completedCount = completedSendCount
            let totalCount = sentAudioCount
            lock.unlock()

            if shouldSendFinish {
                sendFinishFrame(socket: socket, completedCount: completedCount, totalCount: totalCount)
            }
            return
        }

        let data = queuedAudio.removeFirst()
        isSendingAudio = true
        lock.unlock()

        socket.send(.data(data)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.lock.lock()
                self.isSendingAudio = false
                self.state = .failed
                self.lock.unlock()
                AppLog.error("ASR audio send failed error=\(error.localizedDescription)")
                self.onError?(error)
                return
            }

            self.lock.lock()
            self.completedSendCount += 1
            let completedCount = self.completedSendCount
            if Self.shouldSampleProgress(completedCount) {
                Self.appendSummarySample("\(completedCount)", to: &self.completedSendSamples)
            }
            self.isSendingAudio = false
            self.lock.unlock()

            self.cancelConnectionTimeout()
            self.sendNextAudio()
        }
    }

    private func sendFinishFrame(socket: URLSessionWebSocketTask, completedCount: Int, totalCount: Int) {
        // Tell the server we're done only after all locally queued audio frames have
        // been accepted by URLSession, so the recognizer sees the tail before finish.
        socket.send(.string("{\"event\":\"finish\"}")) { [weak self] error in
            if let error {
                self?.markFailed()
                AppLog.error("ASR finish frame send failed error=\(error.localizedDescription)")
                self?.logSummary(reason: "finish_frame_failed")
            } else {
                AppLog.info("ASR finish frame sent completedSendCount=\(completedCount) sentAudioCount=\(totalCount)")
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
                self.lock.unlock()
                self.cancelConnectionTimeout()
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    } else {
                        AppLog.info("ASR received binary data bytes=\(data.count)")
                    }
                @unknown default:
                    break
                }
                self.receive()
            case .failure(let error):
                let failure = self.receiveFailureContext(for: error)
                if failure.shouldSuppress {
                    AppLog.info("ASR receive ended state=\(failure.state.rawValue) error=\(error.localizedDescription)")
                    self.logSummary(reason: "receive_ended")
                } else if failure.wasOpen {
                    AppLog.error("ASR receive failed error=\(error.localizedDescription)")
                    self.logSummary(reason: "receive_failed")
                    self.onError?(self.asrError(error, stage: "receive_failed"))
                } else {
                    AppLog.error("ASR receive failed before open error=\(error.localizedDescription)")
                    self.logSummary(reason: "receive_failed_before_open")
                    self.onError?(self.asrError(error, stage: "receive_failed_before_open"))
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLog.error("ASR message JSON parse failed text=\(text.prefix(200))")
            return
        }

        let code = json["code"] as? Int ?? 0
        let event = json["event"] as? String ?? ""
        let message = (json["message"] as? String ?? "").lowercased()
        lock.lock()
        let receivedCount = receivedMessageCount
        if event == "result" {
            resultMessageCount += 1
            if Self.shouldSampleProgress(resultMessageCount) {
                Self.appendSummarySample("\(receivedCount):code=\(code)", to: &resultMessageSamples)
            }
        }
        lock.unlock()
        if event != "result" {
            AppLog.info("ASR message count=\(receivedCount) event=\(event) code=\(code)")
        }

        if code != 0 {
            if code == 709599054 || message.contains("auth") || message.contains("login") || message.contains("session") || message.contains("cookie") {
                markFailed()
                AppLog.error("ASR auth-like error code=\(code) message=\(message)")
                logSummary(reason: "auth_error")
                onAuthError?()
                return
            }
            AppLog.error("ASR nonzero code=\(code) message=\(message)")
            markFailed()
            logSummary(reason: "server_error")
            let description = message.isEmpty ? "ASR server error code=\(code)" : message
            onError?(NSError(
                domain: "Douvo.WebASR",
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                    TranscriptionErrorMetadata.userInfoKey: diagnosticMetadata(stage: "server_error", event: event, code: code)
                ]
            ))
            return
        }

        if event == "result",
           let result = json["result"] as? [String: Any],
           let text = result["Text"] as? String,
           !text.isEmpty {
            onResult?(.web(text))
        } else if event == "finish" {
            markFinished()
            AppLog.info("ASR finish received")
            logSummary(reason: "finish")
            onFinish?()
        }
    }

    private func receiveFailureContext(for error: Error) -> (shouldSuppress: Bool, state: State, wasOpen: Bool) {
        lock.lock()
        let previousState = state
        let wasOpen = state == .open || state == .finishing || state == .finished
        if state != .disconnected && state != .finished {
            state = .failed
        }
        lock.unlock()

        return (
            shouldSuppress: Self.isExpectedCloseState(previousState) && Self.isExpectedCloseError(error),
            state: previousState,
            wasOpen: wasOpen
        )
    }

    private func markFinished() {
        lock.lock()
        state = .finished
        lock.unlock()
    }

    private func markFailed() {
        lock.lock()
        state = .failed
        lock.unlock()
    }

    private static func isExpectedCloseState(_ state: State) -> Bool {
        state == .finishing || state == .finished || state == .disconnected
    }

    private static func isExpectedCloseError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true } // ENOTCONN
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled, NSURLErrorNetworkConnectionLost:
                return true
            default:
                break
            }
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected")
    }

    private func asrError(_ error: Error, stage: String) -> Error {
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

    private func diagnosticMetadata(stage: String, event: String = "", code: Int? = nil) -> [String: String] {
        lock.lock()
        let currentState = state.rawValue
        let pendingCount = pendingAudio.count
        let queuedCount = queuedAudio.count
        let sentCount = sentAudioCount
        let completedCount = completedSendCount
        let receivedCount = receivedMessageCount
        let resultCount = resultMessageCount
        lock.unlock()

        var metadata: [String: String] = [
            "web_stage": stage,
            "web_endpoint_host": Self.webSocketHost,
            "web_state": currentState,
            "web_pending_audio_count": String(pendingCount),
            "web_queued_audio_count": String(queuedCount),
            "web_sent_audio_count": String(sentCount),
            "web_completed_send_count": String(completedCount),
            "web_received_messages": String(receivedCount),
            "web_result_messages": String(resultCount)
        ]
        if !event.isEmpty {
            metadata["web_event"] = event
        }
        if let code {
            metadata["web_code"] = String(code)
        }
        return metadata
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        AppLog.info("ASR URLSession didOpen protocol=\(proto ?? "none")")
        markOpen(reason: "delegate")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        AppLog.info("ASR URLSession didClose code=\(closeCode.rawValue) reasonBytes=\(reason?.count ?? 0) reason=\"\(reasonText)\"")
        lock.lock()
        if state != .finished && state != .disconnected {
            state = .disconnected
        }
        lock.unlock()
        logSummary(reason: "socket_closed")
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
        let sentCount = sentAudioCount
        let completedCount = completedSendCount
        let receivedCount = receivedMessageCount
        let resultCount = resultMessageCount
        let bufferedSamples = Self.formatSamples(bufferedAudioSamples)
        let queuedSamples = Self.formatSamples(queuedAudioSamples)
        let completedSamples = Self.formatSamples(completedSendSamples)
        let resultSamples = Self.formatSamples(resultMessageSamples)
        lock.unlock()

        AppLog.info("ASR summary reason=\(reason) state=\(state) pending=\(pendingCount) queued=\(queuedCount) sentAudio=\(sentCount) completedSends=\(completedCount) receivedMessages=\(receivedCount) resultMessages=\(resultCount) bufferedSamples=\(bufferedSamples) queuedSamples=\(queuedSamples) completedSamples=\(completedSamples) resultSamples=\(resultSamples)")
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
}
