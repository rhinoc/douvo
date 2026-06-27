import AppKit
import AVFoundation
import Dispatch
import Sparkle
import SwiftUI

@main
struct DouvoMain {
    static func main() {
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
        setupStatusItem()
        setupOverlay()
        setupWebView()
        setupHotkey()
        setupTranscription()
        requestMicrophonePermission()
        rebuildMenu()
        prewarmSelectedLocalLLMModel(reason: "launch")
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
        menu.removeAllItems()

        switch appState.loginStatus {
        case .checking:
            menu.addItem(disabledItem("Checking login..."))
        case .loggedIn:
            menu.addItem(disabledItem("Logged in"))
        case .notLoggedIn:
            menu.addItem(NSMenuItem(title: "Log In", action: #selector(showLogin), keyEquivalent: "l"))
        }
        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "c")
        copyItem.isEnabled = !appState.lastTranscript.isEmpty
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
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
            loginStatus: appState.loginStatus,
            isKeyboardCaptureActive: hotkeyManager.isEventTapActive,
            keyboardCaptureError: hotkeyManager.lastEventTapError,
            appVersion: appVersion,
            microphoneDevices: microphoneDevices,
            selectedMicrophoneUID: selectedUID,
            onCapture: { [weak self] slot, shortcut in
                guard let self else { return false }
                let accepted: Bool
                switch slot {
                case .toggle:
                    accepted = self.hotkeyManager.setToggleShortcut(shortcut)
                case .hold:
                    accepted = self.hotkeyManager.setHoldShortcut(shortcut)
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
            onSelectMicrophone: { uid in
                AudioDeviceStore.setSelectedUID(uid)
            },
            onDownloadLocalLLMModel: { model, onProgress in
                try await LocalLLMPostProcessor.shared.preload(model, onProgress: onProgress)
            },
            onDeleteLocalLLMModel: { model in
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
            onCancel: {}
        )
    }

    @objc private func resetToggleTriggerKey() {
        AppLog.info("Toggle trigger reset requested")
        if hotkeyManager.resetShortcutToDefault() {
            settingsPanel.refreshShortcuts(
                toggleShortcut: hotkeyManager.toggleShortcut,
                holdShortcut: hotkeyManager.holdShortcut
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
            holdShortcut: hotkeyManager.holdShortcut
        )
        rebuildMenu()
    }

    private func clearToggleTriggerKey() {
        AppLog.info("Toggle trigger clear requested")
        hotkeyManager.clearToggleShortcut()
        settingsPanel.refreshShortcuts(
            toggleShortcut: hotkeyManager.toggleShortcut,
            holdShortcut: hotkeyManager.holdShortcut
        )
        rebuildMenu()
    }

    private func resetHoldTriggerKey() {
        AppLog.info("Hold trigger reset requested")
        if hotkeyManager.resetHoldShortcutToDefault() {
            settingsPanel.refreshShortcuts(
                toggleShortcut: hotkeyManager.toggleShortcut,
                holdShortcut: hotkeyManager.holdShortcut
            )
        } else {
            settingsPanel.showShortcutConflict(for: .hold)
        }
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
        guard let debugInfo = ASRParamsStore.loginDebugInfo() else { return }
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
        updaterController.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleAuthExpired() {
        appState.loginStatus = .notLoggedIn
        rebuildMenu()
        webViewManager.showLoginWindow()
    }
}
