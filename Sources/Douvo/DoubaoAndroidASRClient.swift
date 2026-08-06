import Foundation

enum AndroidASRResponseType {
    case taskStarted
    case sessionStarted
    case sessionFinished
    case recognition(ASRRecognitionResult)
    case heartbeat
    case error(String, Int, [String: String])
    case unknown
}

struct AndroidASRResponse {
    let type: AndroidASRResponseType
}

enum AndroidASRErrorClassifier {
    static let concurrencyQuotaStatusCode = 40_200_011

    static func isConcurrencyQuotaExceeded(_ message: String) -> Bool {
        isConcurrencyQuotaExceeded(statusCode: 0, message: message)
    }

    static func isConcurrencyQuotaExceeded(statusCode: Int, message: String) -> Bool {
        if statusCode == concurrencyQuotaStatusCode { return true }
        let normalized = message.lowercased()
        return normalized.contains("concurrency quota exceeded")
            || normalized.contains("exceedconcurrentquota")
    }
}

enum AndroidASRSessionConfig {
    static func make(
        deviceID: String,
        context: String = "",
        usePersonalLexicon: Bool = false
    ) -> [String: Any] {
        var extra: [String: Any] = [
            "app_name": "com.android.chrome",
            "app_version": DoubaoAndroidClientIdentity.versionName,
            "aid": DoubaoAndroidClientIdentity.aid,
            "cell_compress_rate": 8,
            "did": deviceID,
            "enable_asr_threepass": true,
            "enable_asr_twopass": true,
            "enable_print_chinese": false,
            "disable_user_words": !usePersonalLexicon,
            // Runs one final whole-transcript correction after FinishSession.
            "enable_text_post_process": true,
            "asr_text_post_process_type": "last_post_process",
            "input_mode": "tool",
            "strong_ddc": true,
            "use_twopass_retry": true,
            "update_version_code": DoubaoAndroidClientIdentity.versionCode,
            "version_code": DoubaoAndroidClientIdentity.versionCode,
            "version_name": DoubaoAndroidClientIdentity.versionName
        ]
        if !context.isEmpty {
            extra["context"] = context
        }

        return [
            "audio_info": [
                "channel": 1,
                "format": "speech_opus",
                "sample_rate": 16000
            ],
            "enable_punctuation": true,
            "enable_speech_rejection": false,
            "extra": extra
        ]
    }
}

enum AndroidASRTaskRequestPayload {
    static func make(timestampMillis: Int64, isFinal: Bool) -> String {
        if isFinal {
            return #"{"extra":{"finish_audio":true,"force_asr_twopass":true},"timestamp_ms":\#(timestampMillis)}"#
        }
        return #"{"extra":{},"timestamp_ms":\#(timestampMillis)}"#
    }
}

enum AndroidASRFinishTrigger: String, Equatable {
    case finalFrameSent = "final_frame_sent"
    case noFinalAudio = "no_final_audio"
}

struct AndroidASRFinishCoordinator {
    private(set) var finalFrameSent = false
    private(set) var finalResultReceived = false
    private(set) var finishSessionRequested = false
    private(set) var finishTrigger: AndroidASRFinishTrigger?

    mutating func receive(_ result: ASRRecognitionResult) {
        if result.isFinal {
            finalResultReceived = true
        }
    }

    mutating func finalFrameDidSend() -> AndroidASRFinishTrigger? {
        finalFrameSent = true
        return requestFinish(.finalFrameSent)
    }

    mutating func finishWithoutAudio() -> AndroidASRFinishTrigger? {
        finalFrameSent = true
        return requestFinish(.noFinalAudio)
    }

    private mutating func requestFinish(_ trigger: AndroidASRFinishTrigger) -> AndroidASRFinishTrigger? {
        guard !finishSessionRequested else { return nil }
        finishSessionRequested = true
        finishTrigger = trigger
        return trigger
    }
}

final class DoubaoAndroidASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private typealias Identity = DoubaoAndroidClientIdentity

    private struct Connection {
        let session: URLSession
        let socket: URLSessionWebSocketTask
    }

    enum State: String, Sendable {
        case idle
        case connecting
        case open
        case finishing
        case finished
        case disconnected
        case failed
    }

    private static let webSocketURL = Identity.webSocketURL
    private static let webSocketHost = webSocketURL.host ?? "unknown"
    private static let frameDurationMillis: Int64 = 20
    private static let closeAcknowledgementTimeout: Duration = .seconds(1)
    private static let forcedTransportShutdownTimeout: Duration = .seconds(1)
    private static let unexpectedCloseErrorCode = 7

    private let sessionGate: AndroidASRSessionGate
    private let disconnectSignal = AndroidASRDisconnectSignal()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var sessionLease: AndroidASRSessionGate.Lease?
    private var socketCloseCoordinator = AndroidASRSocketCloseCoordinator()
    private var appKeyFallbackCoordinator = AndroidASRAppKeyFallbackCoordinator()
    private var activeAppKey = ""
    private var deferredFallbackFailure: Error?
    private var closeAcknowledgementTimeoutTask: Task<Void, Never>?
    private var forcedTransportShutdownTimeoutTask: Task<Void, Never>?
    private var state: State = .idle
    private var credentials: DoubaoAndroidCredentials?
    private var sessionContext = ""
    private var usePersonalLexicon = false
    private var requestID = ""
    private var pendingAudio: [Data] = []
    private var queuedAudio: [Data] = []
    private var latestAudioFrame: Data?
    private var isSendingAudio = false
    private var finishRequested = false
    private var finishFramesSent = false
    private var finishCoordinator = AndroidASRFinishCoordinator()
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

    init(sessionGate: AndroidASRSessionGate = .shared) {
        self.sessionGate = sessionGate
        super.init()
    }

    func connect(
        credentials: DoubaoAndroidCredentials,
        context: String = "",
        usePersonalLexicon: Bool = false
    ) async throws {
        try await withTaskCancellationHandler(operation: {
            let lease = try await sessionGate.acquire()
            do {
                try Task.checkCancellation()
                try startInitialAttempt(
                    credentials: credentials,
                    context: context,
                    usePersonalLexicon: usePersonalLexicon,
                    lease: lease
                )
                try Task.checkCancellation()
            } catch {
                let clientOwnsLease = lock.withLock { sessionLease == lease }
                if clientOwnsLease {
                    disconnect()
                } else {
                    sessionGate.release(lease)
                }
                throw error
            }
        }, onCancel: {
            disconnect()
        })
    }

    private func startInitialAttempt(
        credentials: DoubaoAndroidCredentials,
        context: String,
        usePersonalLexicon: Bool,
        lease: AndroidASRSessionGate.Lease
    ) throws {
        let request = try makeWebSocketRequest(credentials: credentials)
        let activeSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let socket = activeSession.webSocketTask(with: request)

        lock.lock()
        guard !Task.isCancelled, state == .idle else {
            lock.unlock()
            activeSession.invalidateAndCancel()
            throw CancellationError()
        }
        self.session = activeSession
        self.credentials = credentials
        sessionContext = context
        self.usePersonalLexicon = usePersonalLexicon
        task = socket
        sessionLease = lease
        activeAppKey = credentials.token
        appKeyFallbackCoordinator.reset(primaryAppKey: credentials.token)
        deferredFallbackFailure = nil
        disconnectSignal.reset()
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        latestAudioFrame = nil
        finishRequested = false
        resetAttemptStateLocked()
        lock.unlock()

        startSocket(socket, credentials: credentials)
    }

    private func makeWebSocketRequest(credentials: DoubaoAndroidCredentials) throws -> URLRequest {
        var components = URLComponents(url: Self.webSocketURL, resolvingAgainstBaseURL: false)!
        components.queryItems = Identity.frontierQueryItems(credentials: credentials)
        guard let url = components.url else {
            throw NSError(
                domain: "Douvo.AndroidASR",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Android recognition WebSocket URL is invalid"]
            )
        }

        var request = URLRequest(url: url)
        request.setValue(Identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")
        // URLSessionWebSocketTask owns the protocol handshake headers
        // (Connection, Upgrade, Sec-WebSocket-*). Keep these client-visible
        // headers aligned with the Web ASR request shape.
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 8
        return request
    }

    private func startSocket(
        _ socket: URLSessionWebSocketTask,
        credentials: DoubaoAndroidCredentials
    ) {
        guard let attempt = lock.withLock({ () -> String? in
            guard task === socket, state == .connecting else { return nil }
            return appKeyFallbackCoordinator.attempt.rawValue
        }) else { return }
        AppLog.info(
            "Android ASR connect begin attempt=\(attempt) deviceIdSet=\(!credentials.deviceId.isEmpty)"
        )
        socket.resume()
        receive(socket: socket)
        sendStartTask()
    }

    private func resetAttemptStateLocked() {
        requestID = UUID().uuidString
        startedAtMillis = Self.currentTimeMillis()
        socketCloseCoordinator = AndroidASRSocketCloseCoordinator()
        closeAcknowledgementTimeoutTask?.cancel()
        closeAcknowledgementTimeoutTask = nil
        forcedTransportShutdownTimeoutTask?.cancel()
        forcedTransportShutdownTimeoutTask = nil
        isSendingAudio = false
        finishFramesSent = false
        finishCoordinator = AndroidASRFinishCoordinator()
        frameIndex = 0
        receivedMessageCount = 0
        recognitionMessageCount = 0
        queuedAudioCount = queuedAudio.count
        pendingAudioCount = pendingAudio.count
        summaryLogged = false
        pendingAudioSamples.removeAll(keepingCapacity: true)
        queuedAudioSamples.removeAll(keepingCapacity: true)
        sentFrameSamples.removeAll(keepingCapacity: true)
        recognitionSamples.removeAll(keepingCapacity: true)
        transcriptAssembler.reset()
        state = .connecting
    }

    func sendAudio(_ data: Data) {
        lock.lock()
        if finishFramesSent {
            lock.unlock()
            return
        }

        if state == .open || state == .finishing {
            latestAudioFrame = data
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
        } else if state == .connecting || appKeyFallbackCoordinator.isRetryPending {
            latestAudioFrame = data
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
        if state == .connecting || appKeyFallbackCoordinator.isRetryPending {
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
        disconnect(cancelFallback: true, preservePendingRequest: false)
    }

    private func disconnectForFallback() {
        disconnect(cancelFallback: false, preservePendingRequest: true)
    }

    private func disconnect(cancelFallback: Bool, preservePendingRequest: Bool) {
        lock.lock()
        if cancelFallback {
            appKeyFallbackCoordinator.cancel()
            deferredFallbackFailure = nil
        }
        if state == .disconnected, socketCloseCoordinator.closeRequested {
            lock.unlock()
            return
        }
        state = .disconnected
        if !preservePendingRequest {
            pendingAudio.removeAll()
            queuedAudio.removeAll()
            latestAudioFrame = nil
            finishRequested = false
        }
        isSendingAudio = false
        finishFramesSent = false
        finishCoordinator = AndroidASRFinishCoordinator()
        let connection = currentConnectionLocked()
        let socketIsActive = connection.map { $0.socket.state != .completed } ?? false
        let closeAction = socketCloseCoordinator.requestClose(hasTask: socketIsActive)
        let lease = sessionLease
        lock.unlock()

        if let lease {
            sessionGate.beginClosing(lease)
        }
        performSocketCloseAction(closeAction, connection: connection)
    }

    func waitUntilDisconnected() async {
        await disconnectSignal.wait()
    }

    private func performSocketCloseAction(
        _ action: AndroidASRSocketCloseAction,
        connection: Connection?,
        error: Error? = nil
    ) {
        switch action {
        case .none:
            break
        case .sendClose:
            guard let connection, isCurrentConnection(connection) else { return }
            AppLog.info("Android ASR WebSocket close requested")
            scheduleCloseAcknowledgementTimeout(for: connection)
            connection.socket.cancel(with: .normalClosure, reason: "1000-".data(using: .utf8))
        case .forceTransportShutdown:
            guard let connection, isCurrentConnection(connection) else { return }
            AppLog.info("Android ASR WebSocket close acknowledgement timed out; forcing transport shutdown")
            scheduleForcedTransportShutdownTimeout(for: connection)
            connection.socket.cancel(with: .goingAway, reason: nil)
            connection.session.invalidateAndCancel()
        case .releaseSlot:
            releaseSessionSlot(for: connection)
        case .unexpectedClose:
            guard let connection else { return }
            handleUnexpectedClose(error ?? unexpectedCloseError(), connection: connection)
        }
    }

    private func handleUnexpectedClose(_ error: Error, connection: Connection) {
        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            return
        }
        let shouldNotify = state != .failed
        state = .failed
        isSendingAudio = false
        lock.unlock()

        if shouldNotify {
            onError?(asrError(error, stage: "unexpected_close"))
        }
        releaseSessionSlot(for: connection)
    }

    private func unexpectedCloseError(closeCode: Int? = nil) -> Error {
        let suffix = closeCode.map { " (close code \($0))" } ?? ""
        return NSError(
            domain: "Douvo.AndroidASR",
            code: Self.unexpectedCloseErrorCode,
            userInfo: [
                NSLocalizedDescriptionKey: "Android recognition WebSocket closed unexpectedly\(suffix)"
            ]
        )
    }

    private func scheduleCloseAcknowledgementTimeout(for connection: Connection) {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeAcknowledgementTimeout)
            guard !Task.isCancelled else { return }
            self?.handleCloseAcknowledgementTimeout(for: connection)
        }

        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        closeAcknowledgementTimeoutTask?.cancel()
        closeAcknowledgementTimeoutTask = timeoutTask
        lock.unlock()
    }

    private func handleCloseAcknowledgementTimeout(for connection: Connection) {
        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            return
        }
        let action = socketCloseCoordinator.closeAcknowledgementDidTimeOut()
        lock.unlock()
        performSocketCloseAction(action, connection: connection)
    }

    private func releaseSessionSlot(for connection: Connection?) {
        lock.lock()
        if let connection {
            guard isCurrentConnectionLocked(connection) else {
                lock.unlock()
                return
            }
        } else {
            guard task == nil, session == nil else {
                lock.unlock()
                return
            }
        }
        let lease = sessionLease
        let releasedSession = session
        session = nil
        task = nil
        let timeoutTask = closeAcknowledgementTimeoutTask
        closeAcknowledgementTimeoutTask = nil
        let forcedTimeoutTask = forcedTransportShutdownTimeoutTask
        forcedTransportShutdownTimeoutTask = nil
        let closeAcknowledged = socketCloseCoordinator.closeAcknowledged
        let completedAttempt = appKeyFallbackCoordinator.attempt
        let fallbackAppKey = appKeyFallbackCoordinator.transportDidRelease(
            closeAcknowledged: closeAcknowledged
        )
        let deferredFailure = fallbackAppKey == nil ? deferredFallbackFailure : nil
        deferredFallbackFailure = nil
        if fallbackAppKey == nil {
            sessionLease = nil
        }
        lock.unlock()

        timeoutTask?.cancel()
        forcedTimeoutTask?.cancel()
        // URLSession retains its delegate until invalidated. Prefer a Close ACK or
        // confirmed completion; forced invalidation has a bounded final fallback so
        // a missing delegate callback cannot block future recordings forever.
        releasedSession?.invalidateAndCancel()
        AppLog.info(
            "Android ASR disconnected attempt=\(completedAttempt.rawValue) closeAcknowledged=\(closeAcknowledged)"
        )
        logSummary(reason: "disconnect")

        if let fallbackAppKey, let lease {
            startFallbackAttempt(appKey: fallbackAppKey, lease: lease)
            return
        }

        if let deferredFailure {
            onError?(deferredFailure)
        }
        if let lease {
            sessionGate.release(lease)
        }
        disconnectSignal.complete()
    }

    private func startFallbackAttempt(
        appKey: String,
        lease: AndroidASRSessionGate.Lease
    ) {
        guard let credentials = lock.withLock({ self.credentials }) else {
            finishFallbackBeforeSocket(
                lease: lease,
                error: NSError(
                    domain: "Douvo.AndroidASR",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Android fallback credentials are missing"]
                )
            )
            return
        }

        let activeSession: URLSession
        let socket: URLSessionWebSocketTask
        do {
            let request = try makeWebSocketRequest(credentials: credentials)
            activeSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            socket = activeSession.webSocketTask(with: request)
        } catch {
            finishFallbackBeforeSocket(lease: lease, error: error)
            return
        }

        // The previous server connection has completed its Close handshake. Keep
        // the same lease so no second recording can enter between the two attempts.
        sessionGate.resumeAfterClose(lease)
        let shouldStart = lock.withLock { () -> Bool in
            guard sessionLease == lease,
                  task == nil,
                  appKeyFallbackCoordinator.canStartFallback else {
                return false
            }
            session = activeSession
            task = socket
            activeAppKey = appKey
            resetAttemptStateLocked()
            return true
        }

        guard shouldStart else {
            activeSession.invalidateAndCancel()
            finishFallbackBeforeSocket(lease: lease, error: nil)
            return
        }

        AppLog.info("Android ASR concurrency fallback starting after acknowledged Close")
        startSocket(socket, credentials: credentials)
    }

    private func finishFallbackBeforeSocket(
        lease: AndroidASRSessionGate.Lease,
        error: Error?
    ) {
        let shouldRelease = lock.withLock { () -> Bool in
            guard sessionLease == lease, task == nil else { return false }
            sessionLease = nil
            appKeyFallbackCoordinator.cancel()
            state = error == nil ? .disconnected : .failed
            return true
        }
        guard shouldRelease else { return }

        if let error {
            AppLog.error("Android ASR fallback connection failed error=\(error.localizedDescription)")
            onError?(asrError(error, stage: "fallback_connect_failed"))
        }
        sessionGate.release(lease)
        disconnectSignal.complete()
    }

    private func scheduleForcedTransportShutdownTimeout(for connection: Connection) {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.forcedTransportShutdownTimeout)
            guard !Task.isCancelled else { return }
            self?.handleForcedTransportShutdownTimeout(for: connection)
        }

        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        forcedTransportShutdownTimeoutTask?.cancel()
        forcedTransportShutdownTimeoutTask = timeoutTask
        lock.unlock()
    }

    private func handleForcedTransportShutdownTimeout(for connection: Connection) {
        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            return
        }
        let action = socketCloseCoordinator.transportDidComplete()
        lock.unlock()
        guard action == .releaseSlot else { return }
        AppLog.info("Android ASR forced transport shutdown completion timed out; releasing local slot")
        performSocketCloseAction(action, connection: connection)
    }

    private func currentConnectionLocked() -> Connection? {
        guard let session, let task else { return nil }
        return Connection(session: session, socket: task)
    }

    private func isCurrentConnection(_ connection: Connection) -> Bool {
        lock.withLock { isCurrentConnectionLocked(connection) }
    }

    private func isCurrentConnectionLocked(_ connection: Connection) -> Bool {
        session === connection.session && task === connection.socket
    }

    private func sendStartTask() {
        guard let (task, appKey) = lock.withLock({ () -> (URLSessionWebSocketTask, String)? in
            guard state == .connecting, let task else { return nil }
            return (task, activeAppKey)
        }) else { return }
        let payload = AndroidASRProtobuf.request(
            appKey: appKey,
            methodName: "StartTask",
            payload: "",
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        task.send(.data(payload)) { [weak self] error in
            guard let self, self.isCurrentActiveTask(task) else { return }
            if let error {
                AppLog.error("Android ASR StartTask send failed error=\(error.localizedDescription)")
                self.markFailed(error)
            }
        }
    }

    private func sendStartSession() {
        guard let (task, credentials, appKey) = lock.withLock({
            () -> (URLSessionWebSocketTask, DoubaoAndroidCredentials, String)? in
            guard state == .connecting, let task, let credentials else { return nil }
            return (task, credentials, activeAppKey)
        }) else { return }
        let config = AndroidASRSessionConfig.make(
            deviceID: credentials.deviceId,
            context: sessionContext,
            usePersonalLexicon: usePersonalLexicon
        )
        let payloadData = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        let payload = String(data: payloadData, encoding: .utf8) ?? "{}"
        let message = AndroidASRProtobuf.request(
            appKey: appKey,
            methodName: "StartSession",
            payload: payload,
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        task.send(.data(message)) { [weak self] error in
            guard let self, self.isCurrentActiveTask(task) else { return }
            if let error {
                AppLog.error("Android ASR StartSession send failed error=\(error.localizedDescription)")
                self.markFailed(error)
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
            appKey: "",
            methodName: "TaskRequest",
            payload: AndroidASRTaskRequestPayload.make(timestampMillis: timestamp, isFinal: false),
            audioData: audio,
            requestID: requestID,
            frameState: isFirst ? 1 : 3
        )
        lock.unlock()

        socket.send(.data(message)) { [weak self] error in
            guard let self else { return }
            guard self.isCurrentActiveTask(socket) else { return }
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
        lock.lock()
        let finalAudioFrame = latestAudioFrame
        lock.unlock()

        guard let finalAudioFrame else {
            AppLog.info("Android ASR final Opus frame skipped; no encoded audio available")
            lock.lock()
            let trigger = finishCoordinator.finishWithoutAudio()
            lock.unlock()
            if let trigger {
                sendFinishSession(socket: socket, trigger: trigger)
            }
            return
        }

        let timestamp = startedAtMillis + frameIndex * Self.frameDurationMillis
        let lastFrame = AndroidASRProtobuf.request(
            appKey: "",
            methodName: "TaskRequest",
            payload: AndroidASRTaskRequestPayload.make(timestampMillis: timestamp, isFinal: true),
            // AudioCaptureManager appends encoded Opus silence before finishSending().
            // Reuse its final packet so the protocol's last frame remains valid Opus.
            audioData: finalAudioFrame,
            requestID: requestID,
            frameState: 9
        )
        socket.send(.data(lastFrame)) { [weak self] error in
            guard let self else { return }
            guard self.isCurrentActiveTask(socket) else { return }
            if let error {
                AppLog.error("Android ASR last frame send failed error=\(error.localizedDescription)")
                self.markFailed(error)
                self.logSummary(reason: "last_frame_failed")
                return
            }
            AppLog.info("Android ASR final Opus frame sent finishAudio=true forceTwopass=true bytes=\(finalAudioFrame.count)")
            self.lock.lock()
            let trigger = self.finishCoordinator.finalFrameDidSend()
            self.lock.unlock()
            if let trigger {
                self.sendFinishSession(socket: socket, trigger: trigger)
            }
        }
    }

    private func sendFinishSession(
        socket: URLSessionWebSocketTask,
        trigger: AndroidASRFinishTrigger
    ) {
        lock.lock()
        guard state == .finishing, finishCoordinator.finishSessionRequested else {
            lock.unlock()
            return
        }
        let appKey = activeAppKey
        lock.unlock()

        AppLog.info("Android ASR sending FinishSession reason=\(trigger.rawValue)")
        let finish = AndroidASRProtobuf.request(
            appKey: appKey,
            methodName: "FinishSession",
            payload: "",
            audioData: Data(),
            requestID: requestID,
            frameState: 0
        )
        socket.send(.data(finish)) { [weak self] error in
            guard let self, self.isCurrentActiveTask(socket) else { return }
            if let error {
                AppLog.error("Android ASR FinishSession send failed error=\(error.localizedDescription)")
                self.logSummary(reason: "finish_session_failed")
                self.markFailed(error)
            } else {
                AppLog.info("Android ASR FinishSession sent")
            }
        }
    }

    private func receive(socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            guard self.isCurrentTask(socket) else { return }
            switch result {
            case .success(let message):
                self.lock.lock()
                self.receivedMessageCount += 1
                let count = self.receivedMessageCount
                self.lock.unlock()

                if case .data(let data) = message {
                    self.handleResponse(AndroidASRProtobuf.parseResponse(data), count: count)
                }
                self.receive(socket: socket)
            case .failure(let error):
                if !self.isExpectedClose(error) {
                    AppLog.error("Android ASR receive failed error=\(error.localizedDescription)")
                    self.logSummary(reason: "receive_failed")
                    let reportedError = self.asrError(error, stage: "receive_failed")
                    self.markFailed(nil, notify: false, disconnectImmediately: false)
                    self.onError?(reportedError)
                    self.disconnect()
                } else {
                    self.logSummary(reason: "receive_ended")
                }
            }
        }
    }

    private func isCurrentTask(_ socket: URLSessionTask) -> Bool {
        lock.withLock { task === socket }
    }

    private func isCurrentActiveTask(_ socket: URLSessionTask) -> Bool {
        lock.withLock { task === socket && state != .disconnected }
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
            disconnect()
            onFinish?()
        case .recognition(let result):
            let assembledResult = transcriptAssembler.update(with: result)
            lock.lock()
            recognitionMessageCount += 1
            let recognitionCount = recognitionMessageCount
            finishCoordinator.receive(assembledResult)
            if Self.shouldSampleProgress(recognitionCount) {
                Self.appendSummarySample(
                    "\(count):chars=\(assembledResult.text.count):kind=\(assembledResult.kind):segments=\(assembledResult.segmentCount):assembled=\(assembledResult.metadata["android_assembled_segments"] ?? "0")",
                    to: &recognitionSamples
                )
            }
            lock.unlock()
            onResult?(assembledResult)
            if assembledResult.isFinal {
                AppLog.info("Android ASR final result received chars=\(assembledResult.text.count) kind=\(assembledResult.kind) nonstream=\(assembledResult.metadata["android_nonstream_result"] ?? "false")")
            }
        case .heartbeat:
            break
        case .error(let message, let statusCode, let responseMetadata):
            AppLog.error("Android ASR error code=\(statusCode) message=\(message)")
            let reportedServerError = asrError(
                description: message,
                code: statusCode == 0 ? 3 : statusCode,
                stage: "server_error",
                responseMetadata: responseMetadata
            )
            let fallbackAction = lock.withLock {
                appKeyFallbackCoordinator.receiveServerError(
                    statusCode: statusCode,
                    message: message,
                    sessionIsConnecting: state == .connecting
                )
            }
            markFailed(nil, notify: false, disconnectImmediately: false)
            logSummary(reason: "server_error")
            if fallbackAction == .closeThenRetry {
                lock.withLock {
                    deferredFallbackFailure = reportedServerError
                }
                AppLog.info("Android ASR concurrency quota exceeded; closing before one fallback attempt")
                disconnectForFallback()
                return
            }
            if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("token") {
                onAuthError?()
            } else {
                onError?(reportedServerError)
            }
            disconnect()
        case .unknown:
            break
        }
    }

    private func markFinished() {
        lock.lock()
        state = .finished
        lock.unlock()
    }

    private func markFailed(
        _ error: Error?,
        notify: Bool = true,
        disconnectImmediately: Bool = true
    ) {
        lock.lock()
        state = .failed
        isSendingAudio = false
        lock.unlock()
        if notify {
            onError?(asrError(error, stage: "transport_failed"))
        }
        if disconnectImmediately {
            disconnect()
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
        let finalFrameSent = finishCoordinator.finalFrameSent
        let finalResultReceived = finishCoordinator.finalResultReceived
        let finishTrigger = finishCoordinator.finishTrigger?.rawValue ?? ""
        let appKeyAttempt = appKeyFallbackCoordinator.attempt.rawValue
        let fallbackUsed = appKeyFallbackCoordinator.fallbackUsed
        let fallbackTriggerStatusCode = appKeyFallbackCoordinator.triggerStatusCode
        lock.unlock()

        var metadata = [
            "android_stage": stage,
            "android_endpoint_host": Self.webSocketHost,
            "android_request_id": currentRequestID,
            "android_state": currentState,
            "android_pending_audio_count": String(pendingCount),
            "android_queued_audio_count": String(queuedCount),
            "android_sent_frames": String(sentFrames),
            "android_received_messages": String(receivedCount),
            "android_recognition_messages": String(recognitionCount),
            "android_final_frame_sent": String(finalFrameSent),
            "android_final_result_received": String(finalResultReceived),
            "android_finish_trigger": finishTrigger,
            "android_app_key_attempt": appKeyAttempt,
            "android_app_key_fallback_used": String(fallbackUsed)
        ]
        if let fallbackTriggerStatusCode {
            metadata["android_app_key_fallback_trigger_status"] = String(fallbackTriggerStatusCode)
        }
        return metadata
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
        let finalFrameSent = finishCoordinator.finalFrameSent
        let finalResultReceived = finishCoordinator.finalResultReceived
        let finishTrigger = finishCoordinator.finishTrigger?.rawValue ?? "none"
        let appKeyAttempt = appKeyFallbackCoordinator.attempt.rawValue
        let fallbackUsed = appKeyFallbackCoordinator.fallbackUsed
        lock.unlock()

        AppLog.info("Android ASR summary reason=\(reason) attempt=\(appKeyAttempt) fallbackUsed=\(fallbackUsed) state=\(state) pending=\(pendingCount) queued=\(queuedCount) pendingAudio=\(pendingTotal) queuedAudio=\(queuedTotal) sentFrames=\(sentFrames) receivedMessages=\(receivedCount) recognitionMessages=\(recognitionCount) finalFrameSent=\(finalFrameSent) finalResultReceived=\(finalResultReceived) finishTrigger=\(finishTrigger) pendingSamples=\(pendingSamples) queuedSamples=\(queuedSamples) sentSamples=\(sentSamples) recognitionSamples=\(resultSamples)")
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

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let connection = Connection(session: session, socket: webSocketTask)
        lock.lock()
        guard isCurrentConnectionLocked(connection) else {
            lock.unlock()
            return
        }
        let action = socketCloseCoordinator.receiveCloseAcknowledgement()
        lock.unlock()

        if action == .unexpectedClose {
            AppLog.error(
                "Android ASR WebSocket closed without a close request code=\(closeCode.rawValue) reasonBytes=\(reason?.count ?? 0)"
            )
            performSocketCloseAction(
                action,
                connection: connection,
                error: unexpectedCloseError(closeCode: closeCode.rawValue)
            )
        } else {
            AppLog.info(
                "Android ASR WebSocket close acknowledged code=\(closeCode.rawValue) reasonBytes=\(reason?.count ?? 0)"
            )
            performSocketCloseAction(
                action,
                connection: connection
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task completedTask: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard task === completedTask,
              let connection = currentConnectionLocked(),
              connection.session === session else {
            lock.unlock()
            return
        }
        let action = socketCloseCoordinator.transportDidComplete()
        lock.unlock()

        if action == .unexpectedClose {
            let unexpectedError = error ?? unexpectedCloseError()
            AppLog.error("Android ASR transport completed before a close request error=\(unexpectedError.localizedDescription)")
            performSocketCloseAction(
                action,
                connection: connection,
                error: unexpectedError
            )
        } else {
            if let error, !isExpectedClose(error) {
                AppLog.info("Android ASR transport completed error=\(error.localizedDescription)")
            }
            performSocketCloseAction(
                action,
                connection: connection
            )
        }
    }
}

struct AndroidASRTranscriptAssembler {
    private var committedSegments: [ASRRecognitionSegment] = []
    private var activeSegment: ASRRecognitionSegment?
    private var usesCumulativeSnapshots = false
    private var activeRewriteCount = 0
    private var activeCommitCount = 0
    private var overlappedSegmentUpdateCount = 0

    mutating func reset() {
        committedSegments.removeAll(keepingCapacity: true)
        activeSegment = nil
        usesCumulativeSnapshots = false
        activeRewriteCount = 0
        activeCommitCount = 0
        overlappedSegmentUpdateCount = 0
    }

    mutating func update(with result: ASRRecognitionResult) -> ASRRecognitionResult {
        guard !result.segments.isEmpty else { return result }

        if result.metadata["android_result_model"] == "cumulative_with_details" {
            // This frame proves results[0] is the full snapshot. Future single-result
            // frames in the same session must also replace, not append to, that text.
            usesCumulativeSnapshots = true
            committedSegments.removeAll(keepingCapacity: true)
            activeSegment = nil
        }

        if usesCumulativeSnapshots {
            var metadata = result.metadata
            metadata["android_transcript_model"] = "cumulative"
            metadata["android_assembled_segments"] = String(result.segments.count)
            metadata["android_assembled_segment_ids"] = result.segments.map(\.id).joined(separator: ",")
            metadata["android_assembled_segment_final_count"] = String(result.segments.filter(\.isFinal).count)
            return .android(
                text: result.text,
                kind: result.kind,
                segmentCount: result.segmentCount,
                isFinal: result.isFinal,
                metadata: metadata,
                segments: result.segments
            )
        }

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
        appKey: String,
        methodName: String,
        payload: String,
        audioData: Data,
        requestID: String,
        frameState: Int
    ) -> Data {
        var data = Data()
        if !appKey.isEmpty {
            appendString(appKey, fieldNumber: 2, to: &data)
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
        var statusCode = 0
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
            case (5, 0):
                statusCode = Int(readVarint(data, index: &index) ?? 0)
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
            "android_response_status_code": String(statusCode),
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
            return AndroidASRResponse(type: .error(statusMessage, statusCode, responseMetadata))
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

        let isCumulativeWithDetails = isCumulativeWithSentenceDetails(results)
        var segments: [ASRRecognitionSegment] = []
        var resultKeys = Set<String>()
        var indices: [String] = []
        var startTimes: [String] = []
        var endTimes: [String] = []
        var timeRanges: [String] = []
        var interimCount = 0
        var finalCount = 0
        var vadFinishedCount = 0
        var streamASRFinishedCount = 0
        var rawNonstreamResultCount = 0
        for (resultOffset, result) in results.enumerated() {
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
                    if !isCumulativeWithDetails || resultOffset == 0 {
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
            }
            if result["is_interim"] as? Bool == false {
                finalCount += 1
            } else {
                interimCount += 1
            }
            if result["is_vad_finished"] as? Bool == true {
                vadFinishedCount += 1
            }
            if result["stream_asr_finish"] as? Bool == true {
                streamASRFinishedCount += 1
            }
            if let extra = result["extra"] as? [String: Any],
               extra["nonstream_result"] as? Bool == true {
                rawNonstreamResultCount += 1
            }
        }

        // Sentence-detail nonstream flags finalize only that sentence. They must not
        // finalize the full stream represented by results[0].
        let finalizationResults = isCumulativeWithDetails ? Array(results.prefix(1)) : results
        let finalizationFinalCount = finalizationResults.filter { $0["is_interim"] as? Bool == false }.count
        let nonstreamResult = finalizationResults.contains {
            guard let extra = $0["extra"] as? [String: Any] else { return false }
            return extra["nonstream_result"] as? Bool == true
        }
        let text = joinedSegmentText(segments.map(\.text))
        // `last_post_process` returns the whole-transcript revision with
        // `is_interim=false`, but without `is_vad_finished`. Requiring both flags
        // mislabels the server's final corrected snapshot as interim.
        let isFinal = nonstreamResult || (
            finalizationFinalCount > 0
                && finalizationFinalCount == finalizationResults.count
        )
        let kind = isFinal ? "final" : "interim"
        let resultModel: String
        if isCumulativeWithDetails {
            resultModel = "cumulative_with_details"
        } else if results.count == 1 {
            resultModel = "single"
        } else {
            resultModel = "segmented"
        }
        let metadata: [String: String] = [
            "android_result_model": resultModel,
            "android_result_segments": String(results.count),
            "android_text_segments": String(segments.count),
            "android_detail_segments": String(isCumulativeWithDetails ? max(0, results.count - 1) : 0),
            "android_interim_segments": String(interimCount),
            "android_final_segments": String(finalCount),
            "android_vad_finished_segments": String(vadFinishedCount),
            "android_stream_asr_finished_segments": String(streamASRFinishedCount),
            "android_nonstream_result": String(nonstreamResult),
            "android_raw_nonstream_result_segments": String(rawNonstreamResultCount),
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

    private static func isCumulativeWithSentenceDetails(_ results: [[String: Any]]) -> Bool {
        guard results.count > 1,
              let cumulativeValue = results[0]["text"] as? String else {
            return false
        }
        let cumulativeText = cumulativeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cumulativeText.isEmpty else { return false }

        let detailResults = results.dropFirst()
        let detailTexts = detailResults.compactMap { result -> String? in
            guard let value = result["text"] as? String else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !detailTexts.isEmpty else { return false }

        if normalizedFrameText(joinedSegmentText(detailTexts)) == normalizedFrameText(cumulativeText) {
            return true
        }

        // Captured Android frames identify sentence breakdown entries with these
        // fields while the cumulative entry starts at the beginning of the stream.
        let firstStartsAtZero = intValue(results[0]["start_time"]) == 0
        let hasSentenceDetailSignal = detailResults.contains { result in
            if result["stream_asr_finish"] != nil { return true }
            guard let extra = result["extra"] as? [String: Any] else { return false }
            return extra["nonstream_result"] != nil
        }
        return firstStartsAtZero && hasSentenceDetailSignal
    }

    private static func normalizedFrameText(_ text: String) -> String {
        text.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
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
