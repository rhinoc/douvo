import AppKit
import AVFoundation
import Combine
import Dispatch
import Sparkle
import SwiftUI

@main
struct DouvoMain {
    static func main() {
        if let traceURL = TraceReplayCommand.traceURL(from: CommandLine.arguments) {
            runTraceReplayAndExit(traceURL: traceURL)
        }

        if let configURL = PromptLabCommand.configURL(from: CommandLine.arguments) {
            runPromptLabAndExit(configURL: configURL)
        }

        if CommandLine.arguments.contains("--asr-lab") {
            runASRLabAndExit(arguments: CommandLine.arguments)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func runPromptLabAndExit(configURL: URL) -> Never {
        Task {
            let exitCode = await PromptLabCommand.run(configURL: configURL)
            exit(exitCode)
        }

        dispatchMain()
    }

    private static func runTraceReplayAndExit(traceURL: URL) -> Never {
        Task {
            let exitCode = await TraceReplayCommand.run(traceURL: traceURL)
            exit(exitCode)
        }

        dispatchMain()
    }

    private static func runASRLabAndExit(arguments: [String]) -> Never {
        Task {
            let exitCode = await ASRLabCommand.run(arguments: arguments)
            exit(exitCode)
        }

        dispatchMain()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appState = AppState.shared
    private var statusItem: NSStatusItem!
    private var webViewManager: WebViewManager!
    private var bageshuoWebViewManager: BageshuoWebViewManager!
    private var chatterflyAuthWebViewManager: ChatterflyAuthWebViewManager!
    private var hotkeyManager: HotkeyManager!
    private var overlayPanel: OverlayPanel!
    private var transcriptionManager: TranscriptionManager!
    private var settingsPanel: ShortcutCapturePanel!
    private var localLLMDownloadManager: LocalLLMDownloadManager!
    private var loginStatusCancellable: AnyCancellable?
    private var bageshuoVocabularySyncTask: Task<Void, Never>?
    private var bageshuoVocabularySyncPending = false
    private let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("App launched bundle=\(Bundle.main.bundlePath) log=\(AppLog.fileURL.path)")
        setupMainMenu()
        setupStatusItem()
        setupOverlay()
        setupWebView()
        setupHotkey()
        observeLoginStatus()
        setupTranscription()
        requestMicrophonePermission()
        rebuildMenu()
        scheduleStatusItemVisibilityCheck()
        prewarmSelectedLocalLLMModel(reason: "launch")
        if ASRProviderStore.selected.usesBageshuoASR {
            synchronizeBageshuoVocabularyIfSelected(reason: "launch")
        }
    }

    private func setupMainMenu() {
        NSApp.mainMenu = AppMenuFactory.makeMainMenu(
            settingsAction: #selector(showSettings),
            quitAction: #selector(quit),
            target: self
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = loadStatusBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func scheduleStatusItemVisibilityCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkStatusItemVisibilityAfterLaunch()
        }
    }

    private func checkStatusItemVisibilityAfterLaunch() {
        guard let button = statusItem?.button,
              let itemFrame = StatusItemVisibilityDetector.frameInScreenCoordinates(for: button),
              let screen = button.window?.screen ?? NSScreen.screens.first else {
            AppLog.info("Status item visibility check skipped reason=layout_unavailable")
            return
        }

        let isLikelyObscured = StatusItemVisibilityDetector.isLikelyObscured(
            itemFrame: itemFrame,
            screenFrame: screen.frame,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
        AppLog.info(
            "Status item visibility checked likelyObscured=\(isLikelyObscured) hasCameraHousing=\(screen.auxiliaryTopRightArea != nil)"
        )
        guard isLikelyObscured else { return }
        guard StatusItemVisibilityAlertStore.shouldShowAlert() else {
            AppLog.info("Status item visibility alert skipped reason=user_suppressed")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = loadApplicationIcon()
        alert.messageText = StatusItemVisibilityAlertContent.title()
        let shortcutNames = StatusItemVisibilityAlertContent.speakingShortcuts(
            toggleShortcut: hotkeyManager.toggleShortcut,
            holdShortcut: hotkeyManager.holdShortcut
        ).map(\.localizedDisplayName)
        alert.informativeText = StatusItemVisibilityAlertContent.informativeText(
            shortcutNames: shortcutNames
        )
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.text(en: "Don't show again", zh: "以后不再提示")
        alert.addButton(withTitle: L10n.text(en: "OK", zh: "知道了"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if alert.suppressionButton?.state == .on {
            StatusItemVisibilityAlertStore.suppressAlert()
            AppLog.info("Status item visibility alert suppressed by user")
        }
    }

    private func loadApplicationIcon() -> NSImage {
        let candidateURLs = [
            Bundle.main.url(forResource: "Douvo", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("assets/Douvo.icns")
        ]
        for case let url? in candidateURLs {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return NSApp.applicationIconImage
    }

    private func loadStatusBarIcon() -> NSImage {
        let bundleURL = Bundle.main.bundleURL
        let resourceURL = Bundle.main.resourceURL
        let candidateURLs = [
            resourceURL?.appendingPathComponent("MenuBarIcon.pdf"),
            resourceURL?.appendingPathComponent("Douvo_Douvo.bundle/MenuBarIcon.pdf"),
            bundleURL.deletingLastPathComponent().appendingPathComponent("Douvo_Douvo.bundle/MenuBarIcon.pdf"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Douvo/Resources/MenuBarIcon.pdf"),
            resourceURL?.appendingPathComponent("MenuBarIcon.svg"),
            resourceURL?.appendingPathComponent("Douvo_Douvo.bundle/MenuBarIcon.svg"),
            bundleURL.deletingLastPathComponent().appendingPathComponent("Douvo_Douvo.bundle/MenuBarIcon.svg"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Douvo/Resources/MenuBarIcon.svg")
        ].compactMap { $0 }

        for url in candidateURLs {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Douvo") {
            image.isTemplate = true
            return image
        }
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel(appState: appState)
    }

    private func setupWebView() {
        webViewManager = WebViewManager(appState: appState)
        bageshuoWebViewManager = BageshuoWebViewManager(appState: appState)
        chatterflyAuthWebViewManager = ChatterflyAuthWebViewManager()
        refreshSelectedProviderLoginStatus()
    }

    private func refreshSelectedProviderLoginStatus() {
        let selection = ASRProviderStore.selected
        let statuses = loginStatuses(for: selection)
        let requiredProviders = selection.sortedProviders.filter(\.requiresLogin)
        let aggregateStatus: LoginStatus = requiredProviders.isEmpty || requiredProviders.allSatisfy {
            statuses[$0] == .loggedIn
        } ? .loggedIn : .notLoggedIn
        if appState.loginStatus != aggregateStatus {
            appState.loginStatus = aggregateStatus
        }
        settingsPanel?.refreshLoginStatus(aggregateStatus, providerStatuses: statuses)
    }

    private func loginStatuses(for _: ASRProviderSelection) -> [ASRProvider: LoginStatus] {
        return ASRProvider.allCases.reduce(into: [ASRProvider: LoginStatus]()) { statuses, provider in
            switch provider {
            case .web:
                statuses[provider] = ASRParamsStore.load() != nil ? .loggedIn : .notLoggedIn
            case .android:
                statuses[provider] = .loggedIn
            case .bageshuo:
                statuses[provider] = BageshuoASRParamsStore.load() != nil ? .loggedIn : .notLoggedIn
            case .chatterfly:
                statuses[provider] = ChatterflyAuthTokenStore.hasUsableCredentials ? .loggedIn : .notLoggedIn
            }
        }
    }

    private func missingLoginProvider(in selection: ASRProviderSelection) -> ASRProvider? {
        selection.sortedProviders.first { provider in
            provider.requiresLogin && loginStatuses(for: selection)[provider] != .loggedIn
        }
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
        chatterflyAuthWebViewManager.onLoginWindowVisibilityChanged = { [weak self] isVisible in
            self?.hotkeyManager.setEventTapEnabled(!isVisible)
            if !isVisible {
                self?.refreshSelectedProviderLoginStatus()
                self?.rebuildMenu()
            }
        }
        hotkeyManager.onShortcutChanged = { [weak self] in
            self?.rebuildMenu()
        }
        hotkeyManager.onAvailabilityChanged = { [weak self] _, _ in
            self?.settingsPanel.refreshKeyboardCaptureState(
                isActive: self?.hotkeyManager.isEventTapActive ?? false,
                error: self?.hotkeyManager.lastEventTapError
            )
            self?.rebuildMenu()
        }
        localLLMDownloadManager = LocalLLMDownloadManager { model, onProgress in
            try await LocalLLMPostProcessor.shared.downloadModel(model) { progress in
                Task { @MainActor in
                    onProgress(progress)
                }
            }
        }
        settingsPanel = ShortcutCapturePanel()
    }

    private func observeLoginStatus() {
        loginStatusCancellable = Self.observeLoginStatus(appState) { [weak self] _ in
            guard self != nil else { return }
            // Individual login managers publish a success for their own route.
            // Recompute the aggregate so a multi-route selection cannot look ready
            // while another login-based route is still missing.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.refreshSelectedProviderLoginStatus()
                self.synchronizeBageshuoVocabularyIfSelected(reason: "login-status")
                self.rebuildMenu()
            }
        }
    }

    static func observeLoginStatus(
        _ appState: AppState,
        onChange: @escaping (LoginStatus) -> Void
    ) -> AnyCancellable {
        appState.$loginStatus.sink(receiveValue: onChange)
    }

    private func setupTranscription() {
        transcriptionManager = TranscriptionManager(
            appState: appState,
            webViewManager: webViewManager,
            bageshuoWebViewManager: bageshuoWebViewManager,
            overlayPanel: overlayPanel,
            hotkeyManager: hotkeyManager
        )
        transcriptionManager.onStateChanged = { [weak self] in
            self?.rebuildMenu()
        }
        transcriptionManager.onAuthExpired = { [weak self] in
            self?.handleAuthExpired()
        }
        transcriptionManager.start()
    }

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AppLog.info("Microphone permission not determined; requesting")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                AppLog.info("Microphone permission request result granted=\(granted)")
            }
        case .authorized:
            AppLog.info("Microphone permission authorized")
        case .denied:
            AppLog.error("Microphone permission denied")
        case .restricted:
            AppLog.error("Microphone permission restricted")
        default:
            break
        }
    }

    private func prewarmSelectedLocalLLMModel(reason: String) {
        guard CorrectionSettingsStore.backend == .local else {
            AppLog.info("Local LLM prewarm skipped reason=\(reason) backend=\(CorrectionSettingsStore.backend.rawValue)")
            return
        }
        guard LocalLLMPostProcessor.isCorrectionEnabled else {
            AppLog.info("Local LLM prewarm skipped reason=\(reason) correction_disabled=true")
            return
        }

        let model = LocalLLMPostProcessor.configuredModel
        guard model.isDownloaded else {
            AppLog.info("Local LLM prewarm skipped reason=\(reason) model=\(model.repositoryID) downloaded=false")
            return
        }

        Task {
            let startedAt = ProcessInfo.processInfo.systemUptime
            AppLog.info("Local LLM prewarm start reason=\(reason) model=\(model.repositoryID)")
            do {
                try await LocalLLMPostProcessor.shared.preload(model)
                AppLog.info("Local LLM prewarm complete reason=\(reason) model=\(model.repositoryID) ms=\(Self.milliseconds(since: startedAt))")
            } catch {
                AppLog.error("Local LLM prewarm failed reason=\(reason) model=\(model.repositoryID) error=\(error.localizedDescription)")
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        hotkeyManager?.setShortcutHandlingSuspended(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        hotkeyManager?.setShortcutHandlingSuspended(false)
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        Self.rebuildStatusMenu(
            menu,
            selection: ASRProviderStore.selected,
            loginStatus: appState.loginStatus,
            transcriptHistory: appState.transcriptHistory,
            canCheckForUpdates: updaterController.updater.canCheckForUpdates,
            target: self
        )
    }

    static func rebuildStatusMenu(
        _ menu: NSMenu,
        selection: ASRProviderSelection,
        loginStatus: LoginStatus,
        transcriptHistory: [String],
        canCheckForUpdates: Bool,
        target: AnyObject?
    ) {
        menu.removeAllItems()

        if loginStatus == .checking {
            menu.addItem(disabledItem(L10n.text(en: "Checking login...", zh: "正在检查登录状态...")))
        } else if selection.requiresLogin && loginStatus != .loggedIn {
            menu.addItem(menuItem(title: L10n.text(en: "Log In", zh: "登录"), action: #selector(showLogin), keyEquivalent: "l", target: target))
        } else {
            menu.addItem(disabledItem(
                L10n.text(
                    en: "Recognition: \(selection.displayName)",
                    zh: "识别方式：\(selection.displayName)"
                )
            ))
        }
        menu.addItem(transcriptHistoryItem(transcriptHistory, target: target))
        menu.addItem(menuItem(title: L10n.text(en: "Settings", zh: "设置"), action: #selector(showSettings), keyEquivalent: ",", target: target))
        let updateItem = menuItem(title: L10n.text(en: "Check for Updates…", zh: "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "", target: target)
        updateItem.isEnabled = canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(menuItem(title: L10n.text(en: "Quit", zh: "退出"), action: #selector(quit), keyEquivalent: "q", target: target))
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func menuItem(title: String, action: Selector, keyEquivalent: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        return item
    }

    private static func transcriptHistoryItem(_ history: [String], target: AnyObject?) -> NSMenuItem {
        let parent = NSMenuItem(
            title: L10n.text(en: "Copy Transcript", zh: "复制转写记录"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: parent.title)
        let recentEntries = history.suffix(TranscriptHistoryStore.maxCount).reversed()

        if recentEntries.isEmpty {
            parent.isEnabled = false
        } else {
            for (index, transcript) in recentEntries.enumerated() {
                let item = menuItem(
                    title: transcriptHistoryTitle(transcript),
                    action: #selector(copyTranscriptFromHistory(_:)),
                    keyEquivalent: index == 0 ? "c" : "",
                    target: target
                )
                item.representedObject = transcript
                item.toolTip = transcript
                submenu.addItem(item)
            }
        }

        if !recentEntries.isEmpty {
            parent.submenu = submenu
        }
        return parent
    }

    private static func transcriptHistoryTitle(_ transcript: String) -> String {
        let singleLine = transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let maxCharacters = 42
        let preview = singleLine.count > maxCharacters
            ? String(singleLine.prefix(maxCharacters)) + "…"
            : singleLine
        return preview
    }

    @objc private func showLogin() {
        let selection = ASRProviderStore.selected
        guard let provider = missingLoginProvider(in: selection)
                ?? selection.sortedProviders.first(where: \.requiresLogin) else {
            return
        }
        openLogin(for: provider)
    }

    @objc private func showChatterflyLogin() {
        chatterflyAuthWebViewManager.showLoginWindow()
    }

    private func synchronizeBageshuoVocabularyIfSelected(reason: String) {
        guard ASRProviderStore.selected.usesBageshuoASR else { return }

        if bageshuoVocabularySyncTask != nil {
            bageshuoVocabularySyncPending = true
            return
        }

        AppLog.info("Bage Shuo vocabulary auto-sync requested reason=\(reason)")
        bageshuoVocabularySyncPending = false
        bageshuoVocabularySyncTask = Task { [weak self] in
            let result = await BageshuoVocabularySynchronizer.shared.synchronizeBidirectionally()
            guard let self else { return }
            self.settingsPanel.refreshBageshuoVocabularyWordCount(result.wordCount)
            switch result.status {
            case .synced:
                AppLog.info(
                    "Bage Shuo vocabulary auto-sync complete count=\(result.wordCount) pushed=\(result.pushedWordCount)"
                )
            case .failed:
                AppLog.info(
                    "Bage Shuo vocabulary auto-sync failed error=\(result.errorDescription ?? "unknown") pushed=\(result.pushedWordCount)"
                )
            }

            let shouldRetry = self.bageshuoVocabularySyncPending
            self.bageshuoVocabularySyncPending = false
            self.bageshuoVocabularySyncTask = nil
            if shouldRetry {
                self.synchronizeBageshuoVocabularyIfSelected(reason: "coalesced-change")
            }
        }
    }

    private func openLogin(for provider: ASRProvider) {
        switch provider {
        case .web:
            webViewManager.showLoginWindow()
        case .bageshuo:
            bageshuoWebViewManager.showLoginWindow()
        case .android:
            break
        case .chatterfly:
            showChatterflyLogin()
        }
    }

    @objc private func refreshLoginParams() {
        AppLog.info("Refresh login params requested")
        let selection = ASRProviderStore.selected
        guard let provider = missingLoginProvider(in: selection)
                ?? selection.sortedProviders.first(where: \.requiresLogin) else {
            return
        }
        refreshLoginParams(for: provider)
    }

    private func refreshLoginParams(for provider: ASRProvider) {
        AppLog.info("Refresh login params requested provider=\(provider.rawValue)")
        Task {
            let didSave: Bool
            switch provider {
            case .bageshuo:
                didSave = await bageshuoWebViewManager.extractAndSaveASRParams()
            case .web:
                didSave = await webViewManager.extractAndSaveASRParams()
            case .android:
                didSave = false
            case .chatterfly:
                didSave = false
            }
            if !didSave {
                openLogin(for: provider)
            }
            refreshSelectedProviderLoginStatus()
            rebuildMenu()
        }
    }

    @objc private func copyTranscriptFromHistory(_ sender: NSMenuItem) {
        guard let transcript = sender.representedObject as? String else { return }
        AppLog.info("Copy transcript history requested chars=\(transcript.count)")
        PasteHelper.copyOnly(transcript)
    }

    @objc private func requestAccessibility() {
        AppLog.info("Accessibility permission requested from menu")
        HotkeyManager.requestAccessibilityPermission()
        hotkeyManager.start()
        settingsPanel.refreshKeyboardCaptureState(
            isActive: hotkeyManager.isEventTapActive,
            error: hotkeyManager.lastEventTapError
        )
        rebuildMenu()
    }

    @objc private func showSettings() {
        let microphoneDevices = AudioDeviceManager.inputDevices()
        let storedUID = AudioDeviceStore.selectedUID()
        // If the stored device was unplugged, fall back to system default in the UI.
        let selectedUID = microphoneDevices.contains { $0.uid == storedUID } ? storedUID : nil

        settingsPanel.show(
            currentToggleShortcut: hotkeyManager.toggleShortcut,
            currentHoldShortcut: hotkeyManager.holdShortcut,
            currentTranslationShortcut: hotkeyManager.translationShortcut,
            loginStatus: appState.loginStatus,
            isKeyboardCaptureActive: hotkeyManager.isEventTapActive,
            keyboardCaptureError: hotkeyManager.lastEventTapError,
            appVersion: appVersion,
            microphoneDevices: microphoneDevices,
            selectedMicrophoneUID: selectedUID,
            selectedASRProviders: ASRProviderStore.selected,
            providerLoginStatuses: loginStatuses(for: ASRProviderStore.selected),
            onCapture: { [weak self] slot, shortcut in
                guard let self else { return false }
                let accepted: Bool
                switch slot {
                case .toggle:
                    accepted = self.hotkeyManager.setToggleShortcut(shortcut)
                case .hold:
                    accepted = self.hotkeyManager.setHoldShortcut(shortcut)
                case .translation:
                    accepted = self.hotkeyManager.setTranslationShortcut(shortcut)
                }

                if accepted {
                    self.settingsPanel.complete(with: shortcut, for: slot)
                    self.rebuildMenu()
                } else {
                    self.settingsPanel.showShortcutConflict(for: slot)
                }
                return accepted
            },
            onCaptureStateChanged: { [weak self] isCapturing in
                self?.hotkeyManager.setShortcutHandlingSuspended(isCapturing)
            },
            onResetToggle: { [weak self] in
                self?.resetToggleTriggerKey()
            },
            onClearToggle: { [weak self] in
                self?.clearToggleTriggerKey()
            },
            onResetHold: { [weak self] in
                self?.resetHoldTriggerKey()
            },
            onClearHold: { [weak self] in
                self?.clearHoldTriggerKey()
            },
            onResetTranslation: { [weak self] in
                self?.clearTranslationTriggerKey()
            },
            onClearTranslation: { [weak self] in
                self?.clearTranslationTriggerKey()
            },
            onSelectMicrophone: { uid in
                AudioDeviceStore.setSelectedUID(uid)
            },
            onSelectASRProviders: { [weak self] selection in
                ASRProviderStore.selected = selection
                self?.refreshSelectedProviderLoginStatus()
                self?.synchronizeBageshuoVocabularyIfSelected(reason: "provider-selection")
                self?.rebuildMenu()
            },
            onSelectLanguage: { [weak self] language in
                AppLanguageStore.selected = language
                self?.settingsPanel.refreshLanguage(language)
                self?.rebuildMenu()
            },
            onDeleteLocalLLMModel: { [weak self] model in
                guard let self else { return }
                self.localLLMDownloadManager.cancelDownload(model)
                AppLog.info("Local LLM delete callback entered model=\(model.repositoryID)")
                try await LocalLLMPostProcessor.shared.deleteDownloadedModel(model)
                AppLog.info("Local LLM delete callback returned model=\(model.repositoryID)")
            },
            onLogin: { [weak self] in
                self?.showLogin()
            },
            onLogout: { [weak self] in
                self?.logOut()
            },
            onCopyLoginDebugInfo: { [weak self] in
                self?.copyLoginDebugInfo()
            },
            onRepairLogin: { [weak self] in
                self?.refreshLoginParams()
            },
            onBageshuoVocabularyChanged: { [weak self] in
                self?.synchronizeBageshuoVocabularyIfSelected(reason: "local-vocabulary-changed")
            },
            onCopyLogPath: { [weak self] in
                self?.copyLogPath()
            },
            onOpenLog: { [weak self] in
                self?.openLog()
            },
            onExportLogs: { [weak self] in
                self?.exportLogs()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates()
            },
            canCheckForUpdates: updaterController.updater.canCheckForUpdates,
            onRequestAccessibility: { [weak self] in
                self?.requestAccessibility()
            },
            localLLMDownloadManager: localLLMDownloadManager,
            onCancel: {}
        )
    }

    @objc private func resetToggleTriggerKey() {
        AppLog.info("Toggle trigger reset requested")
        if hotkeyManager.resetShortcutToDefault() {
            settingsPanel.refreshShortcuts(
                toggleShortcut: hotkeyManager.toggleShortcut,
                holdShortcut: hotkeyManager.holdShortcut,
                translationShortcut: hotkeyManager.translationShortcut
            )
        } else {
            settingsPanel.showShortcutConflict(for: .toggle)
        }
        rebuildMenu()
    }

    private func clearHoldTriggerKey() {
        AppLog.info("Hold trigger clear requested")
        hotkeyManager.clearHoldShortcut()
        settingsPanel.refreshShortcuts(
            toggleShortcut: hotkeyManager.toggleShortcut,
            holdShortcut: hotkeyManager.holdShortcut,
            translationShortcut: hotkeyManager.translationShortcut
        )
        rebuildMenu()
    }

    private func clearToggleTriggerKey() {
        AppLog.info("Toggle trigger clear requested")
        hotkeyManager.clearToggleShortcut()
        settingsPanel.refreshShortcuts(
            toggleShortcut: hotkeyManager.toggleShortcut,
            holdShortcut: hotkeyManager.holdShortcut,
            translationShortcut: hotkeyManager.translationShortcut
        )
        rebuildMenu()
    }

    private func resetHoldTriggerKey() {
        AppLog.info("Hold trigger reset requested")
        if hotkeyManager.resetHoldShortcutToDefault() {
            settingsPanel.refreshShortcuts(
                toggleShortcut: hotkeyManager.toggleShortcut,
                holdShortcut: hotkeyManager.holdShortcut,
                translationShortcut: hotkeyManager.translationShortcut
            )
        } else {
            settingsPanel.showShortcutConflict(for: .hold)
        }
        rebuildMenu()
    }

    private func clearTranslationTriggerKey() {
        AppLog.info("Translation trigger clear requested")
        hotkeyManager.clearTranslationShortcut()
        settingsPanel.refreshShortcuts(
            toggleShortcut: hotkeyManager.toggleShortcut,
            holdShortcut: hotkeyManager.holdShortcut,
            translationShortcut: hotkeyManager.translationShortcut
        )
        rebuildMenu()
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion ?? "Development"
    }

    @objc private func logOut() {
        for provider in ASRProviderStore.selected.sortedProviders {
            logOut(provider: provider)
        }
        refreshSelectedProviderLoginStatus()
        rebuildMenu()
    }

    private func logOut(provider: ASRProvider) {
        switch provider {
        case .bageshuo:
            bageshuoWebViewManager.logOut()
        case .web:
            webViewManager.logOut()
        case .android:
            break
        case .chatterfly:
            chatterflyAuthWebViewManager.logOut()
        }
    }

    @objc private func copyLoginDebugInfo() {
        let debugInfo = ASRProviderStore.selected.sortedProviders.compactMap { provider in
            switch provider {
            case .web:
                ASRParamsStore.loginDebugInfo()
            case .android:
                DoubaoAndroidCredentialStore.debugInfo()
            case .bageshuo:
                BageshuoASRParamsStore.loginDebugInfo()
            case .chatterfly:
                ChatterflyAuthTokenStore.debugInfo()
            }
        }.joined(separator: "\n\n")
        guard !debugInfo.isEmpty else { return }
        PasteHelper.copyOnly(debugInfo)
    }

    @objc private func copyLogPath() {
        AppLog.info("Copy log path requested")
        PasteHelper.copyOnly(AppLog.fileURL.path)
    }

    @objc private func openLog() {
        AppLog.info("Open log requested")
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
    }

    private func exportLogs() {
        AppLog.info("Export logs requested")
        Task {
            do {
                let zipURL = try LogExportStore.export()
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([zipURL])
                }
            } catch {
                AppLog.error("Export logs failed error=\(error.localizedDescription)")
            }
        }
    }

    @objc private func checkForUpdates() {
        AppLog.info("Check for updates requested")
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleAuthExpired() {
        let selection = ASRProviderStore.selected
        if let provider = missingLoginProvider(in: selection) {
            appState.loginStatus = .notLoggedIn
            openLogin(for: provider)
        }
        rebuildMenu()
    }
}

enum AppMenuFactory {
    @MainActor
    static func makeMainMenu(
        settingsAction: Selector?,
        quitAction: Selector,
        target: AnyObject? = nil
    ) -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: ProcessInfo.processInfo.processName)
        if let settingsAction {
            let settingsItem = NSMenuItem(
                title: L10n.text(en: "Settings", zh: "设置"),
                action: settingsAction,
                keyEquivalent: ","
            )
            settingsItem.target = target
            appMenu.addItem(settingsItem)
            appMenu.addItem(.separator())
        }

        let hideItem = NSMenuItem(
            title: L10n.text(en: "Hide Douvo", zh: "隐藏 Douvo"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: L10n.text(en: "Hide Others", zh: "隐藏其他"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: L10n.text(en: "Show All", zh: "全部显示"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text(en: "Quit", zh: "退出"),
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.target = target
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(editMenuItem())
        return mainMenu
    }

    @MainActor
    private static func editMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text(en: "Edit", zh: "编辑"))

        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Undo", zh: "撤销"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Redo", zh: "重做"),
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Cut", zh: "剪切"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Copy", zh: "复制"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Paste", zh: "粘贴"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: L10n.text(en: "Select All", zh: "全选"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenuItem.submenu = editMenu
        return editMenuItem
    }
}
