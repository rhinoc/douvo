import Foundation

@MainActor
final class TranscriptionManager {
    private static var noRecognizedTextMessage: String {
        L10n.text(en: "No text recognized", zh: "没有识别到文字")
    }

    private static var noRecognizedSpeechMessage: String {
        L10n.text(en: "No speech recognized", zh: "没有识别到语音")
    }

    private static var authExpiredMessage: String {
        L10n.text(en: "Login expired. Please log in again.", zh: "登录已过期，请重新登录")
    }

    private static var selectionTooLongMessage: String {
        L10n.text(en: "Select 500 chars or fewer.", zh: "选中文本不超过 500 字。")
    }

    private static var focusTextInputMessage: String {
        L10n.text(en: "Focus a text field first.", zh: "请先聚焦在输入框中")
    }

    private static var accessibilityPermissionMessage: String {
        L10n.text(en: "Accessibility permission is required.", zh: "需要授予辅助功能权限")
    }

    private static var recordingStartTimeoutMessage: String {
        L10n.text(en: "Recording did not start. Please try again.", zh: "录音没有启动，请重试")
    }

    private static var focusTextInputCopiedMessage: String {
        L10n.text(en: "No text field found. Copied to clipboard.", zh: "未找到输入框，已复制到剪贴板")
    }

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
    private var startTimeoutWork: DispatchWorkItem?
    private var completionTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?
    private var transcriptionSession: TranscriptionSession?
    private var activeSessionID: UUID?
    private var transcriptionTrace: TranscriptionTrace?
    private var asrResultCount = 0
    private var asrResultSummaryLogged = false
    private var asrResultProgressSamples: [String] = []
    private var maxASRResultCharsByProvider: [String: Int] = [:]
    private var latestProviderTranscripts: [String: String] = [:]
    private var activeASRProviders = Set<String>()
    private var openedASRProviders = Set<String>()
    private var audioReady = false
    private var finishedASRProviders = Set<String>()
    private var selectionEditTarget: String?
    private var translationSessionActive = false
    private var holdRecordingStartedAt: TimeInterval?
    private static let maxASRResultSummarySamples = 12
    private let minimumHoldRecordingDuration: TimeInterval = 0.45
    // After the user stops, wait this long with no new results before submitting.
    private let finalQuietInterval: TimeInterval = 1.5
    // Absolute cap on how long we keep spinning after stop, in case finish never arrives.
    private let finalHardTimeout: TimeInterval = 12
    // Avoid leaving the overlay in the loading state if audio/ASR startup hangs.
    private let startTimeout: TimeInterval = 8

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
        case .recordingSaved(let path):
            transcriptionTrace?.set("recording_path", path)
            transcriptionTrace?.event("recording.saved", metadata: ["path": path])
        case .asrOpened(let provider):
            handleASROpen(provider: provider)
        case .asrResult(let result):
            handleASRResult(result)
        case .asrFinished(let provider):
            handleASRFinish(provider: provider)
        case .asrError(let provider, let error):
            handleASRError(error, provider: provider)
        case .asrAuthError(let provider):
            handleASRAuthError(provider: provider)
        case .audioStartFailed(let error):
            handleAudioStartFailure(error, sessionID: sessionID)
        }
    }

    private func handleHotkeyEvent(_ event: HotkeyManager.HotkeyEvent) {
        switch event {
        case .toggleRecording:
            toggleRecording()
        case .holdRecordingStarted:
            startRecordingFromHold()
        case .holdRecordingEnded:
            stopRecordingFromHold()
        case .translationRequested:
            markTranslationRequested()
        case .cancel:
            cancelRecording()
        }
    }

    private func handleASROpen(provider: String) {
        guard appState.recordingState == .starting || appState.recordingState == .recording else { return }
        openedASRProviders.insert(provider)
        transcriptionTrace?.event("asr.opened", metadata: ["asr_provider": provider])
        if activeASRProviders.isSubset(of: openedASRProviders) {
            transcriptionTrace?.finishSpan("asr.connect", metadata: [
                "result": "opened",
                "opened_providers": openedASRProviders.sorted().joined(separator: ",")
            ])
        }
        if appState.recordingState == .starting {
            tryTransitionToRecording(trigger: "asr_open")
        } else {
            AppLog.info("ASR open provider=\(provider); recording state already recording")
        }
    }

    private func handleAudioStarted() {
        audioReady = true
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "started"])
        AppLog.info("Audio capture started")
        if appState.recordingState == .starting {
            tryTransitionToRecording(trigger: "audio_started")
        }
    }

    /// Transition from `.starting` to `.recording` only when both ASR and audio are ready.
    private func tryTransitionToRecording(trigger: String) {
        let asrReady = activeASRProviders.isSubset(of: openedASRProviders)
        guard asrReady, audioReady else {
            AppLog.info("Waiting for readiness before recording: asrReady=\(asrReady) audioReady=\(audioReady) trigger=\(trigger)")
            return
        }
        AppLog.info("Both ASR and audio ready; recording state -> recording (trigger=\(trigger))")
        setRecordingState(.recording)
    }

    private func handleASRResult(_ result: ASRRecognitionResult) {
        let text = result.text
        asrResultCount += 1
        transcriptionTrace?.set("asr_result_count", asrResultCount)
        transcriptionTrace?.set("last_asr_result_chars", text.count)
        transcriptionTrace?.set("last_asr_result_provider", result.provider)
        transcriptionTrace?.set("last_asr_result_kind", result.kind)
        transcriptionTrace?.set("last_asr_result_segments", result.segmentCount)
        transcriptionTrace?.set("last_asr_result_final", result.isFinal)
        for (key, value) in result.metadata {
            transcriptionTrace?.set(key, value)
        }
        if asrResultCount == 1 {
            transcriptionTrace?.event("asr.first_result", metadata: [
                "chars": String(text.count),
                "provider": result.provider,
                "kind": result.kind,
                "segments": String(result.segmentCount)
            ])
        }
        let acceptedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !acceptedText.isEmpty else {
            transcriptionTrace?.event("asr.empty_result_ignored", metadata: [
                "asr_provider": result.provider,
                "kind": result.kind
            ])
            return
        }
        if Self.isNonInputStatusMessage(acceptedText) {
            if awaitingFinalResult || appState.recordingState == .stopping {
                completeWithoutRecognizedText()
            } else {
                appState.errorMessage = Self.noRecognizedTextMessage
                appState.transcript = ""
            }
            return
        }
        latestProviderTranscripts[result.provider] = acceptedText
        let providerMaxChars = max(maxASRResultCharsByProvider[result.provider] ?? 0, acceptedText.count)
        maxASRResultCharsByProvider[result.provider] = providerMaxChars
        let selectedText = displayTranscript()
        transcriptionTrace?.set("max_asr_result_chars", maxASRResultCharsByProvider.values.max() ?? text.count)
        transcriptionTrace?.set("selected_transcript_chars", selectedText.count)
        transcriptionTrace?.set("asr.\(result.provider).max_result_chars", providerMaxChars)
        transcriptionTrace?.set("asr.\(result.provider).selected_transcript_chars", acceptedText.count)
        recordASRResultProgress(
            result: result,
            rawChars: text.count,
            selectedChars: selectedText.count
        )
        appState.transcript = selectedText
        if appState.recordingState == .starting {
            tryTransitionToRecording(trigger: "asr_result")
        }
        // While finishing, keep waiting for the recognizer to catch up on the
        // tail of the audio. Each new result means it is still producing output,
        // so push the quiet-completion deadline out instead of submitting early.
        if awaitingFinalResult {
            scheduleQuietCompletion()
        }
    }

    private func handleASRFinish(provider: String) {
        finishedASRProviders.insert(provider)
        transcriptionTrace?.event("asr.finish_event", metadata: [
            "asr_provider": provider,
            "finished_providers": finishedASRProviders.sorted().joined(separator: ",")
        ])
        AppLog.info("ASR finish event received provider=\(provider)")
        if appState.recordingState == .stopping || appState.recordingState == .recording {
            if activeASRProviders.isSubset(of: finishedASRProviders) {
                transcriptionTrace?.finishSpan("asr.final_wait", metadata: [
                    "completion_trigger": "finish_event",
                    "finished_providers": finishedASRProviders.sorted().joined(separator: ",")
                ])
                completeTranscription(trigger: "asr_finish_event")
            } else if awaitingFinalResult {
                scheduleQuietCompletion()
            }
        }
    }

    private func handleASRError(_ error: TranscriptionSessionError?, provider: String) {
        guard appState.recordingState != .idle, !isHandlingConnectionError else { return }
        isHandlingConnectionError = true
        transcriptionTrace?.event("asr.connection_error", metadata: [
            "asr_provider": provider,
            "state": String(describing: appState.recordingState),
            "has_error": String(error != nil)
        ])
        AppLog.error("ASR connection error provider=\(provider) state=\(appState.recordingState) error=\(error?.localizedDescription ?? "unknown")")
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
            appState.errorMessage = L10n.text(en: "Network connection interrupted. Please try again.", zh: "网络连接中断，请重试")
            logASRResultSummary(reason: "connection_error")
            finishCurrentTrace(outcome: "failed", metadata: [
                "reason": "asr_connection_error",
                "error": error?.localizedDescription ?? "unknown"
            ])
            resetToIdle(after: 1.8)
        }
    }

    private func handleASRAuthError(provider: String) {
        AppLog.error("ASR auth error provider=\(provider)")
        handleAuthFailure(provider: provider)
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

    private func markTranslationRequested() {
        AppLog.info("Translation requested currentState=\(appState.recordingState)")
        switch appState.recordingState {
        case .starting, .recording:
            if translationSessionActive {
                AppLog.info("Translation request toggled off")
                translationSessionActive = false
                appState.overlayMode = .dictation
                appState.errorMessage = nil
                transcriptionTrace?.event("translation.toggled_off")
                transcriptionTrace?.set("translation.enabled", false)
                return
            }
            guard LocalLLMPostProcessor.isCorrectionEnabled else {
                AppLog.info("Translation request ignored: AI Correction disabled")
                appState.errorMessage = L10n.text(en: "Translation requires AI Correction.", zh: "翻译需要先开启 AI Correction")
                transcriptionTrace?.event("translation.request_ignored", metadata: ["reason": "ai_correction_disabled"])
                return
            }
            translationSessionActive = true
            selectionEditTarget = nil
            appState.overlayMode = .translation
            appState.errorMessage = nil
            transcriptionTrace?.event("translation.requested", metadata: [
                "target_language": LocalLLMSettingsStore.translationTargetLanguage.promptName
            ])
            transcriptionTrace?.set("translation.enabled", true)
            transcriptionTrace?.set("translation.target_language", LocalLLMSettingsStore.translationTargetLanguage.promptName)
        case .idle, .stopping:
            break
        }
    }

    private func startRecordingFromHold() {
        AppLog.info("Hold recording start currentState=\(appState.recordingState)")
        guard appState.recordingState == .idle else { return }
        holdRecordingStartedAt = ProcessInfo.processInfo.systemUptime
        startRecording()
    }

    private func stopRecordingFromHold() {
        AppLog.info("Hold recording stop currentState=\(appState.recordingState)")
        switch appState.recordingState {
        case .starting, .recording:
            let heldDuration = holdRecordingStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            guard heldDuration >= minimumHoldRecordingDuration else {
                AppLog.info("Hold recording cancelled: too short durationMs=\(Int((heldDuration * 1000).rounded())) minimumMs=\(Int(minimumHoldRecordingDuration * 1000))")
                transcriptionTrace?.event("hold.cancelled_short_press", metadata: [
                    "duration_ms": String(Int((heldDuration * 1000).rounded())),
                    "minimum_ms": String(Int(minimumHoldRecordingDuration * 1000))
                ])
                holdRecordingStartedAt = nil
                cancelRecording(traceOutcome: "cancelled_short_hold")
                return
            }
            holdRecordingStartedAt = nil
            stopRecording()
        case .idle, .stopping:
            holdRecordingStartedAt = nil
            break
        }
    }

    private func startRecording() {
        let provider = ASRProviderStore.selected
        AppLog.info("Start recording requested provider=\(provider.rawValue) loginStatus=\(appState.loginStatus)")
        if transcriptionTrace != nil {
            finishCurrentTrace(outcome: "superseded", metadata: ["reason": "new_recording_started"])
        }
        transcriptionTrace = TranscriptionTrace()
        transcriptionTrace?.event("recording.start_requested", metadata: [
            "asr_provider": provider.rawValue,
            "login_status": String(describing: appState.loginStatus)
        ])
        transcriptionTrace?.startSpan("recording.user_audio")
        asrResultCount = 0
        asrResultSummaryLogged = false
        asrResultProgressSamples.removeAll(keepingCapacity: true)
        maxASRResultCharsByProvider.removeAll()
        latestProviderTranscripts.removeAll()
        activeASRProviders = provider.activeProviderKeys
        openedASRProviders.removeAll()
        audioReady = false
        finishedASRProviders.removeAll()
        isHandlingConnectionError = false
        selectionEditTarget = nil
        translationSessionActive = false
        appState.overlayMode = .dictation

        let inputFocus = TextInputFocusCheck.capture()
        transcriptionTrace?.event("input_focus.checked", metadata: inputFocus.traceMetadata)
        guard inputFocus.isTextInput else {
            blockStartForMissingTextInput(inputFocus)
            return
        }

        if LocalLLMSettingsStore.selectionEditingEnabled {
            let selectionPreparation = prepareSelectionEditingTarget()
            if selectionPreparation == .tooLong {
                AppLog.info("Start blocked: selected text too long")
                appState.errorMessage = Self.selectionTooLongMessage
                transcriptionTrace?.event("selection_edit.blocked", metadata: [
                    "reason": "selection_too_long",
                    "max_chars": String(SelectedTextReader.maxSelectionCharacters)
                ])
                setRecordingState(.starting)
                overlayPanel.show()
                finishCurrentTrace(outcome: "blocked", metadata: ["reason": "selection_too_long"])
                resetToIdle(after: 1.5)
                return
            }
            if case .text(let selectedText) = selectionPreparation {
                selectionEditTarget = selectedText
                appState.overlayMode = .selectionEditing
                transcriptionTrace?.set("selection_edit.enabled", true)
                transcriptionTrace?.set("selection_edit.selected_chars", selectedText.count)
            }
        }

        setRecordingState(.starting)
        appState.transcript = ""
        appState.errorMessage = nil
        appState.resetAudioLevels()
        overlayPanel.show()

        var webParams: DoubaoASRParams?
        if provider == .mix, !LocalLLMPostProcessor.isCorrectionEnabled {
            AppLog.error("Start blocked: Mix ASR requires AI Correction")
            appState.errorMessage = L10n.text(en: "Mix ASR requires AI Correction.", zh: "Mix ASR 需要先开启 AI Correction")
            finishCurrentTrace(outcome: "blocked", metadata: ["reason": "mix_requires_ai_correction"])
            resetToIdle(after: 1.8)
            return
        }

        if provider.usesWebASR {
            guard appState.loginStatus == .loggedIn else {
                AppLog.error("Start blocked: not logged in")
                appState.errorMessage = L10n.text(en: "Please log in to Doubao first.", zh: "请先登录豆包")
                webViewManager.showLoginWindow()
                finishCurrentTrace(outcome: "blocked", metadata: ["reason": "not_logged_in"])
                resetToIdle(after: 1.5)
                return
            }

            transcriptionTrace?.startSpan("asr.load_params")
            guard let params = ASRParamsStore.load() else {
                transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "missing"])
                AppLog.error("Start blocked: ASR params missing")
                appState.errorMessage = L10n.text(en: "Login parameters are missing. Please log in again.", zh: "登录参数缺失，请重新登录")
                appState.loginStatus = .notLoggedIn
                webViewManager.showLoginWindow()
                finishCurrentTrace(outcome: "blocked", metadata: ["reason": "asr_params_missing"])
                resetToIdle(after: 1.5)
                return
            }
            webParams = params
            transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "loaded"])
            AppLog.info("Connecting Web ASR params cookieCount=\(params.cookies.count) deviceIdSet=\(!params.deviceId.isEmpty) webIdSet=\(!params.webId.isEmpty)")
            transcriptionTrace?.event("asr.connect_requested", metadata: [
                "asr_provider": provider.rawValue,
                "active_providers": activeASRProviders.sorted().joined(separator: ","),
                "cookie_count": String(params.cookies.count),
                "has_device_id": String(!params.deviceId.isEmpty),
                "has_web_id": String(!params.webId.isEmpty)
            ])
        } else {
            transcriptionTrace?.event("asr.connect_requested", metadata: [
                "asr_provider": provider.rawValue,
                "active_providers": activeASRProviders.sorted().joined(separator: ",")
            ])
        }

        transcriptionTrace?.startSpan("audio.start_capture")
        usingCachedParams = true
        transcriptionTrace?.startSpan("asr.connect")

        let sessionID = UUID()
        let session = TranscriptionSession(provider: provider) { [weak self] event in
            self?.handleSessionEvent(event, sessionID: sessionID)
        }
        activeSessionID = sessionID
        transcriptionSession = session
        scheduleStartTimeout(sessionID: sessionID)
        sessionStartTask?.cancel()
        sessionStartTask = Task { [weak self, session] in
            do {
                try await session.start(webParams: webParams)
            } catch {
                AppLog.error("Session start failed: \(error)")
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
        Task { _ = await session?.stop() }
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

    private func scheduleStartTimeout(sessionID: UUID) {
        startTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeSessionID == sessionID,
                  self.appState.recordingState == .starting else {
                return
            }
            self.handleRecordingStartTimeout(sessionID: sessionID)
        }
        startTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout, execute: work)
    }

    private func cancelStartTimeout() {
        startTimeoutWork?.cancel()
        startTimeoutWork = nil
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

    func cancelRecording(traceOutcome: String = "cancelled") {
        guard appState.recordingState != .idle else { return }
        AppLog.info("Cancel recording currentTextChars=\(appState.transcript.count)")
        transcriptionTrace?.event("recording.cancel_requested", metadata: ["current_text_chars": String(appState.transcript.count)])
        awaitingFinalResult = false
        isCompletingTranscription = false
        selectionEditTarget = nil
        translationSessionActive = false
        appState.overlayMode = .dictation
        completionTask?.cancel()
        completionTask = nil
        cancelFinalTimers()
        cancelActiveSession()
        logASRResultSummary(reason: "cancelled")
        finishCurrentTrace(outcome: traceOutcome, metadata: ["current_text_chars": String(appState.transcript.count)])
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
        transcriptionTrace?.set("raw_text", text)
        transcriptionTrace?.set("completion_trigger", trigger)
        logASRResultSummary(reason: "complete_\(trigger)")
        AppLog.info("Complete transcription trigger=\(trigger) chars=\(text.count)")
        if text.isEmpty || Self.isNonInputStatusMessage(text) {
            completeWithoutRecognizedText()
        } else {
            let correctionRequest = correctionRequest(for: text)
            transcriptionTrace?.set("correction.input_mode", correctionRequest.inputMode)
            transcriptionTrace?.set("correction.prompt_chars", correctionRequest.promptText.count)
            transcriptionTrace?.set("correction.fallback_chars", correctionRequest.fallbackText.count)
            if let webText = correctionRequest.webText {
                transcriptionTrace?.set("asr.web.final_text", webText)
                transcriptionTrace?.set("asr.web.final_chars", webText.count)
            }
            if let androidText = correctionRequest.androidText {
                transcriptionTrace?.set("asr.android.final_text", androidText)
                transcriptionTrace?.set("asr.android.final_chars", androidText.count)
            }
            isCompletingTranscription = true
            completionTask?.cancel()
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let finalText: String
                do {
                    let result = try await CorrectionPostProcessor.shared.correctedTextWithTrace(
                        for: correctionRequest.promptText,
                        requiresEnabled: true,
                        promptConfiguration: correctionRequest.promptConfiguration,
                        generationProfile: correctionRequest.generationProfile,
                        fallbackText: correctionRequest.fallbackText
                    )
                    self.transcriptionTrace?.addTimings(result.timings)
                    for (key, value) in result.metadata {
                        self.transcriptionTrace?.set("correction.\(key)", value)
                    }
                    finalText = result.text
                } catch {
                    self.transcriptionTrace?.event("correction.failed", metadata: ["error": error.localizedDescription])
                    AppLog.error("Local LLM postprocess failed; using raw text error=\(error.localizedDescription)")
                    finalText = correctionRequest.fallbackText
                }

                guard !Task.isCancelled, self.isCompletingTranscription else { return }
                self.finishTranscription(with: finalText)
            }
        }
    }

    private struct CorrectionRequest {
        let promptText: String
        let fallbackText: String
        let inputMode: String
        let webText: String?
        let androidText: String?
        let promptConfiguration: LocalLLMPromptConfiguration?
        let generationProfile: LocalLLMGenerationProfile?

        init(
            promptText: String,
            fallbackText: String,
            inputMode: String,
            webText: String?,
            androidText: String?,
            promptConfiguration: LocalLLMPromptConfiguration?,
            generationProfile: LocalLLMGenerationProfile? = nil
        ) {
            self.promptText = promptText
            self.fallbackText = fallbackText
            self.inputMode = inputMode
            self.webText = webText
            self.androidText = androidText
            self.promptConfiguration = promptConfiguration
            self.generationProfile = generationProfile
        }
    }

    private func prepareSelectionEditingTarget() -> SelectedTextReadResult {
        guard LocalLLMPostProcessor.isCorrectionEnabled,
              LocalLLMSettingsStore.selectionEditingEnabled else {
            return .none
        }
        return SelectedTextReader.currentSelection()
    }

    private func correctionRequest(for recognizedText: String) -> CorrectionRequest {
        if translationSessionActive {
            return translationCorrectionRequest(recognizedText: recognizedText)
        }

        if let selectionEditTarget {
            return selectionEditCorrectionRequest(
                spokenCommand: recognizedText,
                selectedText: selectionEditTarget
            )
        }

        guard ASRProviderStore.selected == .mix else {
            return CorrectionRequest(
                promptText: recognizedText,
                fallbackText: recognizedText,
                inputMode: "single",
                webText: nil,
                androidText: nil,
                promptConfiguration: nil
            )
        }

        let webText = providerTranscript("web")
        let androidText = providerTranscript("android")
        guard !webText.isEmpty, !androidText.isEmpty else {
            let fallback = [webText, androidText, recognizedText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? recognizedText
            return CorrectionRequest(
                promptText: fallback,
                fallbackText: fallback,
                inputMode: "mix_single_available",
                webText: webText.isEmpty ? nil : webText,
                androidText: androidText.isEmpty ? nil : androidText,
                promptConfiguration: nil
            )
        }

        if Self.areEquivalentMixTranscripts(webText, androidText) {
            return CorrectionRequest(
                promptText: webText,
                fallbackText: webText,
                inputMode: "mix_equivalent",
                webText: webText,
                androidText: androidText,
                promptConfiguration: nil
            )
        }

        let fallback = preferredMixFallback(webText: webText, androidText: androidText)
        return CorrectionRequest(
            promptText: Self.mixCorrectionPromptText(webText: webText, androidText: androidText),
            fallbackText: fallback,
            inputMode: "mix_dual",
            webText: webText,
            androidText: androidText,
            promptConfiguration: Self.mixPromptConfiguration()
        )
    }

    private func selectionEditCorrectionRequest(
        spokenCommand: String,
        selectedText: String
    ) -> CorrectionRequest {
        let promptConfiguration = Self.selectionEditPromptConfiguration(selectedText: selectedText)
        let generationProfile = LocalLLMGenerationProfile.currentCorrection(
            for: spokenCommand + selectedText
        )
        return CorrectionRequest(
            promptText: spokenCommand,
            fallbackText: selectedText,
            inputMode: "selection_edit",
            webText: nil,
            androidText: nil,
            promptConfiguration: promptConfiguration,
            generationProfile: generationProfile
        )
    }

    private func translationCorrectionRequest(recognizedText: String) -> CorrectionRequest {
        let targetLanguage = LocalLLMSettingsStore.translationTargetLanguage.promptName
        if ASRProviderStore.selected == .mix {
            let webText = providerTranscript("web")
            let androidText = providerTranscript("android")
            if !webText.isEmpty, !androidText.isEmpty {
                return CorrectionRequest(
                    promptText: Self.mixCorrectionPromptText(webText: webText, androidText: androidText),
                    fallbackText: preferredMixFallback(webText: webText, androidText: androidText),
                    inputMode: "translation_mix_dual",
                    webText: webText,
                    androidText: androidText,
                    promptConfiguration: Self.translationMixPromptConfiguration(targetLanguage: targetLanguage)
                )
            }

            let fallback = [webText, androidText, recognizedText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? recognizedText
            return CorrectionRequest(
                promptText: fallback,
                fallbackText: fallback,
                inputMode: "translation_mix_single_available",
                webText: webText.isEmpty ? nil : webText,
                androidText: androidText.isEmpty ? nil : androidText,
                promptConfiguration: Self.translationPromptConfiguration(targetLanguage: targetLanguage)
            )
        }

        return CorrectionRequest(
            promptText: recognizedText,
            fallbackText: recognizedText,
            inputMode: "translation",
            webText: nil,
            androidText: nil,
            promptConfiguration: Self.translationPromptConfiguration(targetLanguage: targetLanguage)
        )
    }

    private func providerTranscript(_ provider: String) -> String {
        latestProviderTranscripts[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func preferredMixFallback(webText: String, androidText: String) -> String {
        if !webText.isEmpty { return webText }
        return androidText
    }

    private func displayTranscript() -> String {
        if ASRProviderStore.selected != .mix {
            return latestProviderTranscripts.values.first ?? ""
        }

        return latestProviderTranscripts.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .max { lhs, rhs in lhs.count < rhs.count } ?? ""
    }

    nonisolated static func areEquivalentMixTranscripts(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizeMixTranscriptForEquality(lhs)
        let rhs = normalizeMixTranscriptForEquality(rhs)
        return !lhs.isEmpty && lhs == rhs
    }

    private nonisolated static func normalizeMixTranscriptForEquality(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private func finishTranscription(with text: String) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.info("Finish transcription chars=\(finalText.count)")
        isCompletingTranscription = false
        selectionEditTarget = nil
        translationSessionActive = false
        appState.overlayMode = .dictation
        completionTask = nil
        appState.lastTranscript = finalText
        transcriptionTrace?.set("corrected_text", finalText)
        transcriptionTrace?.startSpan("paste.enqueue")
        let pasteOutcome = PasteHelper.copyAndPaste(finalText)
        transcriptionTrace?.finishSpan("paste.enqueue", metadata: [
            "final_chars": String(finalText.count),
            "paste_outcome": pasteOutcome.traceValue
        ])
        finishCurrentTrace(outcome: "completed", metadata: [
            "final_chars": String(finalText.count),
            "paste_outcome": pasteOutcome.traceValue
        ])
        appState.transcript = ""
        switch pasteOutcome {
        case .copiedOnly(let reason):
            appState.errorMessage = reason == "accessibility_permission_denied"
                ? Self.accessibilityPermissionMessage
                : Self.focusTextInputCopiedMessage
            setRecordingState(.idle)
            resetToIdle(after: 1.8)
        case .enqueuedPaste, .skippedEmpty:
            resetToIdle(after: 0)
        }
    }

    private func handleAuthFailure(provider failedProvider: String) {
        AppLog.error("Handling auth failure; clearing ASR params provider=\(failedProvider)")
        transcriptionTrace?.event("asr.auth_failure", metadata: ["asr_provider": failedProvider])
        switch failedProvider {
        case "web":
            ASRParamsStore.clear()
            appState.loginStatus = .notLoggedIn
        case "android":
            DoubaoAndroidCredentialStore.clear()
        default:
            break
        }
        usingCachedParams = false
        cancelActiveSession()
        appState.transcript = ""
        appState.errorMessage = failedProvider == "web"
            ? Self.authExpiredMessage
            : L10n.text(en: "Android ASR credentials expired and will be recreated on the next recording.", zh: "Android ASR 凭据失效，将在下次录音时重新创建")
        logASRResultSummary(reason: "auth_failure")
        finishCurrentTrace(outcome: "failed", metadata: ["reason": "auth_expired"])
        resetToIdle(after: 1.5)
        onAuthExpired?()
    }

    private func completeWithoutRecognizedText() {
        AppLog.info("Complete without recognized text")
        awaitingFinalResult = false
        isCompletingTranscription = false
        translationSessionActive = false
        completionTask?.cancel()
        completionTask = nil
        cancelFinalTimers()
        cancelActiveSession()
        appState.errorMessage = Self.noRecognizedTextMessage
        appState.transcript = ""
        logASRResultSummary(reason: "no_text")
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
        selectionEditTarget = nil
        translationSessionActive = false
        holdRecordingStartedAt = nil
        appState.overlayMode = .dictation
        setRecordingState(.idle)
        overlayPanel.hide()
        appState.errorMessage = nil
        appState.transcript = ""
        appState.resetAudioLevels()
        usingCachedParams = false
        isHandlingConnectionError = false
        isCompletingTranscription = false
    }

    private func blockStartForMissingTextInput(_ inputFocus: TextInputFocusCheck.Result) {
        let reason = inputFocus.blockedReason ?? "unknown"
        AppLog.info("Start blocked: no focused text input reason=\(reason)")
        appState.errorMessage = reason == "accessibility_permission_denied"
            ? Self.accessibilityPermissionMessage
            : Self.focusTextInputMessage
        appState.transcript = ""
        appState.resetAudioLevels()
        transcriptionTrace?.event("input_focus.blocked", metadata: inputFocus.traceMetadata)
        setRecordingState(.idle)
        overlayPanel.show()
        finishCurrentTrace(outcome: "blocked", metadata: [
            "reason": "no_focused_text_input",
            "focus_reason": reason
        ])
        resetToIdle(after: 1.5)
    }

    private func setRecordingState(_ state: RecordingState) {
        AppLog.info("Recording state \(appState.recordingState) -> \(state)")
        if state != .starting {
            cancelStartTimeout()
        }
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

    private func recordASRResultProgress(
        result: ASRRecognitionResult,
        rawChars: Int,
        selectedChars: Int
    ) {
        guard asrResultCount == 1 || asrResultCount % 25 == 0 || awaitingFinalResult else { return }
        let sample = "\(asrResultCount):\(result.provider):\(result.kind):segments=\(result.segmentCount):chars=\(rawChars):selected=\(selectedChars):final=\(result.isFinal)"
        Self.appendSummarySample(sample, to: &asrResultProgressSamples)
    }

    private func logASRResultSummary(reason: String) {
        guard !asrResultSummaryLogged, asrResultCount > 0 else { return }
        asrResultSummaryLogged = true
        let providerMaxChars = maxASRResultCharsByProvider
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        let latestChars = latestProviderTranscripts
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.count)" }
            .joined(separator: ",")
        AppLog.info("ASR result summary reason=\(reason) total=\(asrResultCount) providerMaxChars=[\(providerMaxChars)] latestChars=[\(latestChars)] samples=\(Self.formatSamples(asrResultProgressSamples))")
    }

    private func handleRecordingStartTimeout(sessionID: UUID) {
        guard activeSessionID == sessionID, appState.recordingState == .starting else { return }
        AppLog.error("Recording start timed out")
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "timeout"])
        transcriptionTrace?.finishSpan("asr.connect", metadata: ["result": "timeout"])
        awaitingFinalResult = false
        cancelFinalTimers()
        cancelActiveSession()
        appState.errorMessage = Self.recordingStartTimeoutMessage
        appState.transcript = ""
        appState.resetAudioLevels()
        finishCurrentTrace(outcome: "failed", metadata: ["reason": "recording_start_timeout"])
        resetToIdle(after: 2)
    }

    private static func appendSummarySample(_ sample: String, to samples: inout [String]) {
        if samples.count < Self.maxASRResultSummarySamples {
            samples.append(sample)
        } else {
            samples[Self.maxASRResultSummarySamples - 1] = "...\(sample)"
        }
    }

    private static func formatSamples(_ samples: [String]) -> String {
        "[\(samples.joined(separator: ","))]"
    }

    private func handleAudioStartFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "failed"])
        AppLog.error("Audio capture failed error=\(error.localizedDescription)")
        appState.errorMessage = L10n.text(en: "Microphone failed: \(error.localizedDescription)", zh: "麦克风失败：\(error.localizedDescription)")
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

    nonisolated static func mixCorrectionPromptText(webText: String, androidText: String) -> String {
        """
        识别结果一（Doubao Web）：
        \(webText)

        识别结果二（Doubao Android）：
        \(androidText)

        只输出合并后的最终正文：
        """
    }

    private static func mixPromptConfiguration() -> LocalLLMPromptConfiguration {
        let current = LocalLLMPromptConfiguration.current
        let systemPrompt = """
        \(current.systemPromptTemplate)

        # 双路 ASR 合并
        - 本次输入包含两路 ASR 识别结果；请综合两路信号，合并成一个最终文本
        - 两路内容可能有重叠、漏字、错词或标点差异；优先保留共同语义
        - 用另一结果补足明显漏识别或错识别的片段
        - 不要重复输出同一内容
        - 不要输出“识别结果一”“识别结果二”“Doubao Web”“Doubao Android”等输入标签
        """

        return LocalLLMPromptConfiguration(
            systemPromptTemplate: systemPrompt,
            userPromptTemplate: """
            双路 ASR 输入：
            {{original}}

            只输出合并后的最终正文：
            """,
            vocabulary: current.vocabulary,
            punctuationStyle: current.punctuationStyle,
            removeFillerWords: current.removeFillerWords,
            softenEmotionalLanguage: current.softenEmotionalLanguage,
            outputStyle: current.outputStyle,
            outputStyleStrength: current.outputStyleStrength,
            customOutputStyleInstruction: current.customOutputStyleInstruction,
            environmentContext: current.environmentContext,
            userIdentity: current.userIdentity,
            selectedText: current.selectedText,
            translationLanguage: current.translationLanguage
        )
    }

    private static func selectionEditPromptConfiguration(selectedText: String) -> LocalLLMPromptConfiguration {
        let current = LocalLLMPromptConfiguration.current
        return LocalLLMPromptConfiguration(
            systemPromptTemplate: current.systemPromptTemplate,
            userPromptTemplate: current.userPromptTemplate,
            vocabulary: current.vocabulary,
            punctuationStyle: current.punctuationStyle,
            removeFillerWords: current.removeFillerWords,
            softenEmotionalLanguage: current.softenEmotionalLanguage,
            outputStyle: current.outputStyle,
            outputStyleStrength: current.outputStyleStrength,
            customOutputStyleInstruction: current.customOutputStyleInstruction,
            environmentContext: current.environmentContext,
            userIdentity: current.userIdentity,
            selectedText: selectedText,
            translationLanguage: ""
        )
    }

    private static func translationPromptConfiguration(targetLanguage: String) -> LocalLLMPromptConfiguration {
        let current = LocalLLMPromptConfiguration.current
        return LocalLLMPromptConfiguration(
            systemPromptTemplate: current.systemPromptTemplate,
            userPromptTemplate: current.userPromptTemplate,
            vocabulary: current.vocabulary,
            punctuationStyle: current.punctuationStyle,
            removeFillerWords: current.removeFillerWords,
            softenEmotionalLanguage: current.softenEmotionalLanguage,
            outputStyle: current.outputStyle,
            outputStyleStrength: current.outputStyleStrength,
            customOutputStyleInstruction: current.customOutputStyleInstruction,
            environmentContext: current.environmentContext,
            userIdentity: current.userIdentity,
            selectedText: "",
            translationLanguage: targetLanguage
        )
    }

    private static func translationMixPromptConfiguration(targetLanguage: String) -> LocalLLMPromptConfiguration {
        let current = translationPromptConfiguration(targetLanguage: targetLanguage)
        let systemPrompt = """
        \(current.systemPromptTemplate)

        # 双路 ASR 合并
        - 本次输入包含两路 ASR 识别结果；请综合两路信号后再翻译
        - 两路内容可能有重叠、漏字、错词或标点差异；优先保留共同语义
        - 用另一结果补足明显漏识别或错识别的片段
        - 不要重复输出同一内容
        - 不要输出“识别结果一”“识别结果二”“Doubao Web”“Doubao Android”等输入标签
        """

        return LocalLLMPromptConfiguration(
            systemPromptTemplate: systemPrompt,
            userPromptTemplate: current.userPromptTemplate,
            vocabulary: current.vocabulary,
            punctuationStyle: current.punctuationStyle,
            removeFillerWords: current.removeFillerWords,
            softenEmotionalLanguage: current.softenEmotionalLanguage,
            outputStyle: current.outputStyle,
            outputStyleStrength: current.outputStyleStrength,
            customOutputStyleInstruction: current.customOutputStyleInstruction,
            environmentContext: current.environmentContext,
            userIdentity: current.userIdentity,
            selectedText: current.selectedText,
            translationLanguage: current.translationLanguage
        )
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
