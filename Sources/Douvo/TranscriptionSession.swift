import Foundation

struct TranscriptionSessionError: Sendable {
    let domain: String
    let code: Int
    let localizedDescription: String

    init(_ error: Error?) {
        guard let error else {
            domain = "Douvo.ASR"
            code = 0
            localizedDescription = "unknown"
            return
        }

        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        localizedDescription = nsError.localizedDescription
    }
}

enum TranscriptionSessionEvent: Sendable {
    case audioStarted
    case audioLevel(Float)
    case asrOpened
    case asrResult(String)
    case asrFinished
    case asrError(TranscriptionSessionError?)
    case asrAuthError
}

actor TranscriptionSession {
    typealias EventHandler = @MainActor @Sendable (TranscriptionSessionEvent) -> Void

    private let asrClient: DoubaoASRClient
    private let audioCapture: AudioCaptureManager
    private let onEvent: EventHandler

    init(onEvent: @escaping EventHandler) {
        let asrClient = DoubaoASRClient()
        let audioCapture = AudioCaptureManager()
        self.asrClient = asrClient
        self.audioCapture = audioCapture
        self.onEvent = onEvent

        asrClient.onOpen = { [weak self] in
            Task { await self?.emit(.asrOpened) }
        }
        asrClient.onResult = { [weak self] text in
            Task { await self?.emit(.asrResult(text)) }
        }
        asrClient.onFinish = { [weak self] in
            Task { await self?.emit(.asrFinished) }
        }
        asrClient.onError = { [weak self] error in
            let info = TranscriptionSessionError(error)
            Task { await self?.emit(.asrError(info)) }
        }
        asrClient.onAuthError = { [weak self] in
            Task { await self?.emit(.asrAuthError) }
        }

        audioCapture.onAudioData = { [asrClient] data in
            asrClient.sendAudio(data)
        }
        audioCapture.onLevel = { [weak self] level in
            Task { await self?.emit(.audioLevel(level)) }
        }
    }

    func start(params: DoubaoASRParams) async throws {
        try audioCapture.startCapture()
        await emit(.audioStarted)
        asrClient.connect(params: params)
    }

    func stop() {
        audioCapture.stopCapture()
        asrClient.finishSending()
    }

    func cancel() {
        audioCapture.stopCapture()
        asrClient.disconnect()
    }

    private func emit(_ event: TranscriptionSessionEvent) async {
        await onEvent(event)
    }
}
