import AppKit
import AVFoundation
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appState = AppState.shared
    private var statusItem: NSStatusItem!
    private var webViewManager: WebViewManager!
    private var hotkeyManager: HotkeyManager!
    private var overlayPanel: OverlayPanel!
    private var transcriptionManager: TranscriptionManager!
    private var settingsPanel: ShortcutCapturePanel!
    private var localLLMDownloadManager: LocalLLMDownloadManager!
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
        setupTranscription()
        requestMicrophonePermission()
        rebuildMenu()
        prewarmSelectedLocalLLMModel(reason: "launch")
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

    private func loadStatusBarIcon() -> NSImage {
        let bundleURL = Bundle.main.bundleURL
        let resourceURL = Bundle.main.resourceURL
        let candidateURLs = [
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
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Douvo")!
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel(appState: appState)
    }

    private func setupWebView() {
        webViewManager = WebViewManager(appState: appState)
        if ASRParamsStore.load() != nil {
            appState.loginStatus = .loggedIn
        } else {
            appState.loginStatus = .notLoggedIn
        }
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
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
        localLLMDownloadManager = LocalLLMDownloadManager { model in
            try await LocalLLMPostProcessor.shared.downloadModel(model)
        }
        settingsPanel = ShortcutCapturePanel()
    }

    private func setupTranscription() {
        transcriptionManager = TranscriptionManager(
            appState: appState,
            webViewManager: webViewManager,
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

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        Self.rebuildStatusMenu(
            menu,
            provider: ASRProviderStore.selected,
            loginStatus: appState.loginStatus,
            lastTranscript: appState.lastTranscript,
            canCheckForUpdates: updaterController.updater.canCheckForUpdates,
            target: self
        )
    }

    static func rebuildStatusMenu(
        _ menu: NSMenu,
        provider: ASRProvider,
        loginStatus: LoginStatus,
        lastTranscript: String,
        canCheckForUpdates: Bool,
        target: AnyObject?
    ) {
        menu.removeAllItems()

        switch provider {
        case .web:
            switch loginStatus {
            case .checking:
                menu.addItem(disabledItem(L10n.text(en: "Checking login...", zh: "正在检查登录状态...")))
            case .loggedIn:
                menu.addItem(disabledItem(L10n.text(en: "Web ASR logged in", zh: "网页 ASR 已登录")))
            case .notLoggedIn:
                menu.addItem(menuItem(title: L10n.text(en: "Log In", zh: "登录"), action: #selector(showLogin), keyEquivalent: "l", target: target))
            }
        case .android:
            menu.addItem(disabledItem(L10n.text(en: "Android ASR ready", zh: "Android ASR 已就绪")))
        case .mix:
            switch loginStatus {
            case .checking:
                menu.addItem(disabledItem(L10n.text(en: "Checking login...", zh: "正在检查登录状态...")))
            case .loggedIn:
                menu.addItem(disabledItem(L10n.text(en: "Mix ASR ready", zh: "Mix ASR 已就绪")))
            case .notLoggedIn:
                menu.addItem(menuItem(title: L10n.text(en: "Log In", zh: "登录"), action: #selector(showLogin), keyEquivalent: "l", target: target))
            }
        }
        let copyItem = menuItem(title: L10n.text(en: "Copy Last Transcript", zh: "复制上一段转写"), action: #selector(copyLastTranscript), keyEquivalent: "c", target: target)
        copyItem.isEnabled = !lastTranscript.isEmpty
        menu.addItem(copyItem)
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

    @objc private func showLogin() {
        webViewManager.showLoginWindow()
    }

    @objc private func refreshLoginParams() {
        AppLog.info("Refresh login params requested")
        Task {
            if await webViewManager.extractAndSaveASRParams() {
                appState.loginStatus = .loggedIn
            } else {
                appState.loginStatus = .notLoggedIn
                webViewManager.showLoginWindow()
            }
            settingsPanel.refreshLoginStatus(appState.loginStatus)
            rebuildMenu()
        }
    }

    @objc private func copyLastTranscript() {
        AppLog.info("Copy last transcript requested chars=\(appState.lastTranscript.count)")
        PasteHelper.copyOnly(appState.lastTranscript)
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
            selectedASRProvider: ASRProviderStore.selected,
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
            onSelectASRProvider: { [weak self] provider in
                ASRProviderStore.selected = provider
                self?.settingsPanel.refreshLoginStatus(self?.appState.loginStatus ?? .notLoggedIn)
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
            onCopyLogPath: { [weak self] in
                self?.copyLogPath()
            },
            onOpenLog: { [weak self] in
                self?.openLog()
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
        webViewManager.logOut()
        settingsPanel.refreshLoginStatus(appState.loginStatus)
        rebuildMenu()
    }

    @objc private func copyLoginDebugInfo() {
        let debugInfo: String?
        switch ASRProviderStore.selected {
        case .web:
            debugInfo = ASRParamsStore.loginDebugInfo()
        case .android:
            debugInfo = DoubaoAndroidCredentialStore.debugInfo()
        case .mix:
            debugInfo = [
                ASRParamsStore.loginDebugInfo(),
                DoubaoAndroidCredentialStore.debugInfo()
            ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        }
        guard let debugInfo else { return }
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

    @objc private func checkForUpdates() {
        AppLog.info("Check for updates requested")
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleAuthExpired() {
        if ASRProviderStore.selected.usesWebASR {
            appState.loginStatus = .notLoggedIn
            webViewManager.showLoginWindow()
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
