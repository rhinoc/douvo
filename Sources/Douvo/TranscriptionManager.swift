import Foundation

@MainActor
final class TranscriptionManager {
    private static let noRecognizedTextMessage = "没有识别到文字"
    private static let noRecognizedSpeechMessage = "没有识别到语音"
    private static let authExpiredMessage = "登录已过期，请重新登录"

    private let appState: AppState
    private let webViewManager: WebViewManager
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let asrClient = DoubaoASRClient()
    private let audioCapture = AudioCaptureManager()

    private var usingCachedParams = false
    private var awaitingFinalResult = false
    private var isHandlingConnectionError = false

    private var stopFinalizationWork: DispatchWorkItem?
    private var quietCompletionWork: DispatchWorkItem?
    private var hardCompletionWork: DispatchWorkItem?
    // Keep the mic alive briefly after stop so the last hardware/input-buffered syllable
    // reaches the ASR stream before we flush tail silence and send finish.
    private let stopCaptureTailDelay: TimeInterval = 0.15
    // After the user stops, wait this long with no new results before submitting.
    private let finalQuietInterval: TimeInterval = 1.5
    // Absolute cap on how long we keep spinning after stop, in case finish never arrives.
    private let finalHardTimeout: TimeInterval = 12

    var onAuthExpired: (() -> Void)?
    var onStateChanged: (() -> Void)?

    init(
        appState: AppState,
        webViewManager: WebViewManager,
        overlayPanel: OverlayPanel,
        hotkeyManager: HotkeyManager
    ) {
        self.appState = appState
        self.webViewManager = webViewManager
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
    }

    func start() {
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("Hotkey event received event=\(event)")
                switch event {
                case .toggleRecording:
                    self.toggleRecording()
                case .holdRecordingStarted:
                    self.startRecordingFromHold()
                case .holdRecordingEnded:
                    self.stopRecordingFromHold()
                case .cancel:
                    self.cancelRecording()
                }
            }
        }

        asrClient.onOpen = { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.recordingState == .starting else { return }
                AppLog.info("ASR open; recording state -> recording")
                self.setRecordingState(.recording)
            }
        }

        asrClient.onResult = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("ASR result chars=\(text.count) text=\"\(Self.preview(text))\"")
                if Self.isNonInputStatusMessage(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    if self.awaitingFinalResult || self.appState.recordingState == .stopping {
                        self.completeWithoutRecognizedText()
                    } else {
                        self.appState.errorMessage = Self.noRecognizedTextMessage
                        self.appState.transcript = ""
                    }
                    return
                }
                self.appState.transcript = text
                if self.appState.recordingState == .starting {
                    self.setRecordingState(.recording)
                }
                // While finishing, keep waiting for the recognizer to catch up on the
                // tail of the audio. Each new result means it is still producing output,
                // so push the quiet-completion deadline out instead of submitting early.
                if self.awaitingFinalResult {
                    self.scheduleQuietCompletion()
                }
            }
        }

        asrClient.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("ASR finish event received")
                if self.appState.recordingState == .stopping || self.appState.recordingState == .recording {
                    self.completeTranscription()
                }
            }
        }

        asrClient.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.appState.recordingState != .idle, !self.isHandlingConnectionError else { return }
                self.isHandlingConnectionError = true
                AppLog.error("ASR connection error state=\(self.appState.recordingState) error=\(error?.localizedDescription ?? "unknown")")
                self.awaitingFinalResult = false
                self.cancelFinalTimers()
                self.audioCapture.stopCapture()
                self.asrClient.disconnect()

                let recognized = self.appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !recognized.isEmpty {
                    // We already have text; keep it rather than surfacing a raw socket error.
                    self.completeTranscription()
                } else if Self.isBenignDisconnect(error) {
                    self.completeWithoutRecognizedText()
                } else {
                    self.appState.errorMessage = "网络连接中断，请重试"
                    self.resetToIdle(after: 1.8)
                }
            }
        }

        asrClient.onAuthError = { [weak self] in
            Task { @MainActor in
                AppLog.error("ASR auth error")
                self?.handleAuthFailure()
            }
        }

        audioCapture.onAudioData = { [weak self] data in
            self?.asrClient.sendAudio(data)
        }

        audioCapture.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.appState.pushAudioLevel(level)
            }
        }

        appState.onCancelTapped = { [weak self] in
            self?.cancelRecording()
        }

        appState.onSubmitTapped = { [weak self] in
            self?.submitRecording()
        }

        hotkeyManager.start()
    }

    private func toggleRecording() {
        AppLog.info("Toggle recording currentState=\(appState.recordingState)")
        switch appState.recordingState {
        case .idle:
            startRecording()
        case .starting, .recording:
            stopRecording()
        case .stopping:
            break
        }
    }

    private func startRecordingFromHold() {
        AppLog.info("Hold recording start currentState=\(appState.recordingState)")
        guard appState.recordingState == .idle else { return }
        startRecording()
    }

    private func stopRecordingFromHold() {
        AppLog.info("Hold recording stop currentState=\(appState.recordingState)")
        switch appState.recordingState {
        case .starting, .recording:
            stopRecording()
        case .idle, .stopping:
            break
        }
    }

    private func startRecording() {
        AppLog.info("Start recording requested loginStatus=\(appState.loginStatus)")
        isHandlingConnectionError = false
        setRecordingState(.starting)
        appState.transcript = ""
        appState.errorMessage = nil
        appState.resetAudioLevels()
        overlayPanel.show()

        guard appState.loginStatus == .loggedIn else {
            AppLog.error("Start blocked: not logged in")
            appState.errorMessage = "请先登录豆包"
            webViewManager.showLoginWindow()
            resetToIdle(after: 1.5)
            return
        }

        guard let params = ASRParamsStore.load() else {
            AppLog.error("Start blocked: ASR params missing")
            appState.errorMessage = "登录参数缺失，请重新登录"
            appState.loginStatus = .notLoggedIn
            webViewManager.showLoginWindow()
            resetToIdle(after: 1.5)
            return
        }

        do {
            try audioCapture.startCapture()
            AppLog.info("Audio capture started")
        } catch {
            AppLog.error("Audio capture failed error=\(error.localizedDescription)")
            appState.errorMessage = "Microphone failed: \(error.localizedDescription)"
            resetToIdle(after: 2)
            return
        }

        usingCachedParams = true
        AppLog.info("Connecting ASR params cookieCount=\(params.cookies.count) deviceIdSet=\(!params.deviceId.isEmpty) webIdSet=\(!params.webId.isEmpty)")
        asrClient.connect(params: params)
    }

    private func stopRecording() {
        AppLog.info("Stop recording requested currentTextChars=\(appState.transcript.count)")
        setRecordingState(.stopping)
        awaitingFinalResult = true
        stopFinalizationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
                AppLog.info("Stop capture tail delay elapsed; finishing audio stream")
                self.audioCapture.stopCapture()
                self.asrClient.finishSending()
                // Spin until the recognizer finishes the tail: complete on `finish`, or when
                // results go quiet, or at the hard cap if the server never finishes.
                self.scheduleQuietCompletion()
                self.scheduleHardCompletion()
            }
        }
        stopFinalizationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stopCaptureTailDelay, execute: work)
    }

    private func scheduleQuietCompletion() {
        quietCompletionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
                AppLog.info("Final quiet timeout; completing chars=\(self.appState.transcript.count)")
                self.completeTranscription()
            }
        }
        quietCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finalQuietInterval, execute: work)
    }

    private func scheduleHardCompletion() {
        hardCompletionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
                AppLog.info("Final hard timeout; completing chars=\(self.appState.transcript.count)")
                self.completeTranscription()
            }
        }
        hardCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finalHardTimeout, execute: work)
    }

    private func cancelFinalTimers() {
        stopFinalizationWork?.cancel()
        stopFinalizationWork = nil
        quietCompletionWork?.cancel()
        quietCompletionWork = nil
        hardCompletionWork?.cancel()
        hardCompletionWork = nil
    }

    func submitRecording() {
        AppLog.info("Submit recording requested currentState=\(appState.recordingState)")
        switch appState.recordingState {
        case .starting, .recording:
            stopRecording()
        case .idle, .stopping:
            break
        }
    }

    func cancelRecording() {
        guard appState.recordingState != .idle else { return }
        AppLog.info("Cancel recording currentTextChars=\(appState.transcript.count)")
        awaitingFinalResult = false
        cancelFinalTimers()
        audioCapture.stopCapture()
        asrClient.disconnect()
        resetToIdle(after: 0)
    }

    private func completeTranscription() {
        awaitingFinalResult = false
        cancelFinalTimers()
        let text = appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.info("Complete transcription chars=\(text.count) text=\"\(Self.preview(text))\"")
        if text.isEmpty || Self.isNonInputStatusMessage(text) {
            completeWithoutRecognizedText()
        } else {
            appState.lastTranscript = text
            PasteHelper.copyAndPaste(text)
            appState.transcript = ""
            resetToIdle(after: 0)
        }
    }

    private func handleAuthFailure() {
        AppLog.error("Handling auth failure; clearing ASR params")
        ASRParamsStore.clear()
        usingCachedParams = false
        audioCapture.stopCapture()
        asrClient.disconnect()
        appState.loginStatus = .notLoggedIn
        appState.transcript = ""
        appState.errorMessage = Self.authExpiredMessage
        resetToIdle(after: 1.5)
        onAuthExpired?()
    }

    private func completeWithoutRecognizedText() {
        AppLog.info("Complete without recognized text")
        awaitingFinalResult = false
        cancelFinalTimers()
        audioCapture.stopCapture()
        asrClient.disconnect()
        appState.errorMessage = Self.noRecognizedTextMessage
        appState.transcript = ""
        setRecordingState(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.recordingState == .idle else { return }
                self.overlayPanel.hide()
                self.appState.errorMessage = nil
                self.appState.resetAudioLevels()
                self.usingCachedParams = false
                self.isHandlingConnectionError = false
            }
        }
    }

    private func resetToIdle(after delay: TimeInterval) {
        AppLog.info("Reset to idle scheduled delay=\(delay)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("Reset to idle now")
                self.awaitingFinalResult = false
                self.audioCapture.stopCapture()
                self.asrClient.disconnect()
                self.setRecordingState(.idle)
                self.overlayPanel.hide()
                self.appState.errorMessage = nil
                self.appState.transcript = ""
                self.appState.resetAudioLevels()
                self.usingCachedParams = false
                self.isHandlingConnectionError = false
            }
        }
    }

    private func setRecordingState(_ state: RecordingState) {
        AppLog.info("Recording state \(appState.recordingState) -> \(state)")
        appState.recordingState = state
        hotkeyManager.setEscapeHandlingEnabled(state != .idle)
        onStateChanged?()
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(120)).replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func isNonInputStatusMessage(_ text: String) -> Bool {
        text == noRecognizedTextMessage || text == noRecognizedSpeechMessage
    }

    /// Disconnects that typically happen when there was no real speech (e.g. the user
    /// triggered start/stop without talking) and shouldn't be shown as scary errors.
    private static func isBenignDisconnect(_ error: Error?) -> Bool {
        guard let error else { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true } // ENOTCONN
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost, NSURLErrorCancelled:
                return true
            default:
                break
            }
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected")
    }
}
