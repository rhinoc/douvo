import Foundation

enum TranscriptionErrorMetadata {
    static let userInfoKey = "Douvo.TranscriptionErrorMetadata"
}

struct TranscriptionSessionError: Error, LocalizedError, Sendable {
    let domain: String
    let code: Int
    let localizedDescription: String
    let metadata: [String: String]

    var errorDescription: String? {
        localizedDescription
    }

    init(_ error: Error?) {
        guard let error else {
            domain = "Douvo.ASR"
            code = 0
            localizedDescription = "unknown"
            metadata = [:]
            return
        }

        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        localizedDescription = nsError.localizedDescription
        metadata = nsError.userInfo[TranscriptionErrorMetadata.userInfoKey] as? [String: String] ?? [:]
    }

    init(
        domain: String,
        code: Int,
        localizedDescription: String,
        metadata: [String: String] = [:]
    ) {
        self.domain = domain
        self.code = code
        self.localizedDescription = localizedDescription
        self.metadata = metadata
    }
}

/// Weak reference wrapper for use in `Task.detached` closures that cannot capture actors directly.
private struct WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

enum TranscriptionSessionEvent: Sendable {
    case audioStarted
    case audioStartFailed(TranscriptionSessionError)
    case audioLevel(Float)
    case recordingSaved(String)
    case asrOpened(String)
    case asrResult(ASRRecognitionResult)
    case asrFinished(String)
    case asrError(String, TranscriptionSessionError?)
    case asrAuthError(String, TranscriptionSessionError?)
}

actor TranscriptionSession {
    typealias EventHandler = @MainActor @Sendable (TranscriptionSessionEvent) -> Void

    private let selection: ASRProviderSelection
    private let webASRClient: DoubaoASRClient?
    private let bageshuoASRClient: BageshuoASRClient?
    private let androidASRClient: DoubaoAndroidASRClient?
    private let chatterflyASRClient: ChatterflyASRClient?
    private let audioCapture: AudioCaptureManager
    private let onEvent: EventHandler
    private var audioStartTask: Task<Void, Never>?

    init(selection: ASRProviderSelection, onEvent: @escaping EventHandler) {
        let webASRClient = selection.usesWebASR ? DoubaoASRClient() : nil
        let bageshuoASRClient = selection.usesBageshuoASR ? BageshuoASRClient() : nil
        let androidASRClient = selection.usesAndroidASR ? DoubaoAndroidASRClient() : nil
        let chatterflyASRClient = selection.usesChatterflyASR ? ChatterflyASRClient() : nil
        let audioCapture = AudioCaptureManager()
        self.selection = selection
        self.webASRClient = webASRClient
        self.bageshuoASRClient = bageshuoASRClient
        self.androidASRClient = androidASRClient
        self.chatterflyASRClient = chatterflyASRClient
        self.audioCapture = audioCapture
        self.onEvent = onEvent

        let onResult: @Sendable (ASRRecognitionResult) -> Void = { [weak self] result in
            Task { await self?.emit(.asrResult(result)) }
        }

        webASRClient?.onOpen = { [weak self] in
            Task { await self?.emit(.asrOpened("web")) }
        }
        webASRClient?.onResult = onResult
        webASRClient?.onFinish = { [weak self] in
            Task { await self?.emit(.asrFinished("web")) }
        }
        webASRClient?.onError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrError("web", info)) }
        }
        webASRClient?.onAuthError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrAuthError("web", info)) }
        }

        bageshuoASRClient?.onOpen = { [weak self] in
            Task { await self?.emit(.asrOpened("bageshuo")) }
        }
        bageshuoASRClient?.onResult = onResult
        bageshuoASRClient?.onFinish = { [weak self] in
            Task { await self?.emit(.asrFinished("bageshuo")) }
        }
        bageshuoASRClient?.onError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrError("bageshuo", info)) }
        }
        bageshuoASRClient?.onAuthError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrAuthError("bageshuo", info)) }
        }

        androidASRClient?.onOpen = { [weak self] in
            Task { await self?.emit(.asrOpened("android")) }
        }
        androidASRClient?.onResult = onResult
        androidASRClient?.onFinish = { [weak self] in
            Task { await self?.emit(.asrFinished("android")) }
        }
        androidASRClient?.onError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrError("android", info)) }
        }
        androidASRClient?.onAuthError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrAuthError("android", info)) }
        }

        chatterflyASRClient?.onOpen = { [weak self] in
            Task {
                await self?.emit(.asrOpened("chatterfly"))
            }
        }
        chatterflyASRClient?.onResult = onResult
        chatterflyASRClient?.onFinish = { [weak self] in
            Task { await self?.emit(.asrFinished("chatterfly")) }
        }
        chatterflyASRClient?.onError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrError("chatterfly", info)) }
        }
        chatterflyASRClient?.onAuthError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrAuthError("chatterfly", info)) }
        }
        chatterflyASRClient?.onLevel = { [weak self] level in
            Task { await self?.emit(.audioLevel(level)) }
        }

        audioCapture.onWebPCMData = { [weak webASRClient] data in
            webASRClient?.sendAudio(data)
        }
        audioCapture.onBageshuoPCMData = { [weak bageshuoASRClient] data in
            bageshuoASRClient?.sendAudio(data)
        }
        audioCapture.onAndroidOpusData = { [weak androidASRClient, weak chatterflyASRClient] data in
            androidASRClient?.sendAudio(data)
            chatterflyASRClient?.sendAudio(data)
        }
        audioCapture.onLevel = { [weak self] level in
            Task { await self?.emit(.audioLevel(level)) }
        }
    }

    func start(
        webParams: DoubaoASRParams?,
        bageshuoParams: BageshuoASRParams?,
        androidContext: String = "",
        androidVocabulary: String = ""
    ) async throws {
        audioStartTask?.cancel()
        audioStartTask = nil

        if selection.usesWebASR {
            guard let webParams, let webASRClient else {
                throw NSError(domain: "Douvo.ASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Web recognition parameters are missing"])
            }
            webASRClient.connect(params: webParams)
        }

        if selection.usesBageshuoASR {
            guard let bageshuoParams, let bageshuoASRClient else {
                throw NSError(domain: "Douvo.BageshuoASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Bage Shuo recognition parameters are missing"])
            }
            bageshuoASRClient.connect(params: bageshuoParams)
        }

        var androidConnected = false
        if selection.usesAndroidASR {
            guard let androidASRClient else {
                throw NSError(domain: "Douvo.ASR", code: 11, userInfo: [NSLocalizedDescriptionKey: "Android recognition client is unavailable"])
            }
            do {
                let credentials = try await DoubaoAndroidCredentialStore.ensureCredentials()
                let usePersonalLexicon = await preparePersonalLexicon(
                    vocabulary: androidVocabulary,
                    credentials: credentials
                )
                try await androidASRClient.connect(
                    credentials: credentials,
                    context: androidContext,
                    usePersonalLexicon: usePersonalLexicon
                )
                androidConnected = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                await emit(.asrError("android", TranscriptionSessionError(error)))
            }
        }

        if selection.usesChatterflyASR {
            guard let chatterflyASRClient else {
                throw NSError(domain: "Douvo.ChatterflyASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Chatterfly recognition client is unavailable"])
            }
            chatterflyASRClient.connect()
        }

        if !selection.usesWebASR && !selection.usesBageshuoASR && !androidConnected && !selection.usesChatterflyASR {
            throw NSError(domain: "Douvo.ASR", code: 12, userInfo: [NSLocalizedDescriptionKey: "No ASR provider connected"])
        }

        var captureMode = AudioCaptureManager.CaptureMode()
        if selection.usesWebASR { captureMode.insert(.webPCM) }
        if selection.usesBageshuoASR { captureMode.insert(.bageshuoPCM) }
        if selection.usesAndroidASR { captureMode.insert(.androidOpus) }
        if selection.usesChatterflyASR { captureMode.insert(.androidOpus) }

        if captureMode.isEmpty {
            return
        }

        let audioCapture = self.audioCapture
        let weakSelf = WeakRef(self)
        let webASRClient = self.webASRClient
        let bageshuoASRClient = self.bageshuoASRClient
        let androidASRClient = self.androidASRClient
        let chatterflyASRClient = self.chatterflyASRClient
        audioStartTask = Task.detached {
            do {
                try Task.checkCancellation()
                try audioCapture.startCapture(mode: captureMode)
                try Task.checkCancellation()
                await weakSelf.value?.emit(.audioStarted)
            } catch is CancellationError {
                _ = audioCapture.stopCapture()
            } catch {
                guard !Task.isCancelled else {
                    _ = audioCapture.stopCapture()
                    return
                }
                webASRClient?.disconnect()
                bageshuoASRClient?.disconnect()
                androidASRClient?.finishSessionThenDisconnect()
                chatterflyASRClient?.disconnect()
                await weakSelf.value?.emit(.audioStartFailed(TranscriptionSessionError(error)))
            }
        }
    }

    private func preparePersonalLexicon(
        vocabulary: String,
        credentials: DoubaoAndroidCredentials
    ) async -> Bool {
        let words = DoubaoAndroidPersonalLexicon.words(from: vocabulary)
        guard !words.isEmpty else { return false }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await DoubaoAndroidPersonalLexiconSynchronizer.shared.sync(
                vocabulary: vocabulary,
                credentials: credentials
            )
            let duration = Int(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            AppLog.info("Android personal lexicon ready words=\(result.wordCount) uploaded=\(result.uploaded) durationMs=\(duration)")
        } catch {
            AppLog.error("Android personal lexicon sync failed words=\(words.count) error=\(error.localizedDescription)")
        }
        // Previously uploaded account words remain useful if a refresh fails.
        return true
    }

    func stop() async -> URL? {
        audioStartTask?.cancel()
        audioStartTask = nil
        let recordingURL = audioCapture.stopCapture()
        if let recordingURL {
            await emit(.recordingSaved(recordingURL.path))
        }
        webASRClient?.finishSending()
        bageshuoASRClient?.finishSending()
        androidASRClient?.finishSending()
        chatterflyASRClient?.finishSending()
        return recordingURL
    }

    func cancel() {
        audioStartTask?.cancel()
        audioStartTask = nil
        _ = audioCapture.stopCapture()
        webASRClient?.disconnect()
        bageshuoASRClient?.disconnect()
        androidASRClient?.finishSessionThenDisconnect()
        chatterflyASRClient?.disconnect()
    }

    private func emit(_ event: TranscriptionSessionEvent) async {
        await onEvent(event)
    }
}
