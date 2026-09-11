import CryptoKit
import Foundation
import AppKit

struct BageshuoSigningContext: Sendable {
    let product: String
    let appVersion: String
    let client: String
    let mid: String
    let vendor: String
    let screen: String
    let model: String
    let imei: String
    let network: String
    let keyfrom: String
    let abtest: String
    let yduuid: String
}

enum BageshuoSigner {
    static let keyID = "typeless_mac_main"
    // The ticket service validates the observed Bage Shuo client identity, not Douvo's app version.
    private static let clientVersion = "1.0.30"

    // This is the public client signing key bundled by the original desktop client.
    // It authenticates the app client, not a user's account.
    private static let secretKey = "1TNWxQEtUtTg1XkhvJvQJl84TmtLXmCe"

    static func currentContext(deviceID installedDeviceID: String? = nil) -> BageshuoSigningContext {
        let defaultsKey = "bageshuo.yduuid"
        let deviceID: String
        if let installedDeviceID, !installedDeviceID.isEmpty {
            deviceID = installedDeviceID
        } else if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(deviceID, forKey: defaultsKey)
        }

        let appVersion = clientVersion
        let screen = primaryScreenPixelSize()
        return BageshuoSigningContext(
            product: "typeless",
            appVersion: appVersion,
            client: "mac",
            mid: "macosaarch64",
            vendor: "direct",
            screen: screen,
            model: "aarch64",
            imei: deviceID,
            network: "wifi",
            keyfrom: "typeless.\(appVersion).mac",
            abtest: deviceBucket(for: deviceID),
            yduuid: deviceID
        )
    }

    private static func primaryScreenPixelSize() -> String {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return "100x100"
        }
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        return "\(max(width, 1))x\(max(height, 1))"
    }

    private static func deviceBucket(for deviceID: String) -> String {
        let hash = deviceID.utf8.reduce(UInt32(0)) { partial, byte in
            partial &* 31 &+ UInt32(byte)
        }
        return String(hash % 10)
    }

    static func signedParameters(
        context: BageshuoSigningContext,
        nowMilliseconds: Int64,
        secret: String = secretKey,
        keyID: String = Self.keyID
    ) -> [String: String] {
        var parameters: [String: String] = [
            "product": context.product,
            "appVersion": context.appVersion,
            "client": context.client,
            "mid": context.mid,
            "vendor": context.vendor,
            "screen": context.screen,
            "model": context.model,
            "imei": context.imei,
            "network": context.network,
            "keyfrom": context.keyfrom,
            "abtest": context.abtest,
            "yduuid": context.yduuid,
            "keyid": keyID,
            "mysticTime": String(nowMilliseconds)
        ]
        parameters = parameters.filter { !$0.value.isEmpty }

        let signingKeys = parameters.keys.sorted()
        let signingString = (signingKeys + ["key"]).map { key in
            let value = key == "key" ? secret : parameters[key]!
            return "\(key)=\(value)"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data(signingString.utf8))
        parameters["sign"] = digest.map { String(format: "%02x", $0) }.joined()
        parameters["pointParam"] = (signingKeys + ["key"]).joined(separator: ",")
        return parameters
    }
}

struct BageshuoRealtimeEvent: Sendable {
    let version: Int
    let type: String
    let eventID: String
    let timestamp: String
    let payload: [String: String]
}

struct BageshuoTicketInfo: Sendable {
    let websocketURL: URL
    let ticket: String
    let protocolVersion: Int
    let maxAudioFrameBytes: Int
    let sampleRateHz: Int
    let channels: Int
    let encoding: String
}

final class BageshuoASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private enum State: String {
        case idle
        case connecting
        case open
        case finishing
        case finished
        case failed
        case disconnected
    }

    private static let serverBaseURL = URL(string: "https://dict-typeless.youdao.com")!
    private static let ticketPath = "/api/v1/realtime/tickets"
    private static let defaultMaxAudioFrameBytes = 65_536
    private static let sampleRateHz = 16_000
    private static let channels = 1
    private static let encoding = "PCM_S16LE"

    private let lock = NSLock()
    private var state: State = .idle
    private var connectionTask: Task<Void, Never>?
    private var socketSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var utteranceID = UUID().uuidString
    private var startRequestID = UUID().uuidString
    private var pendingAudio: [Data] = []
    private var queuedAudio: [Data] = []
    private var isSendingAudio = false
    private var readyForAudio = false
    private var finishRequested = false
    private var finishFrameSent = false
    private var sentAudioBytes = 0
    private var maxAudioFrameBytes = 65_536
    private var openCallbackSent = false
    private var finishCallbackSent = false
    private var errorCallbackSent = false

    var onOpen: (() -> Void)?
    var onResult: ((ASRRecognitionResult) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((Error?) -> Void)?
    var onAuthError: ((Error) -> Void)?

    func connect(params: BageshuoASRParams) {
        disconnect()
        lock.lock()
        state = .connecting
        utteranceID = UUID().uuidString.lowercased()
        startRequestID = UUID().uuidString.lowercased()
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        isSendingAudio = false
        readyForAudio = false
        finishRequested = false
        finishFrameSent = false
        sentAudioBytes = 0
        maxAudioFrameBytes = Self.defaultMaxAudioFrameBytes
        openCallbackSent = false
        finishCallbackSent = false
        errorCallbackSent = false
        lock.unlock()

        AppLog.info("Bage Shuo ASR connect begin cookieCount=\(params.cookies.count) hasAuthCookies=\(params.hasRequiredAuthCookies)")
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshedParams: BageshuoASRParams?
                if BageshuoASRParamsStore.credentialSource == .installedApp {
                    refreshedParams = await BageshuoASRParamsStore.rehydrateInstalledApp()
                } else {
                    refreshedParams = nil
                }
                let effectiveParams = refreshedParams ?? params
                AppLog.info("Bage Shuo ASR session-rehydrate used=\(refreshedParams != nil)")
                let ticketInfo = try await self.requestTicket(params: effectiveParams)
                try Task.checkCancellation()
                self.openSocket(ticketInfo: ticketInfo)
            } catch is CancellationError {
                return
            } catch {
                self.report(error: error)
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard state == .connecting || state == .open || state == .finishing else {
            let currentState = state.rawValue
            lock.unlock()
            AppLog.info("Bage Shuo audio dropped state=\(currentState) bytes=\(data.count)")
            return
        }
        guard data.count <= maxAudioFrameBytes else {
            lock.unlock()
            let error = Self.makeError(
                code: 413,
                message: "Bage Shuo audio frame exceeds server limit",
                metadata: ["frame_bytes": String(data.count), "max_frame_bytes": String(maxAudioFrameBytes)]
            )
            report(error: error)
            return
        }

        if readyForAudio {
            queuedAudio.append(data)
            let shouldStartSending = !isSendingAudio
            lock.unlock()
            if shouldStartSending { sendNextAudio() }
        } else {
            pendingAudio.append(data)
            lock.unlock()
        }
    }

    func finishSending() {
        lock.lock()
        finishRequested = true
        if state == .open || state == .connecting {
            state = .finishing
        }
        movePendingAudioToQueueLocked()
        let shouldStartSending = readyForAudio && !isSendingAudio
        lock.unlock()
        if shouldStartSending { sendNextAudio() }
        AppLog.info("Bage Shuo ASR finish requested")
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        lock.lock()
        let socket = self.socket
        let session = socketSession
        let shouldClose = state != .disconnected || socket != nil
        state = .disconnected
        self.socket = nil
        socketSession = nil
        pendingAudio.removeAll()
        queuedAudio.removeAll()
        isSendingAudio = false
        readyForAudio = false
        finishRequested = false
        lock.unlock()
        guard shouldClose else { return }
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        AppLog.info("Bage Shuo ASR disconnected")
    }

    private func requestTicket(params: BageshuoASRParams) async throws -> BageshuoTicketInfo {
        let signedParameters = BageshuoSigner.signedParameters(
            context: BageshuoSigner.currentContext(deviceID: params.deviceID),
            nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        var components = URLComponents(
            url: Self.serverBaseURL.appendingPathComponent(Self.ticketPath),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = signedParameters.keys.sorted().compactMap { key in
            guard let value = signedParameters[key] else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        guard let url = components.url else {
            throw Self.makeError(code: 1, message: "Bage Shuo ticket URL could not be created")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        if let typelessUser = params.typelessUser {
            request.setValue(typelessUser, forHTTPHeaderField: "X-Typeless-User")
        }
        request.setValue(DoubaoClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://dict.youdao.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1,
            "capabilities": ["generationStreaming": true]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Self.makeError(code: 2, message: "Bage Shuo ticket response was invalid")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = Self.apiError(from: data)
            let serverMessage = apiError.message ?? ""
            let isAuth = httpResponse.statusCode == 401
                || Self.isAuthLikeError(
                    code: apiError.code ?? httpResponse.statusCode,
                    message: serverMessage
                )
            let message = isAuth
                ? "Bage Shuo login is required"
                : serverMessage.isEmpty
                    ? "Bage Shuo ticket request failed (HTTP \(httpResponse.statusCode))"
                    : "Bage Shuo ticket request failed: \(serverMessage)"
            var metadata = ["http_status": String(httpResponse.statusCode)]
            if let apiCode = apiError.code {
                metadata["server_code"] = String(apiCode)
            }
            throw Self.makeError(code: apiError.code ?? httpResponse.statusCode, message: message, metadata: metadata)
        }
        guard let ticketInfo = Self.ticketInfo(from: data) else {
            throw Self.makeError(code: 3, message: "Bage Shuo ticket response did not contain a valid ticket")
        }
        return ticketInfo
    }

    private func openSocket(ticketInfo: BageshuoTicketInfo) {
        lock.lock()
        guard state == .connecting || state == .finishing else {
            lock.unlock()
            return
        }
        maxAudioFrameBytes = ticketInfo.maxAudioFrameBytes
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let socket = session.webSocketTask(with: ticketInfo.websocketURL)
        socketSession = session
        self.socket = socket
        lock.unlock()

        AppLog.info("Bage Shuo ASR WebSocket connecting protocolVersion=\(ticketInfo.protocolVersion) maxFrameBytes=\(ticketInfo.maxAudioFrameBytes)")
        socket.resume()
        receive(socket: socket)
    }

    private func receive(socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            switch result {
            case .success(.string(let text)):
                if let event = Self.parseEvent(text) {
                    self.handle(event: event, socket: socket)
                } else {
                    AppLog.error("Bage Shuo ASR ignored malformed event")
                }
                self.receive(socket: socket)
            case .success(.data):
                self.receive(socket: socket)
            case .failure(let error):
                self.report(error: error)
            @unknown default:
                self.report(error: Self.makeError(code: 4, message: "Bage Shuo WebSocket returned an unknown message"))
            }
        }
    }

    private func handle(event: BageshuoRealtimeEvent, socket: URLSessionWebSocketTask) {
        guard event.version == 1 else {
            report(error: Self.makeError(code: 5, message: "Bage Shuo protocol version is unsupported"))
            return
        }

        switch event.type {
        case "connection.ready":
            lock.lock()
            guard state == .connecting || state == .finishing else {
                lock.unlock()
                return
            }
            state = finishRequested ? .finishing : .open
            let shouldNotify = !openCallbackSent
            openCallbackSent = true
            lock.unlock()
            if shouldNotify { onOpen?() }
            sendStartFrame(socket: socket)
        case "utterance.ready":
            lock.lock()
            readyForAudio = true
            if let serverLimit = Int(event.payload["maxAudioFrameBytes"] ?? "") {
                maxAudioFrameBytes = min(maxAudioFrameBytes, serverLimit)
            }
            movePendingAudioToQueueLocked()
            let shouldStartSending = !isSendingAudio
            lock.unlock()
            if shouldStartSending { sendNextAudio() }
        case "transcript.partial":
            let text = event.payload["fullText"] ?? ""
            onResult?(.bageshuo(text: text, kind: "partial", isFinal: false))
        case "transcript.final":
            let text = event.payload["rawText"] ?? event.payload["fullText"] ?? ""
            onResult?(.bageshuo(text: text, kind: "transcript_final", isFinal: true))
        case "generation.completed":
            let text = event.payload["resultText"] ?? ""
            let metadata = event.payload.filter { key, _ in
                ["generationId", "operation", "billedChars", "isSensitive"].contains(key)
            }
            onResult?(.bageshuo(text: text, kind: "generation_completed", isFinal: true, metadata: metadata))
            lock.lock()
            let shouldNotify = !finishCallbackSent
            finishCallbackSent = true
            state = .finished
            lock.unlock()
            if shouldNotify { onFinish?() }
            disconnect()
        case "generation.failed", "utterance.failed", "error":
            let code = event.payload["code"].flatMap(Int.init) ?? 500
            let message = event.payload["message"] ?? "Bage Shuo realtime recognition failed"
            report(error: Self.makeError(code: code, message: message))
        default:
            break
        }
    }

    private func sendStartFrame(socket: URLSessionWebSocketTask) {
        let payload: [String: Any] = [
            "operation": "POLISH",
            "sourceLanguage": "AUTO",
            "targetLanguage": NSNull(),
            "selectedText": NSNull(),
            "audio": [
                "encoding": Self.encoding,
                "sampleRateHz": Self.sampleRateHz,
                "channels": Self.channels
            ]
        ]
        sendControlFrame(
            socket: socket,
            type: "utterance.start",
            requestID: startRequestID,
            payload: payload
        )
    }

    private func sendNextAudio() {
        lock.lock()
        guard !isSendingAudio, readyForAudio,
              (state == .open || state == .finishing),
              let socket else {
            lock.unlock()
            return
        }
        guard !queuedAudio.isEmpty else {
            let shouldSendFinish = finishRequested && !finishFrameSent
            if shouldSendFinish { finishFrameSent = true }
            let sentBytes = sentAudioBytes
            lock.unlock()
            if shouldSendFinish {
                sendEndFrame(socket: socket, sentBytes: sentBytes)
            }
            return
        }

        let data = queuedAudio.removeFirst()
        isSendingAudio = true
        lock.unlock()
        socket.send(.data(data)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.report(error: error)
                return
            }
            self.lock.lock()
            self.isSendingAudio = false
            self.sentAudioBytes += data.count
            self.lock.unlock()
            self.sendNextAudio()
        }
    }

    private func sendEndFrame(socket: URLSessionWebSocketTask, sentBytes: Int) {
        let durationMilliseconds = Int((Double(sentBytes) / Double(Self.sampleRateHz * 2) * 1_000).rounded())
        sendControlFrame(
            socket: socket,
            type: "utterance.end",
            requestID: UUID().uuidString.lowercased(),
            payload: [
                "audioBytesSent": sentBytes,
                "audioDurationMs": durationMilliseconds
            ]
        )
        AppLog.info("Bage Shuo ASR utterance end sent audioBytes=\(sentBytes) audioDurationMs=\(durationMilliseconds)")
    }

    private func sendControlFrame(
        socket: URLSessionWebSocketTask,
        type: String,
        requestID: String,
        payload: [String: Any]
    ) {
        let frame = Self.controlFrame(
            type: type,
            requestID: requestID,
            utteranceID: utteranceID,
            payload: payload
        )
        socket.send(.string(frame)) { [weak self] error in
            if let error { self?.report(error: error) }
        }
    }

    private func movePendingAudioToQueueLocked() {
        guard !pendingAudio.isEmpty else { return }
        queuedAudio.append(contentsOf: pendingAudio)
        pendingAudio.removeAll()
    }

    private func report(error: Error) {
        let nsError = error as NSError
        let isAuth = Self.isAuthLikeError(code: nsError.code, message: nsError.localizedDescription)
        lock.lock()
        guard state != .disconnected, state != .finished else {
            lock.unlock()
            return
        }
        state = .failed
        let shouldNotify = !errorCallbackSent
        errorCallbackSent = true
        lock.unlock()
        guard shouldNotify else { return }
        if isAuth {
            onAuthError?(error)
        } else {
            onError?(error)
        }
        disconnect()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        AppLog.info("Bage Shuo WebSocket transport opened")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { report(error: error) }
    }

    static func controlFrame(
        type: String,
        requestID: String,
        utteranceID: String,
        payload: [String: Any]
    ) -> String {
        let object: [String: Any] = [
            "v": 1,
            "type": type,
            "requestId": requestID,
            "utteranceId": utteranceID,
            "payload": payload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func parseEvent(_ text: String) -> BageshuoRealtimeEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        let payloadObject = object["payload"] as? [String: Any] ?? [:]
        let payload = payloadObject.reduce(into: [String: String]()) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            } else if let value = item.value as? NSNumber {
                result[item.key] = value.stringValue
            }
        }
        return BageshuoRealtimeEvent(
            version: (object["v"] as? NSNumber)?.intValue ?? 0,
            type: type,
            eventID: object["eventId"] as? String ?? "",
            timestamp: object["timestamp"] as? String ?? "",
            payload: payload
        )
    }

    static func isAuthLikeError(code: Int, message: String) -> Bool {
        let containsAuthWord = message.localizedCaseInsensitiveContains("login")
            || message.localizedCaseInsensitiveContains("unauthorized")
            || message.localizedCaseInsensitiveContains("authentication")
            || message.localizedCaseInsensitiveContains("cookie")
            || message.contains("登录")
            || message.contains("认证")
            || message.contains("未授权")
        return code == 401 || containsAuthWord
    }

    static func apiError(from data: Data) -> (code: Int?, message: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let codeValue = object["errorCode"] ?? object["code"]
        let code: Int?
        if let number = codeValue as? NSNumber {
            code = number.intValue
        } else if let string = codeValue as? String {
            code = Int(string)
        } else {
            code = nil
        }
        let message = object["message"] as? String ?? object["msg"] as? String
        return (code, message)
    }

    private static func ticketInfo(from data: Data) -> BageshuoTicketInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dictionary = findTicketDictionary(root) else { return nil }
        guard let websocketString = dictionary["websocketUrl"] as? String,
              let websocketURL = URL(string: websocketString),
              websocketURL.scheme == "ws" || websocketURL.scheme == "wss",
              let ticket = dictionary["ticket"] as? String,
              !ticket.isEmpty else { return nil }
        let queryTicket = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "ticket"
        }?.value
        guard queryTicket == ticket else { return nil }

        let protocolVersion = (dictionary["protocolVersion"] as? NSNumber)?.intValue ?? 0
        guard protocolVersion == 1 else { return nil }
        let audioPolicy = dictionary["audioPolicy"] as? [String: Any] ?? [:]
        let encoding = audioPolicy["encoding"] as? String ?? ""
        let sampleRateHz = (audioPolicy["sampleRateHz"] as? NSNumber)?.intValue ?? 0
        let channels = (audioPolicy["channels"] as? NSNumber)?.intValue ?? 0
        guard encoding == Self.encoding, sampleRateHz == Self.sampleRateHz, channels == Self.channels else {
            return nil
        }
        let limits = dictionary["limits"] as? [String: Any] ?? [:]
        let maxAudioFrameBytes = max(
            1,
            (limits["maxAudioFrameBytes"] as? NSNumber)?.intValue ?? Self.defaultMaxAudioFrameBytes
        )
        return BageshuoTicketInfo(
            websocketURL: websocketURL,
            ticket: ticket,
            protocolVersion: protocolVersion,
            maxAudioFrameBytes: maxAudioFrameBytes,
            sampleRateHz: sampleRateHz,
            channels: channels,
            encoding: encoding
        )
    }

    private static func findTicketDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["websocketUrl"] != nil, dictionary["ticket"] != nil {
                return dictionary
            }
            for child in dictionary.values {
                if let found = findTicketDictionary(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findTicketDictionary(child) { return found }
            }
        }
        return nil
    }

    private static func makeError(
        code: Int,
        message: String,
        metadata: [String: String] = [:]
    ) -> NSError {
        NSError(
            domain: "Douvo.BageshuoASR",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                TranscriptionErrorMetadata.userInfoKey: metadata
            ]
        )
    }
}
