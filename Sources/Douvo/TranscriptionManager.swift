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

    private var usingCachedParams = false
    private var awaitingFinalResult = false
    private var isHandlingConnectionError = false
    private var isCompletingTranscription = false

    private var quietCompletionWork: DispatchWorkItem?
    private var hardCompletionWork: DispatchWorkItem?
    private var completionTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?
    private var transcriptionSession: TranscriptionSession?
    private var activeSessionID: UUID?
    private var transcriptionTrace: TranscriptionTrace?
    private var asrResultCount = 0
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
        AppLog.info("Transcription hotkey handler installing")
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            guard let self else {
                AppLog.error("Hotkey event dropped: TranscriptionManager released event=\(event)")
                return
            }
            AppLog.info("Hotkey event callback invoked event=\(event) isMainThread=\(Thread.isMainThread)")
            if Thread.isMainThread {
                self.handleHotkeyEvent(event)
            } else {
                DispatchQueue.main.async { [self] in
                    self.handleHotkeyEvent(event)
                }
            }
        }
        AppLog.info("Transcription hotkey handler installed")

        appState.onCancelTapped = { [weak self] in
            self?.cancelRecording()
        }

        appState.onSubmitTapped = { [weak self] in
            self?.submitRecording()
        }

        hotkeyManager.start()
    }

    private func handleSessionEvent(
        _ event: TranscriptionSessionEvent,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else {
            AppLog.info("Dropped stale transcription session event event=\(event)")
            return
        }

        switch event {
        case .audioStarted:
            handleAudioStarted()
        case .audioLevel(let level):
            appState.pushAudioLevel(level)
        case .asrOpened:
            handleASROpen()
        case .asrResult(let text):
            handleASRResult(text)
        case .asrFinished:
            handleASRFinish()
        case .asrError(let error):
            handleASRError(error)
        case .asrAuthError:
            handleASRAuthError()
        }
    }

    private func handleHotkeyEvent(_ event: HotkeyManager.HotkeyEvent) {
        AppLog.info("Hotkey event received event=\(event)")
        switch event {
        case .toggleRecording:
            toggleRecording()
        case .holdRecordingStarted:
            startRecordingFromHold()
        case .holdRecordingEnded:
            stopRecordingFromHold()
        case .cancel:
            cancelRecording()
        }
    }

    private func handleASROpen() {
        guard appState.recordingState == .starting || appState.recordingState == .recording else { return }
        transcriptionTrace?.finishSpan("asr.connect", metadata: ["result": "opened"])
        transcriptionTrace?.event("asr.opened")
        if appState.recordingState == .starting {
            AppLog.info("ASR open; recording state -> recording")
            setRecordingState(.recording)
        } else {
            AppLog.info("ASR open; recording state already recording")
        }
    }

    private func handleAudioStarted() {
        guard appState.recordingState == .starting else { return }
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "started"])
        AppLog.info("Audio capture started")
        AppLog.info("Audio capture ready; recording state -> recording")
        setRecordingState(.recording)
    }

    private func handleASRResult(_ text: String) {
        asrResultCount += 1
        transcriptionTrace?.set("asr_result_count", asrResultCount)
        transcriptionTrace?.set("last_asr_result_chars", text.count)
        if asrResultCount == 1 {
            transcriptionTrace?.event("asr.first_result", metadata: ["chars": String(text.count)])
        }
        if asrResultCount == 1 || asrResultCount % 25 == 0 || awaitingFinalResult {
            AppLog.info("ASR result count=\(asrResultCount) chars=\(text.count) text=\"\(Self.preview(text))\"")
        }
        if Self.isNonInputStatusMessage(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if awaitingFinalResult || appState.recordingState == .stopping {
                completeWithoutRecognizedText()
            } else {
                appState.errorMessage = Self.noRecognizedTextMessage
                appState.transcript = ""
            }
            return
        }
        appState.transcript = text
        if appState.recordingState == .starting {
            setRecordingState(.recording)
        }
        // While finishing, keep waiting for the recognizer to catch up on the
        // tail of the audio. Each new result means it is still producing output,
        // so push the quiet-completion deadline out instead of submitting early.
        if awaitingFinalResult {
            scheduleQuietCompletion()
        }
    }

    private func handleASRFinish() {
        transcriptionTrace?.event("asr.finish_event")
        AppLog.info("ASR finish event received")
        if appState.recordingState == .stopping || appState.recordingState == .recording {
            transcriptionTrace?.finishSpan("asr.final_wait", metadata: ["completion_trigger": "finish_event"])
            completeTranscription(trigger: "asr_finish_event")
        }
    }

    private func handleASRError(_ error: TranscriptionSessionError?) {
        guard appState.recordingState != .idle, !isHandlingConnectionError else { return }
        isHandlingConnectionError = true
        transcriptionTrace?.event("asr.connection_error", metadata: [
            "state": String(describing: appState.recordingState),
            "has_error": String(error != nil)
        ])
        AppLog.error("ASR connection error state=\(appState.recordingState) error=\(error?.localizedDescription ?? "unknown")")
        awaitingFinalResult = false
        cancelFinalTimers()
        cancelActiveSession()

        let recognized = appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recognized.isEmpty {
            // We already have text; keep it rather than surfacing a raw socket error.
            completeTranscription(trigger: "connection_error_with_text")
        } else if Self.isBenignDisconnect(error) {
            completeWithoutRecognizedText()
        } else {
            appState.errorMessage = "网络连接中断，请重试"
            finishCurrentTrace(outcome: "failed", metadata: [
                "reason": "asr_connection_error",
                "error": error?.localizedDescription ?? "unknown"
            ])
            resetToIdle(after: 1.8)
        }
    }

    private func handleASRAuthError() {
        AppLog.error("ASR auth error")
        handleAuthFailure()
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
        if transcriptionTrace != nil {
            finishCurrentTrace(outcome: "superseded", metadata: ["reason": "new_recording_started"])
        }
        transcriptionTrace = TranscriptionTrace()
        transcriptionTrace?.event("recording.start_requested", metadata: [
            "login_status": String(describing: appState.loginStatus)
        ])
        transcriptionTrace?.startSpan("recording.user_audio")
        asrResultCount = 0
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
            finishCurrentTrace(outcome: "blocked", metadata: ["reason": "not_logged_in"])
            resetToIdle(after: 1.5)
            return
        }

        transcriptionTrace?.startSpan("asr.load_params")
        guard let params = ASRParamsStore.load() else {
            transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "missing"])
            AppLog.error("Start blocked: ASR params missing")
            appState.errorMessage = "登录参数缺失，请重新登录"
            appState.loginStatus = .notLoggedIn
            webViewManager.showLoginWindow()
            finishCurrentTrace(outcome: "blocked", metadata: ["reason": "asr_params_missing"])
            resetToIdle(after: 1.5)
            return
        }
        transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "loaded"])

        transcriptionTrace?.startSpan("audio.start_capture")
        usingCachedParams = true
        AppLog.info("Connecting ASR params cookieCount=\(params.cookies.count) deviceIdSet=\(!params.deviceId.isEmpty) webIdSet=\(!params.webId.isEmpty)")
        transcriptionTrace?.startSpan("asr.connect")
        transcriptionTrace?.event("asr.connect_requested", metadata: [
            "cookie_count": String(params.cookies.count),
            "has_device_id": String(!params.deviceId.isEmpty),
            "has_web_id": String(!params.webId.isEmpty)
        ])

        let sessionID = UUID()
        let session = TranscriptionSession { [weak self] event in
            self?.handleSessionEvent(event, sessionID: sessionID)
        }
        activeSessionID = sessionID
        transcriptionSession = session
        sessionStartTask?.cancel()
        sessionStartTask = Task { [weak self, session] in
            do {
                try await session.start(params: params)
            } catch {
                await MainActor.run {
                    self?.handleAudioStartFailure(error, sessionID: sessionID)
                }
            }
        }
    }

    private func stopRecording() {
        AppLog.info("Stop recording requested currentTextChars=\(appState.transcript.count)")
        transcriptionTrace?.event("recording.stop_requested", metadata: ["current_text_chars": String(appState.transcript.count)])
        transcriptionTrace?.finishSpan("recording.user_audio", metadata: ["current_text_chars": String(appState.transcript.count)])
        setRecordingState(.stopping)
        awaitingFinalResult = true
        AppLog.info("Stop capture now; finishing audio stream")
        transcriptionTrace?.event("asr.finish_requested")
        let session = transcriptionSession
        Task { await session?.stop() }
        transcriptionTrace?.startSpan("asr.final_wait")
        // Complete on server finish, or after quiet/hard timeout if the server keeps sending empty results.
        scheduleQuietCompletion()
        scheduleHardCompletion()
    }

    private func scheduleQuietCompletion() {
        quietCompletionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
            AppLog.info("Final quiet timeout; completing chars=\(self.appState.transcript.count)")
            self.transcriptionTrace?.finishSpan("asr.final_wait", metadata: ["completion_trigger": "quiet_timeout"])
            self.completeTranscription(trigger: "quiet_timeout")
        }
        quietCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finalQuietInterval, execute: work)
    }

    private func scheduleHardCompletion() {
        hardCompletionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
            AppLog.info("Final hard timeout; completing chars=\(self.appState.transcript.count)")
            self.transcriptionTrace?.finishSpan("asr.final_wait", metadata: ["completion_trigger": "hard_timeout"])
            self.completeTranscription(trigger: "hard_timeout")
        }
        hardCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finalHardTimeout, execute: work)
    }

    private func cancelFinalTimers() {
        quietCompletionWork?.cancel()
        quietCompletionWork = nil
        hardCompletionWork?.cancel()
        hardCompletionWork = nil
    }

    func submitRecording() {
        AppLog.info("Submit recording requested currentState=\(appState.recordingState)")
        transcriptionTrace?.event("recording.submit_requested", metadata: [
            "state": String(describing: appState.recordingState)
        ])
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
        transcriptionTrace?.event("recording.cancel_requested", metadata: ["current_text_chars": String(appState.transcript.count)])
        awaitingFinalResult = false
        isCompletingTranscription = false
        completionTask?.cancel()
        completionTask = nil
        cancelFinalTimers()
        cancelActiveSession()
        finishCurrentTrace(outcome: "cancelled", metadata: ["current_text_chars": String(appState.transcript.count)])
        resetToIdle(after: 0)
    }

    private func completeTranscription(trigger: String) {
        guard !isCompletingTranscription else { return }
        awaitingFinalResult = false
        cancelFinalTimers()
        let text = appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionTrace?.event("transcription.complete_requested", metadata: [
            "trigger": trigger,
            "raw_chars": String(text.count)
        ])
        transcriptionTrace?.set("raw_chars", text.count)
        transcriptionTrace?.set("completion_trigger", trigger)
        AppLog.info("Complete transcription chars=\(text.count) text=\"\(Self.preview(text))\"")
        if text.isEmpty || Self.isNonInputStatusMessage(text) {
            completeWithoutRecognizedText()
        } else {
            isCompletingTranscription = true
            completionTask?.cancel()
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let finalText: String
                do {
                    let result = try await CorrectionPostProcessor.shared.correctedTextWithTrace(
                        for: text,
                        requiresEnabled: true
                    )
                    self.transcriptionTrace?.addTimings(result.timings)
                    for (key, value) in result.metadata {
                        self.transcriptionTrace?.set("correction.\(key)", value)
                    }
                    finalText = result.text
                } catch {
                    self.transcriptionTrace?.event("correction.failed", metadata: ["error": error.localizedDescription])
                    AppLog.error("Local LLM postprocess failed; using raw text error=\(error.localizedDescription)")
                    finalText = text
                }

                guard !Task.isCancelled, self.isCompletingTranscription else { return }
                self.finishTranscription(with: finalText)
            }
        }
    }

    private func finishTranscription(with text: String) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.info("Finish transcription chars=\(finalText.count) text=\"\(Self.preview(finalText))\"")
        isCompletingTranscription = false
        completionTask = nil
        appState.lastTranscript = finalText
        transcriptionTrace?.startSpan("paste.enqueue")
        PasteHelper.copyAndPaste(finalText)
        transcriptionTrace?.finishSpan("paste.enqueue", metadata: ["final_chars": String(finalText.count)])
        finishCurrentTrace(outcome: "completed", metadata: ["final_chars": String(finalText.count)])
        appState.transcript = ""
        resetToIdle(after: 0)
    }

    private func handleAuthFailure() {
        AppLog.error("Handling auth failure; clearing ASR params")
        transcriptionTrace?.event("asr.auth_failure")
        ASRParamsStore.clear()
        usingCachedParams = false
        cancelActiveSession()
        appState.loginStatus = .notLoggedIn
        appState.transcript = ""
        appState.errorMessage = Self.authExpiredMessage
        finishCurrentTrace(outcome: "failed", metadata: ["reason": "auth_expired"])
        resetToIdle(after: 1.5)
        onAuthExpired?()
    }

    private func completeWithoutRecognizedText() {
        AppLog.info("Complete without recognized text")
        awaitingFinalResult = false
        isCompletingTranscription = false
        completionTask?.cancel()
        completionTask = nil
        cancelFinalTimers()
        cancelActiveSession()
        appState.errorMessage = Self.noRecognizedTextMessage
        appState.transcript = ""
        finishCurrentTrace(outcome: "no_text", metadata: ["reason": "no_recognized_text"])
        setRecordingState(.idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.appState.recordingState == .idle else { return }
            self.overlayPanel.hide()
            self.appState.errorMessage = nil
            self.appState.resetAudioLevels()
            self.usingCachedParams = false
            self.isHandlingConnectionError = false
            self.isCompletingTranscription = false
        }
    }

    private func resetToIdle(after delay: TimeInterval) {
        AppLog.info("Reset to idle scheduled delay=\(delay)")
        guard delay > 0 else {
            resetToIdleNow()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.resetToIdleNow()
        }
    }

    private func resetToIdleNow() {
        AppLog.info("Reset to idle now")
        awaitingFinalResult = false
        cancelActiveSession()
        setRecordingState(.idle)
        overlayPanel.hide()
        appState.errorMessage = nil
        appState.transcript = ""
        appState.resetAudioLevels()
        usingCachedParams = false
        isHandlingConnectionError = false
        isCompletingTranscription = false
    }

    private func setRecordingState(_ state: RecordingState) {
        AppLog.info("Recording state \(appState.recordingState) -> \(state)")
        appState.recordingState = state
        hotkeyManager.setEscapeHandlingEnabled(state != .idle)
        onStateChanged?()
    }

    private func finishCurrentTrace(
        outcome: String,
        metadata: [String: String] = [:]
    ) {
        transcriptionTrace?.finish(outcome: outcome, metadata: metadata)
        transcriptionTrace = nil
    }

    private func handleAudioStartFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "failed"])
        AppLog.error("Audio capture failed error=\(error.localizedDescription)")
        appState.errorMessage = "Microphone failed: \(error.localizedDescription)"
        finishCurrentTrace(outcome: "failed", metadata: [
            "reason": "audio_capture_failed",
            "error": error.localizedDescription
        ])
        resetToIdle(after: 2)
    }

    private func cancelActiveSession() {
        sessionStartTask?.cancel()
        sessionStartTask = nil
        let session = transcriptionSession
        transcriptionSession = nil
        activeSessionID = nil
        Task { await session?.cancel() }
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(120)).replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func isNonInputStatusMessage(_ text: String) -> Bool {
        text == noRecognizedTextMessage || text == noRecognizedSpeechMessage
    }

    /// Disconnects that typically happen when there was no real speech (e.g. the user
    /// triggered start/stop without talking) and shouldn't be shown as scary errors.
    private static func isBenignDisconnect(_ error: TranscriptionSessionError?) -> Bool {
        guard let error else { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == 57 { return true } // ENOTCONN
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNetworkConnectionLost, NSURLErrorCancelled:
                return true
            default:
                break
            }
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("socket is not connected")
    }
}
