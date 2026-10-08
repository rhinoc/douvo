import CommonCrypto
import Foundation

final class ChatterflyASRClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable () -> Void)?
    var onResult: (@Sendable (ASRRecognitionResult) -> Void)?
    var onFinish: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var onAuthError: (@Sendable (Error) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?

    private static let endpoint = URL(string: "wss://srss.chatterfly.tencent.com/srss/v1/speech/streaming_recognize")!
    private static let callbackQueue = DispatchQueue.main
    private let queue = DispatchQueue(label: "Douvo.ChatterflyASR")
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var pendingPackets = [Data]()
    private var didOpen = false
    private var didFinish = false
    private var didReportError = false
    private var isStopping = false
    private var stableResultText = ""
    private var temporaryResultText = ""

    func connect() {
        queue.async { [weak self] in
            self?.begin()
        }
    }

    func sendAudio(_ opusPacket: Data) {
        guard !opusPacket.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            let framedPacket = Self.frame(opusPacket)
            guard self.didOpen, let webSocket = self.webSocket else {
                self.pendingPackets.append(framedPacket)
                return
            }
            self.sendBinary(framedPacket, over: webSocket)
        }
    }

    func finishSending() {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.isStopping = true
            guard let webSocket = self.webSocket else {
                self.finish()
                return
            }
            webSocket.send(.string("{}")) { [self] error in
                self.queue.async {
                    if let error {
                        fputs("Chatterfly ASR stop error=\(error.localizedDescription)\n", stderr)
                        self.report(error)
                    }
                }
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.disconnectOnQueue()
        }
    }

    private func begin() {
        guard webSocket == nil, !didFinish else { return }
        didReportError = false
        didOpen = false
        isStopping = false
        stableResultText = ""
        temporaryResultText = ""
        pendingPackets.removeAll(keepingCapacity: true)

        guard let token = ChatterflyAuthTokenStore.accessToken, !token.isEmpty else {
            report(
                Self.makeError("Chatterfly 登录凭据不存在，请先登录 Chatterfly"),
                authenticationFailure: true
            )
            return
        }
        let vocabularyWords = DoubaoAndroidPersonalLexicon.words(
            from: LocalLLMSettingsStore.effectiveVocabulary
        )
        let configuration = Self.nativeConfiguration(speechTerms: vocabularyWords)
        do {
            let json = try JSONSerialization.data(withJSONObject: configuration, options: [])
            let redactedConfiguration = Self.redactedConfiguration(
                configuration,
                vocabularyWordCount: vocabularyWords.count
            )
            if let redactedJSON = try? JSONSerialization.data(withJSONObject: redactedConfiguration, options: [.sortedKeys]),
               let redactedString = String(data: redactedJSON, encoding: .utf8) {
                fputs("Chatterfly ASR redactedConfig=\(redactedString)\n", stderr)
            }
            let material = try ChatterflyCrypto.encryptASRConfiguration(json)
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "GET"
            request.setValue("1", forHTTPHeaderField: "X-Srss-Cipher-Key-Type")
            request.setValue(material.encryptedKey, forHTTPHeaderField: "X-Srss-Cipher-Key-Sec")
            request.setValue(material.encodedIV, forHTTPHeaderField: "X-Srss-Cipher-Key-Vec")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            urlSession = session
            webSocket = session.webSocketTask(with: request)
            pendingConfiguration = material.encryptedConfiguration
            let tokenDigest = token.data(using: .utf8).map { data -> String in
                var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
                return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            } ?? "none"
            fputs("Chatterfly ASR connect tokenChars=\(token.count) tokenSha256=\(tokenDigest) configBytes=\(json.count) cipherBytes=\(material.encryptedConfiguration.count) rsaKeyChars=\(material.encryptedKey.count) ivChars=\(material.encodedIV.count)\n", stderr)
            webSocket?.resume()
            receiveNext()
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, !self.didOpen, !self.didReportError else { return }
                self.report(Self.makeError("Chatterfly 原生 ASR WebSocket 未打开"))
            }
        } catch {
            report(error)
        }
    }

    private var pendingConfiguration = ""

    static func nativeConfiguration(speechTerms: [String]) -> [String: Any] {
        let deviceUUID = ChatterflyEncryptWallClient.nativeASRDeviceID()
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion).\(operatingSystemVersion.patchVersion)"
        let speechContexts: [[String: Any]] = speechTerms.isEmpty ? [] : [
            [
                "instants": ["phrases": speechTerms]
            ]
        ]
        return [
            "config": [
                "client_itn_switch": true,
                "convert_number": true,
                "custom_info": [:],
                "enable_ambient_sound_event": false,
                "enable_word_time_offsets": false,
                "encoding": "OPUS_WITH_HEADER",
                "functions_switch": [
                    "enable_streaming_punctuations": "1",
                    "short_utterance_switch": "0",
                    "voice_multi_cands_3de": "1",
                    "voice_multi_cands_3ta": "1"
                ],
                "language_code": "zh-cmn-Hans-CN",
                "metadata": [
                    "client_info": [
                        "product_category": "sogou_ime",
                        "product_id": "macos_trunk",
                        "product_version": "1.0.4.13386"
                    ],
                    "host_device_info": [
                        "device_aid": deviceUUID,
                        "device_category": "pc",
                        "device_qid": deviceUUID,
                        "device_uuid": deviceUUID,
                    ],
                    "host_os_info": [
                        "os_category": "darwin",
                        "os_id": "UNSPECIFIED",
                        "os_version": osVersion
                    ],
                    "network_info": ["network_type": "ETHERNET"],
                    "runtime_info": [
                        "consumer_input_type": "UNSPECIFIED",
                        "consumer_product_id": "UNSPECIFIED",
                        "consumer_purpose": "UNSPECIFIED"
                    ],
                    "sdk_info": [
                        "sdk_category": "sogou_ime",
                        "sdk_id": "macOS",
                        "sdk_version": "v1.9.4"
                    ],
                    "user_info": [
                        "user_category": "anonymous",
                        "user_ceip": false,
                        "user_id": "anonymous"
                    ],
                    "audio_info": [
                        "audio_id": "douvo-live-session",
                        "audio_slice_id": "douvo-live-session-1"
                    ]
                ],
                "model": "default",
                "original_audio": false,
                "punctuation_mode": "NORMAL_PUNCTUATION",
                "result_form": "ONLY_ONE",
                "speech_contexts": speechContexts,
                "unit_symbol_type": 1,
                "user_feature": [
                    "app_id": 0,
                    "context": "{\"app_name\":\"\",\"windows_title\":\"\"}"
                ]
            ],
            "interim_results": true,
            "single_utterance": false
        ]
    }

    private static func redactedConfiguration(
        _ configuration: [String: Any],
        vocabularyWordCount: Int
    ) -> [String: Any] {
        var redacted = configuration
        guard var config = redacted["config"] as? [String: Any] else { return redacted }
        config["speech_contexts"] = "<\(vocabularyWordCount) vocabulary terms redacted>"
        redacted["config"] = config
        return redacted
    }

    private func report(_ error: Error, authenticationFailure: Bool = false) {
        guard !didReportError, !didFinish else { return }
        didReportError = true
        let callback = errorCallback(for: error, authenticationFailure: authenticationFailure)
        Self.callbackQueue.async(execute: callback)
    }

    private func errorCallback(for error: Error, authenticationFailure: Bool) -> @Sendable () -> Void {
        let callback = authenticationFailure ? (onAuthError ?? onError) : onError
        return { callback?(error) }
    }

    private func receiveNext() {
        guard let webSocket, !didFinish else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(message):
                    self.handle(message: message)
                    self.receiveNext()
                case let .failure(error):
                    if self.isStopping {
                        self.finish()
                    } else {
                        self.report(error)
                    }
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(value): data = value.data(using: .utf8)
        case let .data(value): data = value
        @unknown default: data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        if let dictionary = object as? [String: Any], let errorValue = dictionary["error"] {
            let errorDictionary = errorValue as? [String: Any]
            let message = Self.stringValue(errorValue)
                ?? Self.stringValue(errorDictionary?["message"])
                ?? Self.stringValue(errorDictionary?["msg"])
                ?? Self.stringValue(dictionary["message"])
                ?? "Chatterfly 原生 ASR 返回错误"
            let code = Self.intValue(errorDictionary?["code"])
                ?? Self.intValue(dictionary["code"])
                ?? 1
            fputs("Chatterfly ASR server error code=\(code) message=\(message)\n", stderr)
            report(
                Self.makeError("\(message) (code=\(code))", code: code),
                authenticationFailure: Self.isAuthenticationFailureCode(code)
            )
            return
        }
        guard let update = Self.resultUpdate(from: object) else { return }
        if let replacementText = update.replacementText {
            stableResultText = replacementText
            temporaryResultText = ""
        } else {
            if let stableFragment = update.stableTextDelta {
                stableResultText.append(stableFragment)
            }
            if let temporaryText = update.temporaryText {
                temporaryResultText = temporaryText
            }
        }
        let text = stableResultText + temporaryResultText
        if !text.isEmpty {
            fputs("Chatterfly ASR result chars=\(text.count) final=\(update.isFinal)\n", stderr)
            callback { [weak self] in
                self?.onResult?(Self.makeResult(text: text, isFinal: update.isFinal))
            }
        }
        if isStopping && update.isFinal {
            finish()
        }
    }

    private func callback(_ block: @escaping @Sendable () -> Void) {
        Self.callbackQueue.async(execute: block)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        callback { [weak self] in
            self?.onFinish?()
        }
    }

    private func disconnectOnQueue() {
        didFinish = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        pendingPackets.removeAll()
    }

    private func sendBinary(_ data: Data, over webSocket: URLSessionWebSocketTask) {
        webSocket.send(.data(data)) { [self] error in
            guard let error else { return }
            self.queue.async { self.report(error) }
        }
    }

    private func flushPendingPackets() {
        guard let webSocket else { return }
        if !pendingConfiguration.isEmpty {
            let configuration = pendingConfiguration
            pendingConfiguration = ""
            webSocket.send(.string(configuration)) { [self] error in
                if let error {
                    fputs("Chatterfly ASR config send error=\(error.localizedDescription)\n", stderr)
                    self.queue.async { self.report(error) }
                }
            }
        }
        let packets = pendingPackets
        pendingPackets.removeAll(keepingCapacity: true)
        for packet in packets {
            sendBinary(packet, over: webSocket)
        }
    }

    private static func frame(_ packet: Data) -> Data {
        var frame = Data([UInt8((packet.count >> 8) & 0xff), UInt8(packet.count & 0xff)])
        frame.append(packet)
        return frame
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didOpen = true
            fputs("Chatterfly ASR websocket opened\n", stderr)
            self.flushPendingPackets()
            self.callback { [weak self] in self?.onOpen?() }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            if self.isStopping {
                self.finish()
            } else if let response = webSocketTask.response as? HTTPURLResponse,
                      response.statusCode == 401 || response.statusCode == 403 {
                self.report(
                    Self.makeError("Chatterfly 原生 ASR 登录已失效 (HTTP \(response.statusCode))", code: response.statusCode),
                    authenticationFailure: true
                )
            } else {
                fputs("Chatterfly ASR websocket closed code=\(closeCode.rawValue)\n", stderr)
                self.report(Self.makeError("Chatterfly 原生 ASR WebSocket 已关闭 (code=\(closeCode.rawValue))"))
            }
        }
    }

    private struct RecognitionUpdate {
        let stableTextDelta: String?
        let temporaryText: String?
        let replacementText: String?
        let isFinal: Bool
    }

    private static func resultUpdate(from object: Any) -> RecognitionUpdate? {
        guard let dictionary = object as? [String: Any] else { return nil }
        return resultUpdate(from: dictionary)
    }

    private static func resultUpdate(
        from dictionary: [String: Any],
        inheritedFinal: Bool = false
    ) -> RecognitionUpdate? {
        let isFinal = boolValue(dictionary["is_final"])
            ?? boolValue(dictionary["isFinal"])
            ?? inheritedFinal

        if let finalText = stringValueIncludingEmpty(dictionary["final_result"]) {
            return RecognitionUpdate(
                stableTextDelta: nil,
                temporaryText: nil,
                replacementText: finalText,
                isFinal: true
            )
        }

        let stableText = stringValueIncludingEmpty(dictionary["stable_result"])
        let temporaryText = stringValueIncludingEmpty(dictionary["temp_result"])
        if stableText != nil || temporaryText != nil || isFinal {
            return RecognitionUpdate(
                stableTextDelta: stableText,
                temporaryText: temporaryText,
                replacementText: nil,
                isFinal: isFinal
            )
        }

        for key in ["transcript", "text", "content", "result"] {
            if let text = nonEmptyString(dictionary[key]) {
                return RecognitionUpdate(
                    stableTextDelta: nil,
                    temporaryText: nil,
                    replacementText: text,
                    isFinal: isFinal
                )
            }
        }

        if let results = dictionary["results"] as? [[String: Any]] {
            for result in results {
                let resultFinal = boolValue(result["is_final"])
                    ?? boolValue(result["isFinal"])
                    ?? isFinal
                if let update = resultUpdate(from: result, inheritedFinal: resultFinal) {
                    return update
                }
                if let alternatives = result["alternatives"] as? [[String: Any]],
                   let alternative = alternatives.first {
                    for key in ["transcript", "text", "content"] {
                        if let text = nonEmptyString(alternative[key]) {
                            return RecognitionUpdate(
                                stableTextDelta: nil,
                                temporaryText: nil,
                                replacementText: text,
                                isFinal: resultFinal
                            )
                        }
                    }
                }
            }
        }

        return isFinal
            ? RecognitionUpdate(
                stableTextDelta: nil,
                temporaryText: nil,
                replacementText: nil,
                isFinal: true
            )
            : nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func stringValueIncludingEmpty(_ value: Any?) -> String? {
        value as? String
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func isAuthenticationFailureCode(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 40103
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1"].contains(value.lowercased()) }
        return nil
    }

    private static func makeResult(text: String, isFinal: Bool) -> ASRRecognitionResult {
        ASRRecognitionResult(
            text: text,
            provider: "chatterfly",
            kind: isFinal ? "final" : "partial",
            segmentCount: text.isEmpty ? 0 : 1,
            isFinal: isFinal,
            metadata: ["chatterfly_source": "native_websocket"],
            segments: []
        )
    }

    private static func makeError(_ description: String, code: Int = 1) -> NSError {
        NSError(
            domain: "Douvo.ChatterflyASR",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
