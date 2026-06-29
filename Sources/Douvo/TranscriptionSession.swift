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
    case asrAuthError(String)
}

actor TranscriptionSession {
    typealias EventHandler = @MainActor @Sendable (TranscriptionSessionEvent) -> Void

    private let provider: ASRProvider
    private let webASRClient: DoubaoASRClient?
    private let androidASRClient: DoubaoAndroidASRClient?
    private let audioCapture: AudioCaptureManager
    private let onEvent: EventHandler
    private var audioStartTask: Task<Void, Never>?

    init(provider: ASRProvider, onEvent: @escaping EventHandler) {
        let webASRClient = provider.usesWebASR ? DoubaoASRClient() : nil
        let androidASRClient = provider.usesAndroidASR ? DoubaoAndroidASRClient() : nil
        let audioCapture = AudioCaptureManager()
        self.provider = provider
        self.webASRClient = webASRClient
        self.androidASRClient = androidASRClient
        self.audioCapture = audioCapture
        self.onEvent = onEvent

        let onResult: (ASRRecognitionResult) -> Void = { [weak self] result in
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
        webASRClient?.onAuthError = { [weak self] in
            Task { await self?.emit(.asrAuthError("web")) }
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
        androidASRClient?.onAuthError = { [weak self] in
            Task { await self?.emit(.asrAuthError("android")) }
        }

        audioCapture.onWebPCMData = { [weak webASRClient] data in
            webASRClient?.sendAudio(data)
        }
        audioCapture.onAndroidOpusData = { [weak androidASRClient] data in
            androidASRClient?.sendAudio(data)
        }
        audioCapture.onLevel = { [weak self] level in
            Task { await self?.emit(.audioLevel(level)) }
        }
    }

    func start(webParams: DoubaoASRParams?) async throws {
        audioStartTask?.cancel()
        audioStartTask = nil

        switch provider {
        case .web:
            guard let webParams, let webASRClient else {
                throw NSError(domain: "Douvo.ASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Web recognition parameters are missing"])
            }
            webASRClient.connect(params: webParams)
            let audioCapture = self.audioCapture
            let weakSelf = WeakRef(self)
            audioStartTask = Task.detached {
                do {
                    try Task.checkCancellation()
                    try audioCapture.startCapture(mode: .webPCM)
                    try Task.checkCancellation()
                    await weakSelf.value?.emit(.audioStarted)
                } catch is CancellationError {
                    _ = audioCapture.stopCapture()
                } catch {
                    guard !Task.isCancelled else {
                        _ = audioCapture.stopCapture()
                        return
                    }
                    webASRClient.disconnect()
                    await weakSelf.value?.emit(.audioStartFailed(TranscriptionSessionError(error)))
                }
            }
        case .android:
            guard let androidASRClient else {
                throw NSError(domain: "Douvo.ASR", code: 11, userInfo: [NSLocalizedDescriptionKey: "Android recognition client is unavailable"])
            }
            let credentials = try await DoubaoAndroidCredentialStore.ensureCredentials()
            androidASRClient.connect(credentials: credentials)
            let audioCapture = self.audioCapture
            let weakSelf = WeakRef(self)
            audioStartTask = Task.detached {
                do {
                    try Task.checkCancellation()
                    try audioCapture.startCapture(mode: .androidOpus)
                    try Task.checkCancellation()
                    await weakSelf.value?.emit(.audioStarted)
                } catch is CancellationError {
                    _ = audioCapture.stopCapture()
                } catch {
                    guard !Task.isCancelled else {
                        _ = audioCapture.stopCapture()
                        return
                    }
                    androidASRClient.disconnect()
                    await weakSelf.value?.emit(.audioStartFailed(TranscriptionSessionError(error)))
                }
            }
        case .mix:
            guard let webParams, let webASRClient, let androidASRClient else {
                throw NSError(domain: "Douvo.ASR", code: 12, userInfo: [NSLocalizedDescriptionKey: "Dual recognition clients are unavailable"])
            }
            let androidCredentials: DoubaoAndroidCredentials?
            do {
                androidCredentials = try await DoubaoAndroidCredentialStore.ensureCredentials()
            } catch {
                androidCredentials = nil
                await emit(.asrError("android", TranscriptionSessionError(error)))
            }
            webASRClient.connect(params: webParams)
            if let androidCredentials {
                androidASRClient.connect(credentials: androidCredentials)
            }
            let weakSelf = WeakRef(self)
            let audioCapture = self.audioCapture
            let captureMode: AudioCaptureManager.CaptureMode = androidCredentials == nil
                ? .webPCM
                : .webPCMAndAndroidOpus
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
                    webASRClient.disconnect()
                    androidASRClient.disconnect()
                    await weakSelf.value?.emit(.audioStartFailed(TranscriptionSessionError(error)))
                }
            }
        }
    }

    func stop() async -> URL? {
        audioStartTask?.cancel()
        audioStartTask = nil
        let recordingURL = audioCapture.stopCapture()
        if let recordingURL {
            await emit(.recordingSaved(recordingURL.path))
        }
        webASRClient?.finishSending()
        androidASRClient?.finishSending()
        return recordingURL
    }

    func cancel() {
        audioStartTask?.cancel()
        audioStartTask = nil
        _ = audioCapture.stopCapture()
        webASRClient?.disconnect()
        androidASRClient?.disconnect()
    }

    private func emit(_ event: TranscriptionSessionEvent) async {
        await onEvent(event)
    }
}
