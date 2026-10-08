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
        L10n.text(en: "Microphone failed to start.", zh: "麦克风启动失败")
    }

    private static var speechRecognitionStartTimeoutMessage: String {
        L10n.text(en: "Speech recognition did not connect.", zh: "语音识别连接失败")
    }

    private static var speechRecognitionServiceTimeoutMessage: String {
        L10n.text(en: "Speech recognition timed out.", zh: "语音识别超时")
    }

    private static var androidConcurrencyQuotaFullMessage: String {
        L10n.text(
            en: "Android concurrency quota is full.",
            zh: "Android 服务并发配额已满"
        )
    }

    private static var androidAuthExpiredMessage: String {
        L10n.text(
            en: "Android recognition credentials expired.",
            zh: "Android 识别凭据已失效"
        )
    }

    private static var bageshuoAuthExpiredMessage: String {
        L10n.text(
            en: "Bage Shuo login expired.",
            zh: "叭哥说登录已失效"
        )
    }

    private static var chatterflyAuthExpiredMessage: String {
        L10n.text(
            en: "Chatterfly login expired.",
            zh: "Chatterfly 登录已失效"
        )
    }

    private static var recognitionFailedMessage: String {
        L10n.text(en: "Recognition failed.", zh: "识别失败")
    }

    private static var microphoneFailedMessage: String {
        L10n.text(en: "Microphone failed.", zh: "麦克风不可用")
    }

    private static var focusTextInputCopiedMessage: String {
        L10n.text(en: "No text field found. Copied to clipboard.", zh: "未找到输入框，已复制到剪贴板")
    }

    private let appState: AppState
    private let webViewManager: WebViewManager
    private let bageshuoWebViewManager: BageshuoWebViewManager
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
    private var failedASRProviders = Set<String>()
    private var audioReady = false
    private var finishedASRProviders = Set<String>()
    private var selectionEditTarget: String?
    private var translationSessionActive = false
    private var activeContextSnapshot = DictationContextSnapshot.empty
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
        bageshuoWebViewManager: BageshuoWebViewManager,
        overlayPanel: OverlayPanel,
        hotkeyManager: HotkeyManager
    ) {
        self.appState = appState
        self.webViewManager = webViewManager
        self.bageshuoWebViewManager = bageshuoWebViewManager
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
    }

    func start() {
        AppLog.info("Transcription hotkey handler installing")
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            let receivedAt = ProcessInfo.processInfo.systemUptime
            AppLog.info("Hotkey event received event=\(event)")
            guard let self else {
                AppLog.error("Hotkey event dropped: TranscriptionManager released event=\(event)")
                return
            }
            if Thread.isMainThread {
                AppLog.info("Hotkey event handling on main event=\(event)")
                self.handleHotkeyEvent(event)
            } else {
                DispatchQueue.main.async { [self] in
                    AppLog.info("Hotkey event dispatched to main event=\(event) dispatch_ms=\(Self.milliseconds(since: receivedAt))")
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
        case .asrAuthError(let provider, let error):
            handleASRAuthError(provider: provider, error: error)
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
        guard activeASRProviders.contains(provider) || !failedASRProviders.contains(provider) else {
            AppLog.info("Dropped late ASR open from failed provider=\(provider)")
            return
        }
        openedASRProviders.insert(provider)
        transcriptionTrace?.event("asr.opened", metadata: ["asr_provider": provider])
        if hasUsableASRConnection {
            transcriptionTrace?.finishSpan("asr.connect", metadata: [
                "result": "opened",
                "opened_providers": openedASRProviders.sorted().joined(separator: ",")
            ])
            if audioReady {
                cancelStartTimeout()
            }
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
        } else if hasUsableASRConnection {
            cancelStartTimeout()
        }
    }

    /// The user is recording as soon as microphone capture starts. ASR may still be connecting,
    /// and AudioCaptureManager will buffer provider-specific audio until the socket opens.
    private func tryTransitionToRecording(trigger: String) {
        guard audioReady else {
            AppLog.info("Waiting for audio before recording: asrUsable=\(hasUsableASRConnection) trigger=\(trigger)")
            return
        }
        AppLog.info("Audio ready; recording state -> recording (trigger=\(trigger) asrUsable=\(hasUsableASRConnection))")
        setRecordingState(.recording)
        if hasUsableASRConnection {
            cancelStartTimeout()
        }
    }

    private var hasUsableASRConnection: Bool {
        !openedASRProviders.isDisjoint(with: activeASRProviders)
    }

    private func handleASRResult(_ result: ASRRecognitionResult) {
        guard activeASRProviders.contains(result.provider) || !failedASRProviders.contains(result.provider) else {
            AppLog.info("Dropped late ASR result from failed provider=\(result.provider) chars=\(result.text.count)")
            return
        }
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
        guard activeASRProviders.contains(provider) || !failedASRProviders.contains(provider) else {
            AppLog.info("Dropped late ASR finish from failed provider=\(provider)")
            return
        }
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
        guard activeASRProviders.contains(provider) || !failedASRProviders.contains(provider) else {
            AppLog.info("Dropped repeated ASR error from failed provider=\(provider) error=\(error?.localizedDescription ?? "unknown")")
            return
        }
        let willContinue = canContinueAfterASRProviderFailure(provider: provider)
        writeASRErrorDiagnostic(provider: provider, error: error, reason: "asr_error", willContinue: willContinue)
        if shouldContinueAfterASRProviderFailure(provider: provider, error: error) {
            return
        }
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
            appState.errorMessage = Self.userFacingASRErrorMessage(error)
            logASRResultSummary(reason: "connection_error")
            finishCurrentTrace(outcome: "failed", metadata: [
                "reason": "asr_connection_error",
                "error": error?.localizedDescription ?? "unknown"
            ])
            resetToIdle(after: 1.8)
        }
    }

    private func handleASRAuthError(provider: String, error: TranscriptionSessionError?) {
        let authError = error ?? TranscriptionSessionError(
            domain: "Douvo.ASRAuth",
            code: 1,
            localizedDescription: "ASR authentication failed"
        )
        AppLog.error(
            "ASR auth error provider=\(provider) domain=\(authError.domain) code=\(authError.code) message=\(authError.localizedDescription) metadata=\(authError.metadata)"
        )
        let willContinue = canContinueAfterASRProviderFailure(provider: provider)
        writeASRErrorDiagnostic(provider: provider, error: authError, reason: "asr_auth_error", willContinue: willContinue)
        if shouldContinueAfterASRProviderFailure(provider: provider, error: authError) {
            clearASRAuthState(provider: provider)
            if provider == "web" || provider == "bageshuo" || provider == "chatterfly" {
                AppLog.info("ASR auth expired; opening login while continuing with remaining provider provider=\(provider)")
                onAuthExpired?()
            }
            return
        }
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
                appState.errorMessage = L10n.text(en: "Translation requires AI.", zh: "翻译需要先开启 AI")
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
        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        let selection = ASRProviderStore.selected
        // Capture app/window context before Douvo shows its recording overlay.
        let shouldCaptureContext = LocalLLMPostProcessor.isCorrectionEnabled
            || (selection.usesAndroidASR && AndroidASRSettingsStore.sendContext)
        let environmentSnapshot = shouldCaptureContext
            ? PromptEnvironmentContext.capture()
            : .empty
        let environmentContext = environmentSnapshot.text
        let includeRecentDictationContext = shouldCaptureContext
            && LocalLLMSettingsStore.includeRecentDictationContext
        AppLog.info("Start recording requested providers=\(selection.storageValue) loginStatus=\(appState.loginStatus)")
        if transcriptionTrace != nil {
            finishCurrentTrace(outcome: "superseded", metadata: ["reason": "new_recording_started"])
        }
        transcriptionTrace = TranscriptionTrace()
        transcriptionTrace?.event("recording.start_requested", metadata: [
            "asr_providers": selection.storageValue,
            "login_status": String(describing: appState.loginStatus)
        ])
        transcriptionTrace?.startSpan("recording.user_audio")
        asrResultCount = 0
        asrResultSummaryLogged = false
        asrResultProgressSamples.removeAll(keepingCapacity: true)
        maxASRResultCharsByProvider.removeAll()
        latestProviderTranscripts.removeAll()
        activeASRProviders = selection.activeProviderKeys
        openedASRProviders.removeAll()
        failedASRProviders.removeAll()
        audioReady = false
        finishedASRProviders.removeAll()
        isHandlingConnectionError = false
        selectionEditTarget = nil
        translationSessionActive = false
        activeContextSnapshot = .empty
        appState.overlayMode = .dictation
        appState.transcript = ""
        appState.errorMessage = nil
        appState.resetAudioLevels()

        setRecordingState(.starting)
        AppLog.info("Recording startup stage=before_overlay_show total_ms=\(Self.milliseconds(since: startupStartedAt))")
        overlayPanel.show()
        AppLog.info("Recording startup stage=after_overlay_show show_ms=\(Self.milliseconds(since: startupStartedAt))")

        if TextInsertionSettingsStore.checksFocusedTextInputBeforeRecording {
            let focusStartedAt = ProcessInfo.processInfo.systemUptime
            let inputFocus = TextInputFocusCheck.capture()
            AppLog.info("Recording startup stage=focus_check ms=\(Self.milliseconds(since: focusStartedAt)) total_ms=\(Self.milliseconds(since: startupStartedAt))")
            transcriptionTrace?.event("input_focus.checked", metadata: inputFocus.traceMetadata)
            guard inputFocus.isTextInput else {
                AppLog.info("Recording startup blocked stage=focus_check total_ms=\(Self.milliseconds(since: startupStartedAt))")
                blockStartForMissingTextInput(inputFocus)
                return
            }
        } else {
            AppLog.info("Recording startup stage=focus_check result=skipped reason=disabled total_ms=\(Self.milliseconds(since: startupStartedAt))")
            transcriptionTrace?.event("input_focus.skipped", metadata: ["reason": "disabled"])
        }

        if LocalLLMSettingsStore.selectionEditingEnabled {
            let selectionStartedAt = ProcessInfo.processInfo.systemUptime
            let selectionPreparation = prepareSelectionEditingTarget()
            AppLog.info("Recording startup stage=selection_edit_read result=\(Self.selectionReadResultName(selectionPreparation)) ms=\(Self.milliseconds(since: selectionStartedAt)) total_ms=\(Self.milliseconds(since: startupStartedAt))")
            if selectionPreparation == .tooLong {
                AppLog.info("Start blocked: selected text too long")
                appState.errorMessage = Self.selectionTooLongMessage
                transcriptionTrace?.event("selection_edit.blocked", metadata: [
                    "reason": "selection_too_long",
                    "max_chars": String(SelectedTextReader.maxSelectionCharacters)
                ])
                setRecordingState(.idle)
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
        } else {
            AppLog.info("Recording startup stage=selection_edit_read result=skipped reason=disabled total_ms=\(Self.milliseconds(since: startupStartedAt))")
        }

        var webParams: DoubaoASRParams?
        var bageshuoParams: BageshuoASRParams?
        if selection.requiresAICorrection, !LocalLLMPostProcessor.isCorrectionEnabled {
            AppLog.error("Start blocked: multi-route ASR requires AI Correction")
            appState.errorMessage = L10n.text(en: "Multi-route recognition requires AI.", zh: "多路识别需要先开启 AI")
            setRecordingState(.idle)
            overlayPanel.show()
            finishCurrentTrace(outcome: "blocked", metadata: ["reason": "multi_route_requires_ai_correction"])
            resetToIdle(after: 1.8)
            return
        }

        if selection.usesWebASR {
            transcriptionTrace?.startSpan("asr.load_params")
            let loadParamsStartedAt = ProcessInfo.processInfo.systemUptime
            guard let params = ASRParamsStore.load() else {
                AppLog.info("Recording startup stage=asr_load_params result=missing ms=\(Self.milliseconds(since: loadParamsStartedAt)) total_ms=\(Self.milliseconds(since: startupStartedAt))")
                transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "missing"])
                AppLog.error("Start blocked: ASR params missing")
                appState.errorMessage = Self.authExpiredMessage
                appState.loginStatus = .notLoggedIn
                setRecordingState(.idle)
                overlayPanel.show()
                webViewManager.showLoginWindow()
                finishCurrentTrace(outcome: "blocked", metadata: ["reason": "asr_params_missing"])
                resetToIdle(after: 1.5)
                return
            }
            AppLog.info("Recording startup stage=asr_load_params result=loaded ms=\(Self.milliseconds(since: loadParamsStartedAt)) total_ms=\(Self.milliseconds(since: startupStartedAt))")
            webParams = params
            transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "loaded"])
            AppLog.info("Connecting Web ASR params cookieCount=\(params.cookies.count) deviceIdSet=\(!params.deviceId.isEmpty) webIdSet=\(!params.webId.isEmpty)")
            transcriptionTrace?.event("asr.connect_requested", metadata: [
                "asr_providers": selection.storageValue,
                "active_providers": activeASRProviders.sorted().joined(separator: ","),
                "cookie_count": String(params.cookies.count),
                "has_device_id": String(!params.deviceId.isEmpty),
                "has_web_id": String(!params.webId.isEmpty)
            ])
        }

        if selection.usesBageshuoASR {
            transcriptionTrace?.startSpan("asr.load_params")
            let loadParamsStartedAt = ProcessInfo.processInfo.systemUptime
            guard let params = BageshuoASRParamsStore.load() else {
                AppLog.info("Recording startup stage=asr_load_params result=missing ms=\(Self.milliseconds(since: loadParamsStartedAt)) total_ms=\(Self.milliseconds(since: startupStartedAt))")
                transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "missing"])
                appState.errorMessage = Self.bageshuoAuthExpiredMessage
                appState.loginStatus = .notLoggedIn
                setRecordingState(.idle)
                overlayPanel.show()
                bageshuoWebViewManager.showLoginWindow()
                finishCurrentTrace(outcome: "blocked", metadata: ["reason": "asr_params_missing"])
                resetToIdle(after: 1.5)
                return
            }
            bageshuoParams = params
            transcriptionTrace?.finishSpan("asr.load_params", metadata: ["result": "loaded"])
            transcriptionTrace?.event("asr.connect_requested", metadata: [
                "asr_providers": selection.storageValue,
                "active_providers": activeASRProviders.sorted().joined(separator: ","),
                "cookie_count": String(params.cookies.count)
            ])
        }

        if selection.usesChatterflyASR, !ChatterflyAuthTokenStore.hasUsableCredentials {
            AppLog.error("Start blocked: Chatterfly credentials are missing")
            appState.errorMessage = Self.chatterflyAuthExpiredMessage
            appState.loginStatus = .notLoggedIn
            setRecordingState(.idle)
            overlayPanel.show()
            finishCurrentTrace(outcome: "blocked", metadata: ["reason": "chatterfly_auth_missing"])
            onAuthExpired?()
            resetToIdle(after: 1.5)
            return
        }

        if !selection.usesWebASR && !selection.usesBageshuoASR {
            transcriptionTrace?.event("asr.connect_requested", metadata: [
                "asr_providers": selection.storageValue,
                "active_providers": activeASRProviders.sorted().joined(separator: ",")
            ])
        }

        transcriptionTrace?.startSpan("audio.start_capture")
        usingCachedParams = true
        transcriptionTrace?.startSpan("asr.connect")

        let sessionID = UUID()
        let session = TranscriptionSession(selection: selection) { [weak self] event in
            self?.handleSessionEvent(event, sessionID: sessionID)
        }
        activeSessionID = sessionID
        transcriptionSession = session
        scheduleStartTimeout(sessionID: sessionID)
        sessionStartTask?.cancel()
        sessionStartTask = Task { [weak self, session] in
            guard let self else { return }
            do {
                let recentDictationContext = includeRecentDictationContext
                    ? await RecentDictationContext.shared.fetchContext()
                    : ""
                try Task.checkCancellation()
                guard self.activeSessionID == sessionID else { return }

                let contextSnapshot = DictationContextSnapshot(
                    environmentContext: environmentContext,
                    recentDictationContext: recentDictationContext,
                    activeAppBundleID: environmentSnapshot.activeAppBundleID
                )
                self.activeContextSnapshot = contextSnapshot
                let androidContext = AndroidASRContextBuilder.make(
                    snapshot: contextSnapshot,
                    includeContext: selection.usesAndroidASR && AndroidASRSettingsStore.sendContext
                )
                let androidVocabulary = selection.usesAndroidASR
                    && AndroidASRSettingsStore.personalLexiconEnabled
                    ? LocalLLMSettingsStore.effectiveVocabulary
                    : ""
                let androidVocabularyCount = DoubaoAndroidPersonalLexicon.words(
                    from: androidVocabulary
                ).count
                self.transcriptionTrace?.set("asr.android.context_payload_enabled", !androidContext.isEmpty)
                self.transcriptionTrace?.set("asr.android.shared_context_chars", contextSnapshot.androidText.count)
                self.transcriptionTrace?.set(
                    "asr.android.personal_lexicon_enabled",
                    androidVocabularyCount > 0
                )
                self.transcriptionTrace?.set(
                    "asr.android.personal_lexicon_words",
                    androidVocabularyCount
                )
                try await session.start(
                    webParams: webParams,
                    bageshuoParams: bageshuoParams,
                    androidContext: androidContext,
                    androidVocabulary: androidVocabulary
                )
            } catch {
                AppLog.error("Session start failed: \(error)")
                await MainActor.run {
                    self.handleSessionStartFailure(error, selection: selection, sessionID: sessionID)
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
        // Android sends FinishSession immediately after its final audio frame,
        // then keeps receiving the two-pass/nonstream revision until the server
        // ends the session. The hard timeout remains the stuck-provider guard.
        scheduleQuietCompletion()
        scheduleHardCompletion()
    }

    private func scheduleQuietCompletion() {
        quietCompletionWork?.cancel()
        quietCompletionWork = nil
        guard !isWaitingForAndroidFinalization,
              !isWaitingForChatterflyFinalization else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinalResult, self.appState.recordingState == .stopping else { return }
            AppLog.info("Final quiet timeout; completing chars=\(self.appState.transcript.count)")
            self.transcriptionTrace?.finishSpan("asr.final_wait", metadata: ["completion_trigger": "quiet_timeout"])
            self.completeTranscription(trigger: "quiet_timeout")
        }
        quietCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finalQuietInterval, execute: work)
    }

    private var isWaitingForAndroidFinalization: Bool {
        awaitingFinalResult
            && activeASRProviders.contains("android")
            && !finishedASRProviders.contains("android")
            && !failedASRProviders.contains("android")
    }

    private var isWaitingForChatterflyFinalization: Bool {
        awaitingFinalResult
            && activeASRProviders.contains("chatterfly")
            && !finishedASRProviders.contains("chatterfly")
            && !failedASRProviders.contains("chatterfly")
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
                  self.appState.recordingState == .starting || self.appState.recordingState == .recording else {
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
            for (provider, providerText) in correctionRequest.providerTexts {
                transcriptionTrace?.set("asr.\(provider).final_text", providerText)
                transcriptionTrace?.set("asr.\(provider).final_chars", providerText.count)
            }
            isCompletingTranscription = true
            completionTask?.cancel()
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let finalText: String
                var correctionOutcome: String = ""
                do {
                    let promptConfig = (
                        correctionRequest.promptConfiguration ?? LocalLLMPromptConfiguration.current
                    ).withContextSnapshot(self.activeContextSnapshot)
                    let result = try await CorrectionPostProcessor.shared.correctedTextWithTrace(
                        for: correctionRequest.promptText,
                        requiresEnabled: true,
                        promptConfiguration: promptConfig,
                        generationProfile: correctionRequest.generationProfile,
                        fallbackText: correctionRequest.fallbackText
                    )
                    self.transcriptionTrace?.addTimings(result.timings)
                    for (key, value) in result.metadata {
                        self.transcriptionTrace?.set("correction.\(key)", value)
                    }
                    finalText = result.text
                    correctionOutcome = result.metadata["outcome"] ?? ""
                } catch {
                    self.transcriptionTrace?.event("correction.failed", metadata: ["error": error.localizedDescription])
                    AppLog.error("Local LLM postprocess failed; using raw text error=\(error.localizedDescription)")
                    finalText = correctionRequest.fallbackText
                }

                guard !Task.isCancelled, self.isCompletingTranscription else { return }
                // Record successful dictation for future context (after cancellation check)
                if correctionOutcome == "corrected" || correctionOutcome == "unchanged" {
                    await RecentDictationContext.shared.record(finalText)
                }
                self.finishTranscription(with: finalText)
            }
        }
    }

    private struct CorrectionRequest {
        let promptText: String
        let fallbackText: String
        let inputMode: String
        let providerTexts: [String: String]
        let promptConfiguration: LocalLLMPromptConfiguration?
        let generationProfile: LocalLLMGenerationProfile?

        init(
            promptText: String,
            fallbackText: String,
            inputMode: String,
            providerTexts: [String: String],
            promptConfiguration: LocalLLMPromptConfiguration?,
            generationProfile: LocalLLMGenerationProfile? = nil
        ) {
            self.promptText = promptText
            self.fallbackText = fallbackText
            self.inputMode = inputMode
            self.providerTexts = providerTexts
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

        let selection = ASRProviderStore.selected
        guard selection.requiresAICorrection else {
            return CorrectionRequest(
                promptText: recognizedText,
                fallbackText: recognizedText,
                inputMode: "single",
                providerTexts: [:],
                promptConfiguration: nil
            )
        }

        let providerTexts = providerTranscripts(for: selection)
        guard providerTexts.count >= 2 else {
            let fallback = preferredMultiFallback(providerTexts, recognizedText: recognizedText)
            return CorrectionRequest(
                promptText: fallback,
                fallbackText: fallback,
                inputMode: "multi_single_available",
                providerTexts: providerTexts,
                promptConfiguration: nil
            )
        }

        if Self.areEquivalentTranscripts(Array(providerTexts.values)) {
            let text = preferredMultiFallback(providerTexts, recognizedText: recognizedText)
            return CorrectionRequest(
                promptText: text,
                fallbackText: text,
                inputMode: "multi_equivalent",
                providerTexts: providerTexts,
                promptConfiguration: nil
            )
        }

        let fallback = preferredMultiFallback(providerTexts, recognizedText: recognizedText)
        return CorrectionRequest(
            promptText: Self.multiCorrectionPromptText(providerTexts: providerTexts),
            fallbackText: fallback,
            inputMode: "multi",
            providerTexts: providerTexts,
            promptConfiguration: Self.multiPromptConfiguration()
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
            providerTexts: [:],
            promptConfiguration: promptConfiguration,
            generationProfile: generationProfile
        )
    }

    private func translationCorrectionRequest(recognizedText: String) -> CorrectionRequest {
        let targetLanguage = LocalLLMSettingsStore.translationTargetLanguage.promptName
        if ASRProviderStore.selected.requiresAICorrection {
            let providerTexts = providerTranscripts(for: ASRProviderStore.selected)
            if providerTexts.count >= 2 {
                return CorrectionRequest(
                    promptText: Self.multiCorrectionPromptText(providerTexts: providerTexts),
                    fallbackText: preferredMultiFallback(providerTexts, recognizedText: recognizedText),
                    inputMode: "translation_multi",
                    providerTexts: providerTexts,
                    promptConfiguration: Self.translationMultiPromptConfiguration(targetLanguage: targetLanguage)
                )
            }

            let fallback = preferredMultiFallback(providerTexts, recognizedText: recognizedText)
            return CorrectionRequest(
                promptText: fallback,
                fallbackText: fallback,
                inputMode: "translation_multi_single_available",
                providerTexts: providerTexts,
                promptConfiguration: Self.translationPromptConfiguration(targetLanguage: targetLanguage)
            )
        }

        return CorrectionRequest(
            promptText: recognizedText,
            fallbackText: recognizedText,
            inputMode: "translation",
            providerTexts: [:],
            promptConfiguration: Self.translationPromptConfiguration(targetLanguage: targetLanguage)
        )
    }

    private func providerTranscript(_ provider: String) -> String {
        latestProviderTranscripts[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func providerTranscripts(for selection: ASRProviderSelection) -> [String: String] {
        selection.sortedProviders.reduce(into: [String: String]()) { result, provider in
            let text = providerTranscript(provider.rawValue)
            if !text.isEmpty {
                result[provider.rawValue] = text
            }
        }
    }

    private func preferredMultiFallback(
        _ providerTexts: [String: String],
        recognizedText: String
    ) -> String {
        for provider in ASRProvider.allCases {
            if let text = providerTexts[provider.rawValue], !text.isEmpty {
                return text
            }
        }
        return recognizedText
    }

    private func displayTranscript() -> String {
        if !ASRProviderStore.selected.requiresAICorrection {
            return latestProviderTranscripts.values.first ?? ""
        }

        return latestProviderTranscripts.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .max { lhs, rhs in lhs.count < rhs.count } ?? ""
    }

    nonisolated static func areEquivalentTranscripts(_ texts: [String]) -> Bool {
        let normalized = texts.map(normalizeMultiTranscriptForEquality).filter { !$0.isEmpty }
        return normalized.count >= 2 && Set(normalized).count == 1
    }

    private nonisolated static func normalizeMultiTranscriptForEquality(_ text: String) -> String {
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
        appState.transcriptHistory = TranscriptHistoryStore.record(finalText)
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
        clearASRAuthState(provider: failedProvider)
        usingCachedParams = false
        cancelActiveSession()
        appState.transcript = ""
        switch failedProvider {
        case "web":
            appState.errorMessage = Self.authExpiredMessage
        case "bageshuo":
            appState.errorMessage = Self.bageshuoAuthExpiredMessage
        case "chatterfly":
            appState.errorMessage = Self.chatterflyAuthExpiredMessage
        default:
            appState.errorMessage = Self.androidAuthExpiredMessage
        }
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
        overlayPanel.hide()
        awaitingFinalResult = false
        cancelActiveSession()
        selectionEditTarget = nil
        translationSessionActive = false
        holdRecordingStartedAt = nil
        appState.overlayMode = .dictation
        setRecordingState(.idle)
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
        if state == .idle || state == .stopping {
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

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func selectionReadResultName(_ result: SelectedTextReadResult) -> String {
        switch result {
        case .none:
            "none"
        case .text:
            "text"
        case .tooLong:
            "too_long"
        }
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
        guard activeSessionID == sessionID,
              appState.recordingState == .starting || appState.recordingState == .recording else {
            return
        }
        let asrUsable = hasUsableASRConnection
        guard !audioReady || !asrUsable else {
            cancelStartTimeout()
            return
        }

        let reason: String
        if !audioReady {
            AppLog.error("Recording start timed out")
            transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "timeout"])
            if !asrUsable {
                transcriptionTrace?.finishSpan("asr.connect", metadata: ["result": "timeout"])
            }
            appState.errorMessage = Self.recordingStartTimeoutMessage
            reason = "recording_start_timeout"
        } else {
            AppLog.error("ASR connection timed out")
            transcriptionTrace?.finishSpan("asr.connect", metadata: [
                "result": "timeout",
                "opened_providers": openedASRProviders.sorted().joined(separator: ",")
            ])
            appState.errorMessage = Self.speechRecognitionStartTimeoutMessage
            reason = "asr_connect_timeout"
        }

        let error = TranscriptionSessionError(
            domain: "Douvo.ASR",
            code: 1002,
            localizedDescription: reason
        )
        writeASRErrorDiagnostic(provider: "session", error: error, reason: reason, willContinue: false)
        awaitingFinalResult = false
        cancelFinalTimers()
        cancelActiveSession()
        appState.transcript = ""
        appState.resetAudioLevels()
        finishCurrentTrace(outcome: "failed", metadata: ["reason": reason])
        resetToIdle(after: 2)
    }

    private func shouldContinueAfterASRProviderFailure(provider: String, error: TranscriptionSessionError?) -> Bool {
        guard canContinueAfterASRProviderFailure(provider: provider) else { return false }
        let remainingProviders = activeASRProviders.subtracting([provider])

        failedASRProviders.insert(provider)
        activeASRProviders.remove(provider)
        finishedASRProviders.remove(provider)
        openedASRProviders.remove(provider)
        transcriptionTrace?.event("asr.provider_failed_continuing", metadata: [
            "asr_provider": provider,
            "remaining_providers": remainingProviders.sorted().joined(separator: ","),
            "error": error?.localizedDescription ?? "unknown"
        ])
        AppLog.error("ASR provider failed; continuing with remaining providers failed=\(provider) remaining=\(remainingProviders.sorted().joined(separator: ",")) error=\(error?.localizedDescription ?? "unknown")")

        if !hasUsableASRConnection, let activeSessionID {
            scheduleStartTimeout(sessionID: activeSessionID)
        } else if audioReady {
            cancelStartTimeout()
        }

        if appState.recordingState == .starting {
            tryTransitionToRecording(trigger: "asr_provider_failed")
        } else if awaitingFinalResult,
                  appState.recordingState == .stopping,
                  activeASRProviders.isSubset(of: finishedASRProviders) {
            transcriptionTrace?.finishSpan("asr.final_wait", metadata: [
                "completion_trigger": "provider_failed_remaining_finished",
                "finished_providers": finishedASRProviders.sorted().joined(separator: ","),
                "failed_providers": failedASRProviders.sorted().joined(separator: ",")
            ])
            completeTranscription(trigger: "provider_failed_remaining_finished")
        }
        return true
    }

    private func canContinueAfterASRProviderFailure(provider: String) -> Bool {
        activeASRProviders.contains(provider) && !activeASRProviders.subtracting([provider]).isEmpty
    }

    private func writeASRErrorDiagnostic(
        provider: String,
        error: TranscriptionSessionError?,
        reason: String,
        willContinue: Bool
    ) {
        var payload: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "provider": provider,
            "selected_asr_providers": ASRProviderStore.selected.storageValue,
            "recording_state": String(describing: appState.recordingState),
            "will_continue_with_remaining_provider": willContinue,
            "active_providers": activeASRProviders.sorted(),
            "opened_providers": openedASRProviders.sorted(),
            "failed_providers": failedASRProviders.sorted(),
            "finished_providers": finishedASRProviders.sorted(),
            "audio_ready": audioReady,
            "awaiting_final_result": awaitingFinalResult,
            "asr_result_count": asrResultCount,
            "transcript_chars": appState.transcript.count,
            "latest_provider_transcript_chars": latestProviderTranscripts
                .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines).count },
            "max_provider_result_chars": maxASRResultCharsByProvider
        ]

        if let error {
            payload["error"] = [
                "domain": error.domain,
                "code": error.code,
                "message": error.localizedDescription
            ]
            if !error.metadata.isEmpty {
                payload["client_metadata"] = error.metadata
            }
        }

        _ = ASRErrorDiagnosticStore.write(payload: payload, provider: provider, reason: reason)
    }

    private func clearASRAuthState(provider: String) {
        switch provider {
        case "web":
            ASRParamsStore.clear()
            appState.loginStatus = .notLoggedIn
        case "bageshuo":
            BageshuoASRParamsStore.clear()
            appState.loginStatus = .notLoggedIn
        case "android":
            DoubaoAndroidCredentialStore.clear()
        case "chatterfly":
            ChatterflyAuthTokenStore.clear()
            appState.loginStatus = .notLoggedIn
        default:
            break
        }
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
        appState.errorMessage = Self.microphoneFailedMessage
        finishCurrentTrace(outcome: "failed", metadata: [
            "reason": "audio_capture_failed",
            "error": error.localizedDescription
        ])
        resetToIdle(after: 2)
    }

    private func handleSessionStartFailure(
        _ error: Error,
        selection: ASRProviderSelection,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else { return }
        let sessionError = TranscriptionSessionError(error)
        transcriptionTrace?.finishSpan("asr.connect", metadata: ["result": "failed"])
        transcriptionTrace?.finishSpan("audio.start_capture", metadata: ["result": "not_started"])
        writeASRErrorDiagnostic(
            provider: "session",
            error: sessionError,
            reason: "session_start_failed",
            willContinue: false
        )
        appState.errorMessage = Self.userFacingASRErrorMessage(sessionError)
        finishCurrentTrace(outcome: "failed", metadata: [
            "reason": "session_start_failed",
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

    nonisolated static func multiCorrectionPromptText(providerTexts: [String: String]) -> String {
        let sections = ASRProvider.allCases.compactMap { provider -> String? in
            guard let text = providerTexts[provider.rawValue], !text.isEmpty else { return nil }
            return "识别结果（\(provider.displayName)）：\n\(text)"
        }
        return sections.joined(separator: "\n\n") + "\n\n只输出合并后的最终正文："
    }

    private static func multiPromptConfiguration() -> LocalLLMPromptConfiguration {
        let current = LocalLLMPromptConfiguration.current
        let systemPrompt = """
        \(current.systemPromptTemplate)

        # 多路 ASR 合并
        - 本次输入包含多路 ASR 识别结果；请综合所有信号，合并成一个最终文本
        - 各路内容可能有重叠、漏字、错词或标点差异；优先保留共同语义
        - 用其他结果补足明显漏识别或错识别的片段
        - 不要重复输出同一内容
        - 不要输出“识别结果”“Web”“Android”“Bage Shuo”“叭哥说”“Chatterfly”等输入标签
        """

        return LocalLLMPromptConfiguration(
            systemPromptTemplate: systemPrompt,
            userPromptTemplate: """
            多路 ASR 输入：
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
            activeAppBundleID: current.activeAppBundleID,
            userIdentity: current.userIdentity,
            selectedText: current.selectedText,
            translationLanguage: current.translationLanguage,
            recentDictationContext: current.recentDictationContext
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
            activeAppBundleID: current.activeAppBundleID,
            userIdentity: current.userIdentity,
            selectedText: selectedText,
            translationLanguage: "",
            recentDictationContext: current.recentDictationContext
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
            activeAppBundleID: current.activeAppBundleID,
            userIdentity: current.userIdentity,
            selectedText: "",
            translationLanguage: targetLanguage,
            recentDictationContext: current.recentDictationContext
        )
    }

    private static func translationMultiPromptConfiguration(targetLanguage: String) -> LocalLLMPromptConfiguration {
        let current = translationPromptConfiguration(targetLanguage: targetLanguage)
        let systemPrompt = """
        \(current.systemPromptTemplate)

        # 多路 ASR 合并
        - 本次输入包含多路 ASR 识别结果；请综合所有信号后再翻译
        - 各路内容可能有重叠、漏字、错词或标点差异；优先保留共同语义
        - 用其他结果补足明显漏识别或错识别的片段
        - 不要重复输出同一内容
        - 不要输出“识别结果”“Web”“Android”“Bage Shuo”“叭哥说”“Chatterfly”等输入标签
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
            activeAppBundleID: current.activeAppBundleID,
            userIdentity: current.userIdentity,
            selectedText: current.selectedText,
            translationLanguage: current.translationLanguage,
            recentDictationContext: current.recentDictationContext
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

    static func userFacingASRErrorMessage(_ error: TranscriptionSessionError?) -> String {
        guard let error else {
            return recognitionFailedMessage
        }
        let message = error.localizedDescription.lowercased()
        if error.domain == "Douvo.AndroidASR",
           AndroidASRErrorClassifier.isConcurrencyQuotaExceeded(
               statusCode: error.code,
               message: message
           ) {
            return androidConcurrencyQuotaFullMessage
        }
        if error.domain == "Douvo.WebASR",
           error.code == 710020702 || message.contains("server processing timeout") || message.contains("node execution timeout") {
            return speechRecognitionServiceTimeoutMessage
        }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut {
            return speechRecognitionStartTimeoutMessage
        }
        if isNetworkTransportError(error) {
            return L10n.text(en: "Network connection interrupted.", zh: "网络连接中断")
        }
        return recognitionFailureMessage(error)
    }

    private static func isNetworkTransportError(_ error: TranscriptionSessionError) -> Bool {
        if error.domain == NSURLErrorDomain { return true }
        guard error.domain == NSPOSIXErrorDomain else { return false }
        return [50, 51, 54, 57, 60, 61, 64, 65].contains(error.code)
    }

    private static func recognitionFailureMessage(_ error: TranscriptionSessionError) -> String {
        let detail = error.localizedDescription
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !detail.isEmpty, detail.lowercased() != "unknown" else {
            return recognitionFailedMessage
        }
        let visibleDetail = String(detail.prefix(180))
        switch error.domain {
        case "Douvo.AndroidASR":
            return L10n.text(
                en: "Android recognition failed: \(visibleDetail)",
                zh: "Android 识别失败：\(visibleDetail)"
            )
        case "Douvo.WebASR":
            return L10n.text(
                en: "Web recognition failed: \(visibleDetail)",
                zh: "Web 识别失败：\(visibleDetail)"
            )
        case "Douvo.BageshuoASR":
            return L10n.text(
                en: "Bage Shuo recognition failed: \(visibleDetail)",
                zh: "叭哥说识别失败：\(visibleDetail)"
            )
        default:
            return L10n.text(
                en: "Recognition failed: \(visibleDetail)",
                zh: "识别失败：\(visibleDetail)"
            )
        }
    }
}
