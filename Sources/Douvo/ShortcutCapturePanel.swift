import AppKit
import SwiftUI

@MainActor
final class ShortcutCapturePanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var model: SettingsPanelModel?
    private var onCapture: ((HotkeyShortcutSlot, HotkeyShortcut) -> Bool)?
    private var onCaptureStateChanged: ((Bool) -> Void)?
    private var onCancel: (() -> Void)?
    private var isClosingFromCode = false

    func show(
        currentToggleShortcut: HotkeyShortcut?,
        currentHoldShortcut: HotkeyShortcut?,
        currentTranslationShortcut: HotkeyShortcut?,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?,
        selectedASRProvider: ASRProvider,
        onCapture: @escaping (HotkeyShortcutSlot, HotkeyShortcut) -> Bool,
        onCaptureStateChanged: @escaping (Bool) -> Void,
        onResetToggle: @escaping () -> Void,
        onClearToggle: @escaping () -> Void,
        onResetHold: @escaping () -> Void,
        onClearHold: @escaping () -> Void,
        onResetTranslation: @escaping () -> Void,
        onClearTranslation: @escaping () -> Void,
        onSelectMicrophone: @escaping (String?) -> Void,
        onSelectASRProvider: @escaping (ASRProvider) -> Void,
        onSelectLanguage: @escaping (AppLanguage) -> Void,
        onDownloadLocalLLMModel: @escaping (LocalLLMModel, @escaping @Sendable (Double) -> Void) async throws -> Void,
        onDeleteLocalLLMModel: @escaping (LocalLLMModel) async throws -> Void,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void,
        onCopyLoginDebugInfo: @escaping () -> Void,
        onRepairLogin: @escaping () -> Void,
        onCopyLogPath: @escaping () -> Void,
        onOpenLog: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        canCheckForUpdates: Bool,
        onRequestAccessibility: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onCaptureStateChanged = onCaptureStateChanged
        self.onCancel = onCancel

        let model = SettingsPanelModel(
            toggleShortcut: currentToggleShortcut,
            holdShortcut: currentHoldShortcut,
            translationShortcut: currentTranslationShortcut,
            toggleShortcutName: Self.shortcutName(currentToggleShortcut),
            holdShortcutName: Self.holdShortcutName(currentHoldShortcut),
            translationShortcutName: Self.shortcutName(currentTranslationShortcut),
            loginStatus: loginStatus,
            isKeyboardCaptureActive: isKeyboardCaptureActive,
            keyboardCaptureError: keyboardCaptureError,
            appVersion: appVersion,
            microphoneDevices: microphoneDevices,
            selectedMicrophoneUID: selectedMicrophoneUID,
            selectedASRProvider: selectedASRProvider,
            selectedLanguage: AppLanguageStore.selected
        )
        model.canCheckForUpdates = canCheckForUpdates
        self.model = model

        let view = SettingsPanelView(
            model: model,
            onBeginCapture: { [weak self] in
                self?.startLocalMonitor()
            },
            onEndCapture: { [weak self] in
                self?.stopLocalMonitor()
                self?.clearFocus()
            },
            onResetToggle: onResetToggle,
            onClearToggle: onClearToggle,
            onResetHold: onResetHold,
            onClearHold: onClearHold,
            onResetTranslation: onResetTranslation,
            onClearTranslation: onClearTranslation,
            onSelectMicrophone: onSelectMicrophone,
            onSelectASRProvider: onSelectASRProvider,
            onSelectLanguage: onSelectLanguage,
            onDownloadLocalLLMModel: onDownloadLocalLLMModel,
            onDeleteLocalLLMModel: onDeleteLocalLLMModel,
            onLogin: onLogin,
            onLogout: onLogout,
            onCopyLoginDebugInfo: onCopyLoginDebugInfo,
            onRepairLogin: onRepairLogin,
            onCopyLogPath: onCopyLogPath,
            onOpenLog: onOpenLog,
            onCheckForUpdates: onCheckForUpdates,
            onRequestAccessibility: onRequestAccessibility
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: SettingsPanelView.panelWidth, height: SettingsPanelView.panelHeight)

        if panel == nil {
            let panel = SettingsPanelWindow(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.text(en: "Settings", zh: "设置")
            panel.backgroundColor = NSColor.windowBackgroundColor
            panel.isOpaque = true
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            // Keep the settings window open when the app loses focus (NSPanel hides by default).
            panel.hidesOnDeactivate = false
            panel.delegate = self
            self.panel = panel
        }

        panel?.contentView = hosting
        panel?.title = L10n.text(en: "Settings", zh: "设置")
        panel?.setContentSize(hosting.frame.size)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.initialFirstResponder = nil
        _ = panel?.makeFirstResponder(nil)
    }

    func complete(with shortcut: HotkeyShortcut, for slot: HotkeyShortcutSlot) {
        switch slot {
        case .toggle:
            model?.toggleShortcut = shortcut
            model?.toggleShortcutName = shortcut.settingsDisplayName
        case .hold:
            model?.holdShortcut = shortcut
            model?.holdShortcutName = shortcut.settingsDisplayName
        case .translation:
            model?.translationShortcut = shortcut
            model?.translationShortcutName = shortcut.settingsDisplayName
        }
        model?.capturingShortcut = nil
        model?.shortcutErrorMessage = nil
        clearFocus()
    }

    func showShortcutConflict(for slot: HotkeyShortcutSlot) {
        model?.capturingShortcut = nil
        switch slot {
        case .toggle:
            model?.shortcutErrorMessage = L10n.text(en: "Short press, hold-to-talk, and translation must use different keys.", zh: "短按、按住说话和翻译必须使用不同按键。")
        case .hold:
            model?.shortcutErrorMessage = L10n.text(en: "Hold-to-talk, short press, and translation must use different keys.", zh: "按住说话、短按和翻译必须使用不同按键。")
        case .translation:
            model?.shortcutErrorMessage = L10n.text(en: "Translation and recording shortcuts must use different keys.", zh: "翻译和录音快捷键必须使用不同按键。")
        }
        clearFocus()
    }

    func refreshShortcuts(
        toggleShortcut: HotkeyShortcut?,
        holdShortcut: HotkeyShortcut?,
        translationShortcut: HotkeyShortcut?
    ) {
        model?.toggleShortcut = toggleShortcut
        model?.holdShortcut = holdShortcut
        model?.translationShortcut = translationShortcut
        model?.toggleShortcutName = Self.shortcutName(toggleShortcut)
        model?.holdShortcutName = Self.holdShortcutName(holdShortcut)
        model?.translationShortcutName = Self.shortcutName(translationShortcut)
        model?.capturingShortcut = nil
        model?.shortcutErrorMessage = nil
    }

    func refreshLoginStatus(_ loginStatus: LoginStatus) {
        model?.loginStatus = loginStatus
    }

    func refreshKeyboardCaptureState(isActive: Bool, error: String?) {
        model?.isKeyboardCaptureActive = isActive
        model?.keyboardCaptureError = error
    }

    func refreshLanguage(_ language: AppLanguage) {
        guard let model else { return }
        model.selectedLanguage = language
        model.toggleShortcutName = Self.shortcutName(model.toggleShortcut)
        model.holdShortcutName = Self.holdShortcutName(model.holdShortcut)
        model.translationShortcutName = Self.shortcutName(model.translationShortcut)
        model.refreshMLXRuntimeDiagnostic()
        panel?.title = L10n.text(en: "Settings", zh: "设置")
    }

    func windowWillClose(_ notification: Notification) {
        if !isClosingFromCode {
            cancel()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard model?.capturingShortcut != nil else { return }
        model?.capturingShortcut = nil
        stopLocalMonitor()
        clearFocus()
    }

    private func startLocalMonitor() {
        stopLocalMonitor()
        onCaptureStateChanged?(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in
                    self.model?.capturingShortcut = nil
                    self.stopLocalMonitor()
                    self.clearFocus()
                }
                return nil
            }

            guard let shortcut = HotkeyShortcut.from(event: event) else {
                return nil
            }

            Task { @MainActor in
                guard let slot = self.model?.capturingShortcut else { return }
                self.stopLocalMonitor()
                _ = self.onCapture?(slot, shortcut)
            }
            return nil
        }
    }

    private func stopLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
            onCaptureStateChanged?(false)
        }
    }

    private func clearFocus() {
        panel?.makeFirstResponder(nil)
    }

    private func cancel() {
        stopLocalMonitor()
        isClosingFromCode = true
        panel?.orderOut(nil)
        isClosingFromCode = false
        onCancel?()
    }

    private static func shortcutName(_ shortcut: HotkeyShortcut?) -> String {
        shortcut?.settingsDisplayName ?? L10n.text(en: "Not Set", zh: "未设置")
    }

    private static func holdShortcutName(_ shortcut: HotkeyShortcut?) -> String {
        shortcutName(shortcut)
    }
}

private final class SettingsPanelWindow: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if handleStandardTextEditingKey(event) {
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleStandardTextEditingKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleStandardTextEditingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let textView = firstResponder as? NSTextView
        else {
            return false
        }

        switch key {
        case "a":
            textView.selectAll(nil)
        case "c":
            textView.copy(nil)
        case "v":
            textView.paste(nil)
        case "x":
            textView.cut(nil)
        case "z" where event.modifierFlags.contains(.shift):
            textView.undoManager?.redo()
        case "z":
            textView.undoManager?.undo()
        default:
            return false
        }
        return true
    }
}

private final class SettingsPanelModel: ObservableObject {
    @Published var toggleShortcut: HotkeyShortcut?
    @Published var holdShortcut: HotkeyShortcut?
    @Published var translationShortcut: HotkeyShortcut?
    @Published var toggleShortcutName: String
    @Published var holdShortcutName: String
    @Published var translationShortcutName: String
    @Published var loginStatus: LoginStatus
    @Published var isKeyboardCaptureActive: Bool
    @Published var keyboardCaptureError: String?
    @Published var capturingShortcut: HotkeyShortcutSlot?
    @Published var shortcutErrorMessage: String?
    @Published var canCheckForUpdates: Bool = false
    let appVersion: String
    let microphoneDevices: [AudioInputDevice]
    @Published var selectedMicrophoneUID: String?
    @Published var selectedASRProvider: ASRProvider
    @Published var selectedLanguage: AppLanguage
    @Published var copyResultWhenInsertionFails = TextInsertionSettingsStore.copyResultWhenInsertionFails
    @Published var launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
    @Published var overlayShowsCancelControl = OverlayAppearanceStore.showsCancelControl
    @Published var overlayShowsSubmitControl = OverlayAppearanceStore.showsSubmitControl
    @Published var overlayShowsBorderLight = OverlayAppearanceStore.showsBorderLight
    @Published var selectedOverlaySize = OverlayAppearanceStore.size
    @Published var selectedWaveformStyle = OverlayAppearanceStore.waveformStyle
    @Published var overlayWaveformNoiseFloor = OverlayAppearanceStore.waveformNoiseFloor
    @Published var localPostProcessingEnabled = LocalLLMSettingsStore.postProcessingEnabled
    @Published var correctionBackend = CorrectionSettingsStore.backend
    @Published var selectedLocalLLMModel = LocalLLMSettingsStore.selectedModel
    @Published var remoteLLMProfiles = RemoteLLMSettingsStore.profiles
    @Published var selectedRemoteLLMProfile = RemoteLLMSettingsStore.selectedProfile
    @Published var remoteLLMAPIKey = ""
    @Published var localVocabulary = LocalLLMSettingsStore.vocabulary
    @Published var localPunctuationStyle = LocalLLMSettingsStore.punctuationStyle
    @Published var localRemoveFillerWords = LocalLLMSettingsStore.removeFillerWords
    @Published var localSoftenEmotionalLanguage = LocalLLMSettingsStore.softenEmotionalLanguage
    @Published var localOutputStyle = LocalLLMSettingsStore.outputStyle
    @Published var localOutputStyleStrength = LocalLLMSettingsStore.outputStyleStrength
    @Published var localCustomOutputStyleInstruction = LocalLLMSettingsStore.customOutputStyleInstruction
    @Published var includeCurrentTimeContext = LocalLLMSettingsStore.includeCurrentTimeContext
    @Published var includeFrontmostAppContext = LocalLLMSettingsStore.includeFrontmostAppContext
    @Published var includeWindowTitleContext = LocalLLMSettingsStore.includeWindowTitleContext
    @Published var selectionEditingEnabled = LocalLLMSettingsStore.selectionEditingEnabled
    @Published var translationTargetLanguage = LocalLLMSettingsStore.translationTargetLanguage
    @Published var localIncrementalSystemPrompt = LocalLLMSettingsStore.incrementalSystemPrompt
    @Published var localUserIdentity = LocalLLMSettingsStore.userIdentity
    @Published var localSystemPrompt = LocalLLMSettingsStore.customSystemPrompt
    @Published var localUserPromptTemplate = LocalLLMSettingsStore.customUserPromptTemplate
    @Published var localModelStatusRevision = 0
    @Published var mlxRuntimeDiagnostic = LocalMLXRuntimeDiagnostic.current()

    init(
        toggleShortcut: HotkeyShortcut?,
        holdShortcut: HotkeyShortcut?,
        translationShortcut: HotkeyShortcut?,
        toggleShortcutName: String,
        holdShortcutName: String,
        translationShortcutName: String,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?,
        selectedASRProvider: ASRProvider,
        selectedLanguage: AppLanguage
    ) {
        self.toggleShortcut = toggleShortcut
        self.holdShortcut = holdShortcut
        self.translationShortcut = translationShortcut
        self.toggleShortcutName = toggleShortcutName
        self.holdShortcutName = holdShortcutName
        self.translationShortcutName = translationShortcutName
        self.loginStatus = loginStatus
        self.isKeyboardCaptureActive = isKeyboardCaptureActive
        self.keyboardCaptureError = keyboardCaptureError
        self.appVersion = appVersion
        self.microphoneDevices = microphoneDevices
        self.selectedMicrophoneUID = selectedMicrophoneUID
        self.selectedASRProvider = selectedASRProvider
        self.selectedLanguage = selectedLanguage
    }

    var isLoggedIn: Bool {
        selectedASRProvider == .android || loginStatus == .loggedIn
    }

    var canEnableLocalPostProcessing: Bool {
        _ = localModelStatusRevision
        return selectedLocalLLMModel.isDownloaded
    }

    var canEnablePostProcessing: Bool {
        switch correctionBackend {
        case .local:
            canEnableLocalPostProcessing
        case .remote:
            selectedRemoteLLMProfile?.hasModelConfiguration == true
        }
    }

    var selectedLocalModelStatusText: String {
        canEnableLocalPostProcessing
            ? L10n.text(en: "Ready", zh: "已就绪")
            : L10n.text(en: "Not Downloaded", zh: "未下载")
    }

    var selectedLocalModelStatusIsHealthy: Bool {
        canEnableLocalPostProcessing
    }

    func refreshLocalModelStatus() {
        localModelStatusRevision += 1
        if correctionBackend == .local, !selectedLocalLLMModel.isDownloaded {
            localPostProcessingEnabled = false
            CorrectionSettingsStore.postProcessingEnabled = false
        }
    }

    func refreshMLXRuntimeDiagnostic() {
        mlxRuntimeDiagnostic = LocalMLXRuntimeDiagnostic.current()
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case features
    case ai
    case diagnose
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            L10n.text(en: "General", zh: "通用")
        case .account:
            L10n.text(en: "Account", zh: "账号")
        case .features:
            L10n.text(en: "Features", zh: "功能")
        case .ai:
            "AI"
        case .diagnose:
            L10n.text(en: "Diagnose", zh: "诊断")
        case .about:
            L10n.text(en: "About", zh: "关于")
        }
    }

    var iconName: String {
        switch self {
        case .general:
            return "gearshape"
        case .account:
            return "person.crop.circle"
        case .features:
            return "xmark.triangle.circle.square"
        case .ai:
            return "sparkles"
        case .diagnose:
            return "wrench.and.screwdriver"
        case .about:
            return "info.circle"
        }
    }

    var iconTint: Color {
        switch self {
        case .general:
            return Color(red: 0.22, green: 0.48, blue: 0.92)
        case .account:
            return Color(red: 0.38, green: 0.35, blue: 0.86)
        case .features:
            return Color(red: 0.91, green: 0.46, blue: 0.18)
        case .ai:
            return Color(red: 0.68, green: 0.30, blue: 0.86)
        case .diagnose:
            return Color(red: 0.08, green: 0.58, blue: 0.54)
        case .about:
            return Color(red: 0.42, green: 0.48, blue: 0.56)
        }
    }
}

private enum SettingsToastKind: Equatable {
    case success
    case info
    case error

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return .green
        case .info:
            return .accentColor
        case .error:
            return .orange
        }
    }
}

private struct SettingsToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let kind: SettingsToastKind
}

private struct SettingsToastView: View {
    let toast: SettingsToast

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toast.kind.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(toast.kind.tint)
                .frame(width: 18, height: 18)

            Text(toast.message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(toast.kind.tint.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
    }
}

private enum CorrectionDebugSelection: Hashable {
    case remote
    case local(LocalLLMModel)
}

private extension HotkeyShortcutSlot {
    var accessibilityName: String {
        switch self {
        case .toggle:
            return L10n.text(en: "Short press", zh: "短按")
        case .hold:
            return L10n.text(en: "Hold-to-talk", zh: "按住说话")
        case .translation:
            return L10n.text(en: "Translation", zh: "翻译")
        }
    }

    var helpName: String {
        switch self {
        case .toggle:
            return L10n.text(en: "short press", zh: "短按")
        case .hold:
            return L10n.text(en: "hold-to-talk", zh: "按住说话")
        case .translation:
            return L10n.text(en: "translation", zh: "翻译")
        }
    }
}

private struct SettingsPanelView: View {
    @ObservedObject var model: SettingsPanelModel
    let onBeginCapture: () -> Void
    let onEndCapture: () -> Void
    let onResetToggle: () -> Void
    let onClearToggle: () -> Void
    let onResetHold: () -> Void
    let onClearHold: () -> Void
    let onResetTranslation: () -> Void
    let onClearTranslation: () -> Void
    let onSelectMicrophone: (String?) -> Void
    let onSelectASRProvider: (ASRProvider) -> Void
    let onSelectLanguage: (AppLanguage) -> Void
    let onDownloadLocalLLMModel: (LocalLLMModel, @escaping @Sendable (Double) -> Void) async throws -> Void
    let onDeleteLocalLLMModel: (LocalLLMModel) async throws -> Void
    let onLogin: () -> Void
    let onLogout: () -> Void
    let onCopyLoginDebugInfo: () -> Void
    let onRepairLogin: () -> Void
    let onCopyLogPath: () -> Void
    let onOpenLog: () -> Void
    let onCheckForUpdates: () -> Void
    let onRequestAccessibility: () -> Void
    @State private var selectedTab: SettingsTab = .general
    @State private var downloadingLocalModels: Set<LocalLLMModel> = []
    @State private var deletingLocalModels: Set<LocalLLMModel> = []
    @State private var validatingLocalModels: Set<LocalLLMModel> = []
    @State private var localModelDownloadProgress: [LocalLLMModel: Double] = [:]
    @State private var isAddingLocalModel = false
    @State private var settingsToast: SettingsToast?
    @State private var validatingRemoteModelIDs: Set<String> = []
    @State private var vocabularyDraft = ""
    @State private var customOutputStyleEditorHeight: CGFloat = 82
    @State private var userIdentityEditorHeight: CGFloat = 92
    @State private var incrementalSystemPromptEditorHeight: CGFloat = 118
    @State private var systemPromptEditorHeight: CGFloat = 192
    @State private var userMessageEditorHeight: CGFloat = 118
    @State private var isResizingPromptEditor = false
    @State private var correctionDebugBackend = CorrectionSettingsStore.backend
    @State private var correctionDebugModel = LocalLLMPostProcessor.configuredModel
    @State private var correctionDebugInput = ""
    @State private var correctionDebugOutput = ""
    @State private var correctionDebugDurationText = ""
    @State private var correctionDebugError: String?
    @State private var correctionDebugTraceURL: URL?
    @State private var isRunningCorrectionDebug = false
    @State private var editingRemoteModelProfile: RemoteLLMModelProfile?
    @State private var isAddingRemoteModelProfile = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.top, 12)
                .padding(.horizontal, 18)

            Divider()
                .padding(.top, 12)

            tabContent
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .overlay(alignment: .bottom) {
            if let settingsToast {
                SettingsToastView(toast: settingsToast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                settingsTabItem(tab)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func settingsTabItem(_ tab: SettingsTab) -> some View {
        Button {
            model.capturingShortcut = nil
            model.shortcutErrorMessage = nil
            onEndCapture()
            selectedTab = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tabIconColor(for: tab))
                    .frame(width: 20, height: 18, alignment: .center)
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selectedTab == tab ? .primary : .secondary)
                    .frame(height: 13, alignment: .center)
            }
            .frame(width: 68, height: 48)
            .background(tabBackground(for: tab), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func tabBackground(for tab: SettingsTab) -> Color {
        selectedTab == tab ? tab.iconTint.opacity(0.16) : Color.clear
    }

    private func tabIconColor(for tab: SettingsTab) -> Color {
        selectedTab == tab ? tab.iconTint : tab.iconTint.opacity(0.62)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .account:
            accountTab
        case .features:
            featuresTab
        case .ai:
            aiTab
        case .diagnose:
            diagnoseTab
        case .about:
            aboutTab
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
                settingsTitle(L10n.text(en: "Startup", zh: "启动"))

                settingsSection {
                    settingsListRow(L10n.text(en: "Launch at Login", zh: "开机自启动")) {
                        Toggle("", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                settingsTitle(L10n.text(en: "Shortcuts", zh: "快捷键"))

                settingsSection {
                    settingsListRow(L10n.text(en: "Short Press", zh: "短按")) {
                        shortcutButtons(
                            slot: .toggle,
                            name: model.toggleShortcutName,
                            resetHelp: L10n.text(en: "Reset short press key", zh: "重置短按按键"),
                            clearHelp: L10n.text(en: "Clear short press key", zh: "清除短按按键"),
                            onReset: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onResetToggle()
                                model.toggleShortcut = HotkeyShortcut.defaultShortcut
                                model.toggleShortcutName = HotkeyShortcut.defaultShortcut.settingsDisplayName
                                onEndCapture()
                            },
                            onClear: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onClearToggle()
                                model.toggleShortcut = nil
                                model.toggleShortcutName = L10n.text(en: "Not Set", zh: "未设置")
                                onEndCapture()
                            }
                        )
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Hold", zh: "按住说话")) {
                        shortcutButtons(
                            slot: .hold,
                            name: model.holdShortcutName,
                            resetHelp: L10n.text(en: "Reset hold-to-talk key", zh: "重置按住说话按键"),
                            clearHelp: L10n.text(en: "Clear hold-to-talk key", zh: "清除按住说话按键"),
                            onReset: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onResetHold()
                                model.holdShortcut = HotkeyShortcut.defaultHoldShortcut
                                model.holdShortcutName = HotkeyShortcut.defaultHoldShortcut.settingsDisplayName
                                onEndCapture()
                            },
                            onClear: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onClearHold()
                                model.holdShortcut = nil
                                model.holdShortcutName = L10n.text(en: "Not Set", zh: "未设置")
                                onEndCapture()
                            }
                        )
                    }

                }

                if let message = model.shortcutErrorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14)
                }

                settingsTitle(L10n.text(en: "Input", zh: "输入"))

                settingsSection {
                    settingsListRow(L10n.text(en: "Microphone", zh: "麦克风")) {
                        Picker("", selection: microphoneBinding) {
                            Text(L10n.text(en: "System Default", zh: "系统默认")).tag(String?.none)
                            ForEach(model.microphoneDevices) { device in
                                Text(device.name).tag(Optional(device.uid))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: Self.settingsRowContentWidth, alignment: .trailing)
                    }
                }

                settingsTitle(L10n.text(en: "Appearance", zh: "外观"))

                settingsSection {
                    settingsListRow(L10n.text(en: "Language", zh: "语言")) {
                        Picker("", selection: languageBinding) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180, alignment: .trailing)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Overlay Size", zh: "浮窗尺寸")) {
                        Picker("", selection: overlaySizeBinding) {
                            ForEach(OverlayAppearanceStore.Size.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180, alignment: .trailing)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Cancel Button", zh: "取消按钮")) {
                        Toggle("", isOn: overlayShowsCancelControlBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Submit Button", zh: "提交按钮")) {
                        Toggle("", isOn: overlayShowsSubmitControlBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Border Light", zh: "边框流光")) {
                        Toggle("", isOn: overlayShowsBorderLightBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Waveform Style", zh: "波形样式")) {
                        Picker("", selection: overlayWaveformStyleBinding) {
                            ForEach(OverlayAppearanceStore.WaveformStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220, alignment: .trailing)
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Noise Gate", zh: "底噪门限")) {
                        HStack(spacing: 8) {
                            Slider(
                                value: overlayWaveformNoiseFloorBinding,
                                in: OverlayAppearanceStore.waveformNoiseFloorRange,
                                step: 0.01
                            )
                            .controlSize(.small)

                            Text(String(format: "%.2f", model.overlayWaveformNoiseFloor))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(width: Self.settingsGroupWidth, alignment: .topLeading)
        }
    }

    private func shortcutButtons(
        slot: HotkeyShortcutSlot,
        name: String,
        resetHelp: String,
        clearHelp: String,
        onReset: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                model.capturingShortcut = slot
                model.shortcutErrorMessage = nil
                onBeginCapture()
            } label: {
                Text(name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(shortcutForeground(for: name))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 172, height: 24)
                    .background(shortcutBackground(for: slot), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(shortcutBorder(for: slot), lineWidth: 1)
                    )
                    .accessibilityLabel(L10n.text(en: "\(slot.accessibilityName) key \(name)", zh: "\(slot.accessibilityName)按键 \(name)"))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Click to set \(slot.helpName) key", zh: "点击设置\(slot.helpName)按键"))

            shortcutIconButton(
                systemName: "arrow.counterclockwise",
                help: resetHelp,
                action: onReset
            )

            shortcutIconButton(
                systemName: "xmark",
                help: clearHelp,
                action: onClear
            )
        }
    }

    private func shortcutIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
        .help(help)
    }

    private func shortcutBackground(for slot: HotkeyShortcutSlot) -> Color {
        model.capturingShortcut == slot ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.08)
    }

    private func shortcutBorder(for slot: HotkeyShortcutSlot) -> Color {
        model.capturingShortcut == slot ? Color.accentColor.opacity(0.75) : Color.clear
    }

    private func shortcutForeground(for name: String) -> Color {
        name == L10n.text(en: "Not Set", zh: "未设置") || name == "Not Set" || name == "未设置" ? .secondary : .primary
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.selectedLanguage },
            set: { newValue in
                model.selectedLanguage = newValue
                onSelectLanguage(newValue)
            }
        )
    }

    private var aiDependentFeaturesEnabled: Bool {
        model.localPostProcessingEnabled
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { model.selectedMicrophoneUID },
            set: { newValue in
                model.selectedMicrophoneUID = newValue
                onSelectMicrophone(newValue)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLoginStore.setEnabled(newValue)
                    model.launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
                } catch {
                    model.launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
                    model.shortcutErrorMessage = L10n.text(
                        en: "Launch at login failed: \(error.localizedDescription)",
                        zh: "设置开机自启动失败：\(error.localizedDescription)"
                    )
                }
            }
        )
    }

    private var copyResultWhenInsertionFailsBinding: Binding<Bool> {
        Binding(
            get: { model.copyResultWhenInsertionFails },
            set: { newValue in
                model.copyResultWhenInsertionFails = newValue
                TextInsertionSettingsStore.copyResultWhenInsertionFails = newValue
            }
        )
    }

    private var overlayShowsCancelControlBinding: Binding<Bool> {
        Binding(
            get: { model.overlayShowsCancelControl },
            set: { newValue in
                model.overlayShowsCancelControl = newValue
                OverlayAppearanceStore.showsCancelControl = newValue
            }
        )
    }

    private var overlayShowsSubmitControlBinding: Binding<Bool> {
        Binding(
            get: { model.overlayShowsSubmitControl },
            set: { newValue in
                model.overlayShowsSubmitControl = newValue
                OverlayAppearanceStore.showsSubmitControl = newValue
            }
        )
    }

    private var overlayShowsBorderLightBinding: Binding<Bool> {
        Binding(
            get: { model.overlayShowsBorderLight },
            set: { newValue in
                model.overlayShowsBorderLight = newValue
                OverlayAppearanceStore.showsBorderLight = newValue
            }
        )
    }

    private var overlaySizeBinding: Binding<OverlayAppearanceStore.Size> {
        Binding(
            get: { model.selectedOverlaySize },
            set: { newValue in
                model.selectedOverlaySize = newValue
                OverlayAppearanceStore.size = newValue
            }
        )
    }

    private var overlayWaveformStyleBinding: Binding<OverlayAppearanceStore.WaveformStyle> {
        Binding(
            get: { model.selectedWaveformStyle },
            set: { newValue in
                model.selectedWaveformStyle = newValue
                OverlayAppearanceStore.waveformStyle = newValue
            }
        )
    }

    private var overlayWaveformNoiseFloorBinding: Binding<Double> {
        Binding(
            get: { model.overlayWaveformNoiseFloor },
            set: { newValue in
                model.overlayWaveformNoiseFloor = newValue
                OverlayAppearanceStore.waveformNoiseFloor = newValue
            }
        )
    }

    private var asrProviderBinding: Binding<ASRProvider> {
        Binding(
            get: { model.selectedASRProvider },
            set: { newValue in
                model.selectedASRProvider = newValue
                onSelectASRProvider(newValue)
            }
        )
    }

    private var accountTab: some View {
        VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
            settingsTitle(L10n.text(en: "Doubao", zh: "豆包"))

            settingsSection {
                settingsListRow(L10n.text(en: "Channel", zh: "渠道")) {
                    Picker("", selection: asrProviderBinding) {
                        ForEach(ASRProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220, alignment: .trailing)
                    .focusable(false)
                }

                settingsDivider()

                settingsListRow(L10n.text(en: "Status", zh: "状态")) {
                    switch model.selectedASRProvider {
                    case .web:
                        statusText(model.loginStatus == .loggedIn ? L10n.text(en: "Logged in", zh: "已登录") : L10n.text(en: "Not logged in", zh: "未登录"), isHealthy: model.loginStatus == .loggedIn)
                    case .android:
                        statusText(L10n.text(en: "Automatic", zh: "自动"), isHealthy: true)
                    case .mix:
                        statusText(model.loginStatus == .loggedIn ? L10n.text(en: "Web logged in + Android automatic", zh: "Web 已登录 + Android 自动") : L10n.text(en: "Web not logged in", zh: "Web 未登录"), isHealthy: model.loginStatus == .loggedIn)
                    }
                }

                settingsDivider()

                settingsListRow(L10n.text(en: "Account", zh: "账号")) {
                    if model.selectedASRProvider == .android {
                        Button(L10n.text(en: "Reset Android Credentials", zh: "重置 Android 凭据")) {
                            DoubaoAndroidCredentialStore.clear()
                        }
                        .focusable(false)
                        .help(L10n.text(en: "Clear cached Android IME credentials. They will be recreated on the next recording.", zh: "清除缓存的 Android 输入法凭据，下次录音会重新创建。"))
                    } else if model.selectedASRProvider == .mix {
                        HStack(spacing: 8) {
                            if model.loginStatus == .loggedIn {
                                Button(L10n.text(en: "Refresh Web", zh: "刷新 Web"), action: onRepairLogin)
                                    .focusable(false)

                                Button(L10n.text(en: "Log Out", zh: "退出登录")) {
                                    onLogout()
                                    model.loginStatus = .notLoggedIn
                                }
                                .focusable(false)
                            } else {
                                Button(L10n.text(en: "Log In", zh: "登录"), action: onLogin)
                                    .focusable(false)
                            }

                            Button(L10n.text(en: "Reset Android", zh: "重置 Android")) {
                                DoubaoAndroidCredentialStore.clear()
                            }
                            .focusable(false)
                            .help(L10n.text(en: "Clear cached Android IME credentials. They will be recreated on the next recording.", zh: "清除缓存的 Android 输入法凭据，下次录音会重新创建。"))
                        }
                    } else if model.loginStatus == .loggedIn {
                        HStack(spacing: 8) {
                            Button(L10n.text(en: "Refresh Credentials", zh: "刷新凭据"), action: onRepairLogin)
                                .focusable(false)

                            Button(L10n.text(en: "Log Out", zh: "退出登录")) {
                                onLogout()
                                model.loginStatus = .notLoggedIn
                            }
                            .focusable(false)
                        }
                    } else {
                        Button(L10n.text(en: "Log In", zh: "登录"), action: onLogin)
                            .focusable(false)
                    }
                }

            }
        }
        .frame(width: Self.settingsGroupWidth, alignment: .topLeading)
    }

    private var featuresTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
                settingsTitle(L10n.text(en: "Output", zh: "输出"))

                settingsSection {
                    correctionListRow(L10n.text(en: "Punctuation", zh: "标点"), contentAlignment: .trailing) {
                        Picker("", selection: punctuationStyleBinding) {
                            ForEach(PunctuationStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: Self.correctionContentWidth, alignment: .trailing)
                    }

                    settingsDivider()

                    correctionListRow(L10n.text(en: "Vocabularies", zh: "词库"), height: nil) {
                        vocabularyChipEditor
                    }

                    settingsDivider()

                    correctionListRow(
                        height: 48,
                        labelWidth: 148,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Remove Filler Words", zh: "去水词"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        Toggle("", isOn: removeFillerWordsBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!aiDependentFeaturesEnabled)
                            .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                            .help(L10n.text(en: "Remove filler words and brief hesitations while preserving meaning.", zh: "在保留语义的同时移除水词和短暂停顿。"))
                    }

                    settingsDivider()

                    correctionListRow(
                        height: 48,
                        labelWidth: 148,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Soften Emotion", zh: "弱化情绪"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        Toggle("", isOn: softenEmotionalLanguageBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!aiDependentFeaturesEnabled)
                            .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                            .help(L10n.text(en: "Rewrite hostile or overly emotional wording into a calmer expression without changing the core meaning.", zh: "在不改变核心含义的前提下，把攻击性或情绪化表达改得更克制。"))
                    }

                    settingsDivider()

                    correctionListRow(
                        height: 48,
                        labelWidth: 148,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Output Style", zh: "输出风格"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        Picker("", selection: outputStyleBinding) {
                            ForEach(LocalLLMOutputStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: Self.correctionRowContentWidth(labelWidth: 148), alignment: .trailing)
                        .disabled(!aiDependentFeaturesEnabled)
                        .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                    }

                    if model.localOutputStyle == .custom {
                        settingsDivider()

                        correctionListRow(
                            height: nil,
                            labelWidth: 148,
                            label: {
                                aiRequiredLabel(L10n.text(en: "Custom", zh: "自定义"), isEnabled: aiDependentFeaturesEnabled)
                            }
                        ) {
                            promptTextEditor(
                                text: customOutputStyleInstructionBinding,
                                height: $customOutputStyleEditorHeight,
                                placeholder: L10n.text(en: "Describe how AI should rewrite, translate, or format the transcript.", zh: "描述 AI 应如何改写、翻译或格式化转写文本。")
                            )
                            .disabled(!aiDependentFeaturesEnabled)
                            .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                        }
                    } else {
                        settingsDivider()

                        correctionListRow(
                            height: 48,
                            labelWidth: 148,
                            contentAlignment: .trailing,
                            label: {
                                aiRequiredLabel(L10n.text(en: "Style Strength", zh: "风格强度"), isEnabled: aiDependentFeaturesEnabled)
                            }
                        ) {
                            Picker("", selection: outputStyleStrengthBinding) {
                                ForEach(LocalLLMOutputStyleStrength.allCases) { strength in
                                    Text(strength.displayName).tag(strength)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 168, alignment: .trailing)
                            .disabled(!aiDependentFeaturesEnabled || model.localOutputStyle == .original)
                            .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                        }
                    }
                }

                settingsTitle(L10n.text(en: "Insertion", zh: "插入"))

                settingsSection {
                    correctionListRow(
                        L10n.text(en: "Copy on Failure", zh: "失败时复制"),
                        labelWidth: 160,
                        contentAlignment: .trailing
                    ) {
                        Toggle("", isOn: copyResultWhenInsertionFailsBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                settingsTitle(L10n.text(en: "Editing", zh: "编辑"))

                settingsSection {
                    correctionListRow(
                        height: 48,
                        labelWidth: 160,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Selection Editing", zh: "选区编辑"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        Toggle("", isOn: selectionEditingEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!aiDependentFeaturesEnabled)
                            .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                            .help(L10n.text(en: "When selected text exists, use speech as an edit instruction instead of replacing the selection.", zh: "存在选中文本时，将语音作为编辑指令，而不是直接替换选区。"))
                    }
                }

                settingsTitle(L10n.text(en: "Translation", zh: "翻译"))

                settingsSection {
                    correctionListRow(
                        height: 48,
                        labelWidth: 160,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Shortcut", zh: "快捷键"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        shortcutButtons(
                            slot: .translation,
                            name: model.translationShortcutName,
                            resetHelp: L10n.text(en: "Clear translation key", zh: "清除翻译按键"),
                            clearHelp: L10n.text(en: "Clear translation key", zh: "清除翻译按键"),
                            onReset: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onResetTranslation()
                                model.translationShortcut = nil
                                model.translationShortcutName = L10n.text(en: "Not Set", zh: "未设置")
                                onEndCapture()
                            },
                            onClear: {
                                model.capturingShortcut = nil
                                model.shortcutErrorMessage = nil
                                onClearTranslation()
                                model.translationShortcut = nil
                                model.translationShortcutName = L10n.text(en: "Not Set", zh: "未设置")
                                onEndCapture()
                            }
                        )
                    }

                    Text(L10n.text(
                        en: "Press during recording to switch to translation mode.",
                        zh: "录音过程中按下以切换为翻译模式。"
                    ))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.top, -4)
                    .padding(.bottom, 10)

                    settingsDivider()

                    correctionListRow(
                        height: 48,
                        labelWidth: 160,
                        contentAlignment: .trailing,
                        label: {
                            aiRequiredLabel(L10n.text(en: "Target Language", zh: "目标语言"), isEnabled: aiDependentFeaturesEnabled)
                        }
                    ) {
                        languageMenuPicker(
                            selection: translationTargetLanguageBinding,
                            options: TranslationTargetLanguage.allCases,
                            width: Self.correctionRowContentWidth(labelWidth: 160)
                        )
                        .disabled(!aiDependentFeaturesEnabled)
                        .opacity(aiDependentFeaturesEnabled ? 1 : Self.disabledFeatureOpacity)
                    }
                }
            }
            .frame(width: Self.settingsGroupWidth, alignment: .topLeading)
        }
    }

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
                settingsTitle(L10n.text(en: "Status", zh: "状态"))

                settingsSection {
                    correctionListRow(L10n.text(en: "Enable", zh: "启用"), contentAlignment: .trailing) {
                        Toggle("", isOn: localPostProcessingBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!model.canEnablePostProcessing)
                            .help(L10n.text(en: "Use AI after transcription for correction, rewriting, translation, and custom actions.", zh: "转写后使用 AI 进行纠错、改写、翻译和自定义操作。"))
                    }
                }

                settingsTitle(L10n.text(en: "Model", zh: "模型"))

                settingsSection {
                    correctionListRow(L10n.text(en: "Backend", zh: "后端"), contentAlignment: .trailing) {
                        Picker("", selection: correctionBackendBinding) {
                            ForEach(CorrectionBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 168, alignment: .trailing)
                    }

                    settingsDivider()

                    if model.correctionBackend == .local {
                        localModelList
                    } else {
                        remoteModelSettings
                    }
                }

                settingsTitle(L10n.text(en: "Context", zh: "上下文"))

                settingsSection {
                    correctionListRow(L10n.text(en: "Current Time", zh: "当前时间"), contentAlignment: .trailing) {
                        Toggle("", isOn: includeCurrentTimeContextBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help(L10n.text(en: "Send current local time, weekday, and timezone to AI.", zh: "把当前本地时间、星期和时区传给 AI。"))
                    }

                    settingsDivider()

                    correctionListRow(L10n.text(en: "Frontmost App", zh: "前台应用"), contentAlignment: .trailing) {
                        Toggle("", isOn: includeFrontmostAppContextBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help(L10n.text(en: "Send the frontmost app name to AI for context.", zh: "把前台应用名称作为上下文传给 AI。"))
                    }

                    settingsDivider()

                    correctionListRow(L10n.text(en: "Window Title", zh: "窗口标题"), contentAlignment: .trailing) {
                        Toggle("", isOn: includeWindowTitleContextBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!model.includeFrontmostAppContext)
                            .help(L10n.text(en: "Optionally send the active window title. This may include document, page, chat, or project names.", zh: "可选传入当前窗口标题；标题可能包含文档、网页、聊天或项目名称。"))
                    }

                }

                settingsDocumentationTitle(L10n.text(en: "Advanced", zh: "高级"))

                settingsSection {
                    correctionListRow(
                        height: nil,
                        label: {
                            correctionRowLabel(L10n.text(en: "User Identity", zh: "用户身份"))
                        }
                    ) {
                        promptTextEditor(
                            text: localUserIdentityBinding,
                            height: $userIdentityEditorHeight,
                            placeholder: L10n.text(en: "Describe your role, domain, terminology preferences, or writing context.", zh: "描述你的身份、领域、术语偏好或写作场景。")
                        )
                    }

                    settingsDivider()

                    correctionListRow(
                        height: nil,
                        label: {
                            correctionRowLabel(L10n.text(en: "Add-on Prompt", zh: "增量提示词"))
                        }
                    ) {
                        promptTextEditor(
                            text: localIncrementalSystemPromptBinding,
                            height: $incrementalSystemPromptEditorHeight,
                            placeholder: L10n.text(en: "Append rules to the system prompt", zh: "追加系统提示词片段")
                        )
                    }

                    settingsDivider()

                    correctionListRow(
                        height: nil,
                        label: {
                            correctionRowLabel(L10n.text(en: "System Prompt", zh: "系统提示词"))
                        }
                    ) {
                        promptTextEditor(
                            text: localSystemPromptBinding,
                            height: $systemPromptEditorHeight,
                            placeholder: L10n.text(en: "Use the built-in system prompt", zh: "使用内置系统提示词")
                        )
                    }

                    settingsDivider()

                    correctionListRow(
                        height: nil,
                        label: {
                            correctionRowLabel(L10n.text(en: "User Message", zh: "用户消息"))
                        }
                    ) {
                        promptTextEditor(
                            text: localUserPromptTemplateBinding,
                            height: $userMessageEditorHeight,
                            placeholder: L10n.text(en: "Use the built-in user message template", zh: "使用内置用户消息模板")
                        )
                    }
                }
            }
            .frame(width: Self.settingsGroupWidth, alignment: .topLeading)
        }
        .onAppear {
            model.refreshLocalModelStatus()
        }
    }

    private func localModelRow(_ localModel: LocalLLMModel) -> some View {
        let isSelected = model.selectedLocalLLMModel == localModel
        let isDownloaded = localModel.isDownloaded
        let isDownloading = downloadingLocalModels.contains(localModel)
        let isDeleting = deletingLocalModels.contains(localModel)
        let progress = localModelDownloadProgress[localModel] ?? 0

        return HStack(spacing: 8) {
            Button {
                model.selectedLocalLLMModel = localModel
                LocalLLMSettingsStore.selectedModel = localModel
                model.refreshLocalModelStatus()
                dismissSettingsToast()
                Task {
                    await LocalLLMPostProcessor.shared.retainOnly(localModel, reason: "settings_select")
                }
                prewarmLocalModelIfNeeded(localModel, reason: "select")
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Use \(localModel.displayName) for final processing", zh: "使用 \(localModel.displayName) 进行最终处理"))

            VStack(alignment: .leading, spacing: 2) {
                Text(localModel.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .help(localModel.displayName)

                Text("\(localModelDetailText(localModel)) · \(localModelDownloadSizeText(localModel))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDownloading {
                downloadProgressView(progress: progress)
            } else if isDeleting {
                localModelDeletingView
            } else if localModel.isLocalDirectoryModel {
                localDirectoryModelAccessory(localModel)
            } else if isDownloaded {
                downloadedModelAccessory(localModel)
            } else {
                Button {
                    downloadLocalModel(localModel)
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.accentColor)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .frame(width: Self.localModelSingleAccessoryWidth, alignment: .leading)
                .help(L10n.text(en: "Download \(localModel.displayName)", zh: "下载 \(localModel.displayName)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func localModelDetailText(_ localModel: LocalLLMModel) -> String {
        switch localModel.detailText {
        case "Fastest · smallest":
            L10n.text(en: "Fastest · smallest", zh: "最快 · 最小")
        case "Fast · sharper":
            L10n.text(en: "Fast · sharper", zh: "快速 · 更清晰")
        case "Balanced quality":
            L10n.text(en: "Balanced quality", zh: "质量均衡")
        case "Best quality":
            L10n.text(en: "Best quality", zh: "最佳质量")
        case "Local MLX model":
            L10n.text(en: "Local MLX model", zh: "本地 MLX 模型")
        default:
            localModel.detailText
        }
    }

    private func localModelDownloadSizeText(_ localModel: LocalLLMModel) -> String {
        localModel.downloadSizeText == "Local Folder"
            ? L10n.text(en: "Local Folder", zh: "本地文件夹")
            : localModel.downloadSizeText
    }

    private var localModelList: some View {
        let localModels = LocalLLMModel.allCases
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text(en: "Models", zh: "模型"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isAddingLocalModel {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }

                Button {
                    addLocalModelFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(isAddingLocalModel)
                .help(L10n.text(
                    en: "Add a local MLX folder with config, tokenizer, and safetensors files.",
                    zh: "添加包含 config、tokenizer 和 safetensors 文件的本地 MLX 文件夹。"
                ))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            VStack(spacing: 0) {
                ForEach(localModels) { localModel in
                    localModelRow(localModel)
                    if localModel != localModels.last {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                            .padding(.leading, 40)
                            .padding(.trailing, 10)
                    }
                }
            }
        }
    }

    private var remoteModelSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            remoteModelList

            if editingRemoteModelProfile != nil {
                settingsDivider()
                remoteModelEditor
            }
        }
    }

    private var remoteModelEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            correctionListRow(L10n.text(en: "Name", zh: "名称")) {
                TextField(L10n.text(en: "Remote model", zh: "远端模型"), text: remoteLLMProfileNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: Self.correctionContentWidth)
            }

            settingsDivider()

            correctionListRow(L10n.text(en: "Provider", zh: "服务商"), contentAlignment: .trailing) {
                Picker("", selection: remoteLLMProviderBinding) {
                    ForEach(RemoteLLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: Self.correctionContentWidth, alignment: .trailing)
            }

            settingsDivider()

            correctionListRow("Base URL") {
                TextField("https://api.example.com/v1", text: remoteLLMBaseURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: Self.correctionContentWidth)
            }

            settingsDivider()

            correctionListRow(L10n.text(en: "Model", zh: "模型")) {
                TextField("model-id", text: remoteLLMModelBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: Self.correctionContentWidth)
            }

            settingsDivider()

            correctionListRow("API Key") {
                SecureCredentialField(text: remoteLLMAPIKeyBinding, placeholder: L10n.text(en: "Paste key to replace saved key", zh: "粘贴新 key 以替换已保存的 key"))
                    .frame(width: Self.correctionContentWidth)
            }

            settingsDivider()

            remoteModelEditorFooter
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var remoteModelEditorFooter: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: cancelRemoteModelEditing) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Cancel", zh: "取消"))

            Button(action: saveRemoteModelProfile) {
                Image(systemName: isAddingRemoteModelProfile ? "plus" : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!canSaveEditingRemoteModelProfile)
            .help(isAddingRemoteModelProfile ? L10n.text(en: "Add remote model", zh: "添加远端模型") : L10n.text(en: "Save remote model", zh: "保存远端模型"))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var remoteModelList: some View {
        let profiles = model.remoteLLMProfiles
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text(en: "Models", zh: "模型"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    addRemoteModelProfile()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(editingRemoteModelProfile != nil)
                .help(L10n.text(en: "Add a remote model", zh: "添加远端模型"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            VStack(spacing: 0) {
                if profiles.isEmpty, editingRemoteModelProfile == nil {
                    Text(L10n.text(en: "No Models", zh: "没有模型"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                } else {
                    ForEach(profiles) { profile in
                        remoteModelRow(profile)
                        if profile.id != profiles.last?.id {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, 40)
                                .padding(.trailing, 10)
                        }
                    }
                }
            }
        }
    }

    private func remoteModelRow(_ profile: RemoteLLMModelProfile) -> some View {
        let isSelected = model.selectedRemoteLLMProfile?.id == profile.id

        return HStack(spacing: 8) {
            Button {
                selectRemoteModelProfile(profile)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Use \(profile.displayName) for final processing", zh: "使用 \(profile.displayName) 进行最终处理"))

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .help(profile.displayName)

                Text(remoteModelDetailText(profile))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if validatingRemoteModelIDs.contains(profile.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Button {
                        validateRemoteLLMConfiguration(for: profile)
                    } label: {
                        Image(systemName: "speedometer")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(profile.hasModelConfiguration ? .secondary : .secondary.opacity(0.45))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(validatingRemoteModelIDs.contains(profile.id) || !profile.hasModelConfiguration)
                    .help(L10n.text(en: "Validate \(profile.displayName)", zh: "验证 \(profile.displayName)"))
                }

                Button {
                    editRemoteModelProfile(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.text(en: "Edit \(profile.displayName)", zh: "编辑 \(profile.displayName)"))

                Button {
                    removeRemoteModelProfile(profile)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.text(en: "Remove \(profile.displayName) from the model list", zh: "从模型列表中移除 \(profile.displayName)"))
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var localPostProcessingBinding: Binding<Bool> {
        Binding(
            get: {
                model.localPostProcessingEnabled && model.canEnablePostProcessing
            },
            set: { newValue in
                let enabled = newValue && model.canEnablePostProcessing
                model.localPostProcessingEnabled = enabled
                CorrectionSettingsStore.postProcessingEnabled = enabled
                if enabled {
                    prewarmLocalModelIfNeeded(model.selectedLocalLLMModel, reason: "enable")
                } else {
                    Task {
                        await LocalLLMPostProcessor.shared.releaseAll(reason: "settings_disable")
                    }
                }
            }
        )
    }

    private var correctionBackendBinding: Binding<CorrectionBackend> {
        Binding(
            get: {
                model.correctionBackend
            },
            set: { newValue in
                model.correctionBackend = newValue
                CorrectionSettingsStore.backend = newValue
                if model.localPostProcessingEnabled, !model.canEnablePostProcessing {
                    model.localPostProcessingEnabled = false
                    CorrectionSettingsStore.postProcessingEnabled = false
                }
                if newValue == .local, model.localPostProcessingEnabled {
                    prewarmLocalModelIfNeeded(model.selectedLocalLLMModel, reason: "backend")
                } else if newValue == .remote {
                    Task {
                        await LocalLLMPostProcessor.shared.releaseAll(reason: "settings_remote_backend")
                    }
                }
            }
        )
    }

    private var remoteLLMProviderBinding: Binding<RemoteLLMProvider> {
        Binding(
            get: {
                editingRemoteModelProfile?.provider ?? .custom
            },
            set: { newValue in
                var profile = editingRemoteModelProfile ?? RemoteLLMModelProfile.custom()
                profile.provider = newValue
                if newValue != .custom {
                    profile.displayName = newValue.displayName
                    profile.baseURL = newValue.defaultBaseURL
                    profile.model = newValue.defaultModel
                }
                editingRemoteModelProfile = profile
            }
        )
    }

    private var remoteLLMProfileNameBinding: Binding<String> {
        Binding(
            get: {
                editingRemoteModelProfile?.displayName ?? ""
            },
            set: { newValue in
                var profile = editingRemoteModelProfile ?? RemoteLLMModelProfile.custom()
                profile.displayName = newValue
                editingRemoteModelProfile = profile
            }
        )
    }

    private var remoteLLMBaseURLBinding: Binding<String> {
        Binding(
            get: {
                editingRemoteModelProfile?.baseURL ?? ""
            },
            set: { newValue in
                var profile = editingRemoteModelProfile ?? RemoteLLMModelProfile.custom()
                profile.baseURL = newValue
                editingRemoteModelProfile = profile
            }
        )
    }

    private var remoteLLMModelBinding: Binding<String> {
        Binding(
            get: {
                editingRemoteModelProfile?.model ?? ""
            },
            set: { newValue in
                var profile = editingRemoteModelProfile ?? RemoteLLMModelProfile.custom()
                profile.model = newValue
                editingRemoteModelProfile = profile
            }
        )
    }

    private var remoteLLMAPIKeyBinding: Binding<String> {
        Binding(
            get: {
                model.remoteLLMAPIKey
            },
            set: { newValue in
                model.remoteLLMAPIKey = newValue
            }
        )
    }

    private var canSaveEditingRemoteModelProfile: Bool {
        guard let profile = editingRemoteModelProfile else { return false }
        return profile.hasModelConfiguration
    }

    private func validateRemoteLLMConfiguration(for profile: RemoteLLMModelProfile) {
        guard !validatingRemoteModelIDs.contains(profile.id) else { return }
        validatingRemoteModelIDs.insert(profile.id)
        dismissSettingsToast()
        let configuration = remoteLLMConfiguration(for: profile)
        let startedAt = ProcessInfo.processInfo.systemUptime

        Task {
            do {
                _ = try await RemoteLLMPostProcessor.shared.validate(
                    configuration: configuration
                )
                await MainActor.run {
                    validatingRemoteModelIDs.remove(profile.id)
                    presentSettingsToast(
                        L10n.text(en: "Remote model validated in \(Self.milliseconds(since: startedAt)) ms.", zh: "远端模型验证通过，耗时 \(Self.milliseconds(since: startedAt)) ms。"),
                        kind: .success
                    )
                }
            } catch {
                await MainActor.run {
                    validatingRemoteModelIDs.remove(profile.id)
                    presentSettingsToast(L10n.text(en: "Remote validation failed: \(error.localizedDescription)", zh: "远端验证失败：\(error.localizedDescription)"), kind: .error)
                }
            }
        }
    }

    private func remoteLLMConfiguration(for profile: RemoteLLMModelProfile) -> RemoteLLMConfiguration {
        RemoteLLMConfiguration(
            provider: profile.provider,
            baseURL: profile.baseURL,
            apiKey: RemoteLLMCredentialStore.shared.apiKey(profile: profile) ?? "",
            model: profile.model,
            timeoutSeconds: RemoteLLMSettingsStore.timeoutSeconds,
            temperature: RemoteLLMSettingsStore.temperature,
            reasoningMode: .disabled
        )
    }

    private func selectRemoteModelProfile(_ profile: RemoteLLMModelProfile) {
        model.selectedRemoteLLMProfile = profile
        RemoteLLMSettingsStore.selectedProfile = profile
        model.remoteLLMAPIKey = ""
        dismissSettingsToast()
    }

    private func addRemoteModelProfile() {
        editingRemoteModelProfile = RemoteLLMModelProfile.custom()
        isAddingRemoteModelProfile = true
        model.remoteLLMAPIKey = ""
        dismissSettingsToast()
    }

    private func editRemoteModelProfile(_ profile: RemoteLLMModelProfile) {
        editingRemoteModelProfile = profile
        isAddingRemoteModelProfile = false
        model.remoteLLMAPIKey = ""
        dismissSettingsToast()
    }

    private func cancelRemoteModelEditing() {
        editingRemoteModelProfile = nil
        isAddingRemoteModelProfile = false
        model.remoteLLMAPIKey = ""
        dismissSettingsToast()
    }

    private func saveRemoteModelProfile() {
        guard var profile = editingRemoteModelProfile else { return }
        let trimmedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = trimmedName.isEmpty ? remoteModelFallbackName(profile) : trimmedName
        guard profile.hasModelConfiguration else { return }

        do {
            let trimmedKey = model.remoteLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try RemoteLLMCredentialStore.shared.setAPIKey(trimmedKey, profile: profile)
            }
            RemoteLLMSettingsStore.selectedProfile = profile
            model.selectedRemoteLLMProfile = profile
            refreshRemoteModelProfiles()
            editingRemoteModelProfile = nil
            let wasAdding = isAddingRemoteModelProfile
            isAddingRemoteModelProfile = false
            model.remoteLLMAPIKey = ""
            presentSettingsToast(wasAdding ? L10n.text(en: "Remote model added.", zh: "远端模型已添加。") : L10n.text(en: "Remote model saved.", zh: "远端模型已保存。"), kind: .success)
        } catch {
            presentSettingsToast(L10n.text(en: "Saving remote API key failed: \(error.localizedDescription)", zh: "保存远端 API key 失败：\(error.localizedDescription)"), kind: .error)
        }
    }

    private func removeRemoteModelProfile(_ profile: RemoteLLMModelProfile) {
        RemoteLLMSettingsStore.removeProfile(profile)
        model.selectedRemoteLLMProfile = RemoteLLMSettingsStore.selectedProfile
        refreshRemoteModelProfiles()
        if editingRemoteModelProfile?.id == profile.id {
            editingRemoteModelProfile = nil
            isAddingRemoteModelProfile = false
        }
        model.remoteLLMAPIKey = ""
        presentSettingsToast(L10n.text(en: "Removed remote model from the list.", zh: "已从列表移除远端模型。"), kind: .info)
        if model.localPostProcessingEnabled, !model.canEnablePostProcessing {
            model.localPostProcessingEnabled = false
            CorrectionSettingsStore.postProcessingEnabled = false
        }
    }

    private func remoteModelFallbackName(_ profile: RemoteLLMModelProfile) -> String {
        let trimmedModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            return trimmedModel
        }
        return profile.provider.displayName
    }

    private func refreshRemoteModelProfiles() {
        model.remoteLLMProfiles = RemoteLLMSettingsStore.profiles
    }

    private func remoteModelDetailText(_ profile: RemoteLLMModelProfile) -> String {
        let trimmedModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return profile.provider.displayName
        }
        return "\(profile.provider.displayName) · \(trimmedModel)"
    }

    private var punctuationStyleBinding: Binding<PunctuationStyle> {
        Binding(
            get: {
                model.localPunctuationStyle
            },
            set: { newValue in
                model.localPunctuationStyle = newValue
                LocalLLMSettingsStore.punctuationStyle = newValue
            }
        )
    }

    private var removeFillerWordsBinding: Binding<Bool> {
        Binding(
            get: {
                model.localRemoveFillerWords
            },
            set: { newValue in
                model.localRemoveFillerWords = newValue
                LocalLLMSettingsStore.removeFillerWords = newValue
            }
        )
    }

    private var softenEmotionalLanguageBinding: Binding<Bool> {
        Binding(
            get: {
                model.localSoftenEmotionalLanguage
            },
            set: { newValue in
                model.localSoftenEmotionalLanguage = newValue
                LocalLLMSettingsStore.softenEmotionalLanguage = newValue
            }
        )
    }

    private var outputStyleBinding: Binding<LocalLLMOutputStyle> {
        Binding(
            get: {
                model.localOutputStyle
            },
            set: { newValue in
                model.localOutputStyle = newValue
                LocalLLMSettingsStore.outputStyle = newValue
            }
        )
    }

    private var outputStyleStrengthBinding: Binding<LocalLLMOutputStyleStrength> {
        Binding(
            get: {
                model.localOutputStyleStrength
            },
            set: { newValue in
                model.localOutputStyleStrength = newValue
                LocalLLMSettingsStore.outputStyleStrength = newValue
            }
        )
    }

    private var customOutputStyleInstructionBinding: Binding<String> {
        Binding(
            get: {
                model.localCustomOutputStyleInstruction
            },
            set: { newValue in
                model.localCustomOutputStyleInstruction = newValue
                LocalLLMSettingsStore.customOutputStyleInstruction = newValue
            }
        )
    }

    private var includeCurrentTimeContextBinding: Binding<Bool> {
        Binding(
            get: {
                model.includeCurrentTimeContext
            },
            set: { newValue in
                model.includeCurrentTimeContext = newValue
                LocalLLMSettingsStore.includeCurrentTimeContext = newValue
            }
        )
    }

    private var includeFrontmostAppContextBinding: Binding<Bool> {
        Binding(
            get: {
                model.includeFrontmostAppContext
            },
            set: { newValue in
                model.includeFrontmostAppContext = newValue
                LocalLLMSettingsStore.includeFrontmostAppContext = newValue
                if !newValue, model.includeWindowTitleContext {
                    model.includeWindowTitleContext = false
                    LocalLLMSettingsStore.includeWindowTitleContext = false
                }
            }
        )
    }

    private var includeWindowTitleContextBinding: Binding<Bool> {
        Binding(
            get: {
                model.includeWindowTitleContext
            },
            set: { newValue in
                let enabled = newValue && model.includeFrontmostAppContext
                model.includeWindowTitleContext = enabled
                LocalLLMSettingsStore.includeWindowTitleContext = enabled
            }
        )
    }

    private var selectionEditingEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                model.selectionEditingEnabled
            },
            set: { newValue in
                model.selectionEditingEnabled = newValue
                LocalLLMSettingsStore.selectionEditingEnabled = newValue
            }
        )
    }

    private var translationTargetLanguageBinding: Binding<TranslationTargetLanguage> {
        Binding(
            get: {
                model.translationTargetLanguage
            },
            set: { newValue in
                model.translationTargetLanguage = newValue
                LocalLLMSettingsStore.translationTargetLanguage = newValue
            }
        )
    }

    private var vocabularyChipEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(vocabularyPhrases, id: \.self) { phrase in
                    VocabularyChip(title: phrase) {
                        removeVocabularyPhrase(phrase)
                    }
                }

                TextField(L10n.text(en: "Add term", zh: "添加词条"), text: $vocabularyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .frame(width: 96, height: 24)
                    .padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onSubmit {
                        commitVocabularyDraft()
                    }
            }
            .frame(width: Self.correctionContentWidth, alignment: .leading)
        }
    }

    private var vocabularyPhrases: [String] {
        Self.normalizedVocabularyPhrases(from: model.localVocabulary)
    }

    private func commitVocabularyDraft() {
        let newPhrases = Self.normalizedVocabularyPhrases(from: vocabularyDraft)
        guard !newPhrases.isEmpty else {
            vocabularyDraft = ""
            return
        }

        var phrases = vocabularyPhrases
        var seen = Set(phrases.map { $0.lowercased() })
        for phrase in newPhrases {
            let key = phrase.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            phrases.append(phrase)
        }

        setVocabularyPhrases(phrases)
        vocabularyDraft = ""
    }

    private func removeVocabularyPhrase(_ phrase: String) {
        let keyToRemove = phrase.lowercased()
        setVocabularyPhrases(vocabularyPhrases.filter { $0.lowercased() != keyToRemove })
    }

    private func setVocabularyPhrases(_ phrases: [String]) {
        let value = phrases.joined(separator: "\n")
        model.localVocabulary = value
        LocalLLMSettingsStore.vocabulary = value
    }

    private static func normalizedVocabularyPhrases(from rawValue: String) -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",，、;；"))
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: separators)
            .map(normalizedVocabularyPhrase)
            .filter { !$0.isEmpty }
            .filter { phrase in
                let key = phrase.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    private static func normalizedVocabularyPhrase(_ rawValue: String) -> String {
        var phrase = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.hasPrefix("-") {
            phrase.removeFirst()
            phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return phrase
    }

    private var localSystemPromptBinding: Binding<String> {
        Binding(
            get: {
                model.localSystemPrompt
            },
            set: { newValue in
                model.localSystemPrompt = newValue
                LocalLLMSettingsStore.customSystemPrompt = newValue
            }
        )
    }

    private var localIncrementalSystemPromptBinding: Binding<String> {
        Binding(
            get: {
                model.localIncrementalSystemPrompt
            },
            set: { newValue in
                model.localIncrementalSystemPrompt = newValue
                LocalLLMSettingsStore.incrementalSystemPrompt = newValue
            }
        )
    }

    private var localUserIdentityBinding: Binding<String> {
        Binding(
            get: {
                model.localUserIdentity
            },
            set: { newValue in
                model.localUserIdentity = newValue
                LocalLLMSettingsStore.userIdentity = newValue
            }
        )
    }

    private var localUserPromptTemplateBinding: Binding<String> {
        Binding(
            get: {
                model.localUserPromptTemplate
            },
            set: { newValue in
                model.localUserPromptTemplate = newValue
                LocalLLMSettingsStore.customUserPromptTemplate = newValue
            }
        )
    }

    private func promptTextEditor(
        text: Binding<String>,
        height: Binding<CGFloat>,
        placeholder: String = ""
    ) -> some View {
        ResizablePromptTextEditor(
            text: text,
            height: height,
            isResizing: $isResizingPromptEditor,
            width: Self.correctionContentWidth,
            placeholder: placeholder
        )
    }

    private func addLocalModelFolder() {
        guard !isAddingLocalModel else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.text(en: "Choose Local MLX Model Folder", zh: "选择本地 MLX 模型文件夹")
        panel.prompt = L10n.text(en: "Add Model", zh: "添加模型")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isAddingLocalModel = true
        dismissSettingsToast()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    let localModel: LocalLLMModel? = try LocalLLMSettingsStore.addCustomModelDirectory(url)
                    return (model: localModel, errorMessage: nil as String?)
                } catch {
                    return (model: nil as LocalLLMModel?, errorMessage: error.localizedDescription)
                }
            }.value

            await MainActor.run {
                isAddingLocalModel = false

                if let localModel = result.model {
                    model.selectedLocalLLMModel = localModel
                    LocalLLMSettingsStore.selectedModel = localModel
                    presentSettingsToast(L10n.text(en: "Added local model: \(localModel.displayName)", zh: "已添加本地模型：\(localModel.displayName)"), kind: .success)
                    model.refreshLocalModelStatus()
                } else {
                    presentSettingsToast(L10n.text(en: "Add local model failed: \(result.errorMessage ?? "Unknown error")", zh: "添加本地模型失败：\(result.errorMessage ?? "未知错误")"), kind: .error)
                }
            }
        }
    }

    private func removeLocalModel(_ selectedModel: LocalLLMModel) {
        let wasSelected = model.selectedLocalLLMModel == selectedModel
        LocalLLMSettingsStore.removeCustomModel(selectedModel)
        if wasSelected {
            model.selectedLocalLLMModel = LocalLLMSettingsStore.selectedModel
        }
        presentSettingsToast(L10n.text(en: "Removed local model from the list.", zh: "已从列表移除本地模型。"), kind: .info)
        model.refreshLocalModelStatus()
    }

    private func downloadLocalModel(_ selectedModel: LocalLLMModel) {
        guard selectedModel.isHuggingFaceModel else { return }
        downloadingLocalModels.insert(selectedModel)
        localModelDownloadProgress[selectedModel] = 0
        dismissSettingsToast()

        Task {
            do {
                try await onDownloadLocalLLMModel(selectedModel) { progress in
                    Task { @MainActor in
                        guard progress.isFinite else { return }
                        let normalizedProgress = min(max(progress, 0), 1)
                        localModelDownloadProgress[selectedModel] = max(
                            localModelDownloadProgress[selectedModel] ?? 0,
                            normalizedProgress
                        )
                    }
                }
                await MainActor.run {
                    downloadingLocalModels.remove(selectedModel)
                    localModelDownloadProgress[selectedModel] = 1
                    dismissSettingsToast()
                    model.refreshLocalModelStatus()
                }
            } catch {
                await MainActor.run {
                    downloadingLocalModels.remove(selectedModel)
                    localModelDownloadProgress[selectedModel] = 0
                    presentSettingsToast(L10n.text(en: "Download failed: \(error.localizedDescription)", zh: "下载失败：\(error.localizedDescription)"), kind: .error)
                    model.refreshLocalModelStatus()
                }
            }
        }
    }

    private func deleteLocalModel(_ selectedModel: LocalLLMModel) {
        guard selectedModel.isHuggingFaceModel else { return }
        let selectedIsDownloaded = selectedModel.isDownloaded
        let isDownloading = downloadingLocalModels.contains(selectedModel)
        let isDeleting = deletingLocalModels.contains(selectedModel)
        let downloadedCount = downloadedLocalModels.count
        let canDelete = canDeleteLocalModel(
            selectedModel,
            isDownloaded: selectedIsDownloaded,
            isDownloading: isDownloading,
            isDeleting: isDeleting,
            downloadedCount: downloadedCount
        )
        AppLog.info("Local LLM delete button pressed model=\(selectedModel.repositoryID) downloaded=\(selectedIsDownloaded) downloading=\(isDownloading) deleting=\(isDeleting) enabled=\(model.localPostProcessingEnabled) downloadedCount=\(downloadedCount) canDelete=\(canDelete)")
        guard canDelete else {
            AppLog.info("Local LLM delete button ignored model=\(selectedModel.repositoryID)")
            presentSettingsToast(L10n.text(en: "AI Post-processing needs at least one downloaded model.", zh: "AI 后处理至少需要一个已下载模型。"), kind: .error)
            return
        }

        deletingLocalModels.insert(selectedModel)
        dismissSettingsToast()

        Task {
            do {
                AppLog.info("Local LLM delete task started model=\(selectedModel.repositoryID)")
                try await onDeleteLocalLLMModel(selectedModel)
                await MainActor.run {
                    deletingLocalModels.remove(selectedModel)
                    localModelDownloadProgress.removeValue(forKey: selectedModel)
                    selectFallbackModelIfNeeded(afterDeleting: selectedModel)
                    dismissSettingsToast()
                    model.refreshLocalModelStatus()
                }
                AppLog.info("Local LLM delete task finished model=\(selectedModel.repositoryID)")
            } catch {
                AppLog.error("Local LLM delete task failed model=\(selectedModel.repositoryID) error=\(error.localizedDescription)")
                await MainActor.run {
                    deletingLocalModels.remove(selectedModel)
                    presentSettingsToast(L10n.text(en: "Delete failed: \(error.localizedDescription)", zh: "删除失败：\(error.localizedDescription)"), kind: .error)
                    model.refreshLocalModelStatus()
                }
            }
        }
    }

    private func prewarmLocalModelIfNeeded(_ selectedModel: LocalLLMModel, reason: String) {
        guard model.correctionBackend == .local,
              model.localPostProcessingEnabled,
              selectedModel.isDownloaded
        else {
            return
        }

        Task {
            let startedAt = ProcessInfo.processInfo.systemUptime
            AppLog.info("Local LLM prewarm start reason=settings_\(reason) model=\(selectedModel.repositoryID)")
            do {
                try await LocalLLMPostProcessor.shared.preload(selectedModel)
                AppLog.info("Local LLM prewarm complete reason=settings_\(reason) model=\(selectedModel.repositoryID) ms=\(Self.milliseconds(since: startedAt))")
            } catch {
                AppLog.error("Local LLM prewarm failed reason=settings_\(reason) model=\(selectedModel.repositoryID) error=\(error.localizedDescription)")
            }
        }
    }

    private func validateLocalModel(_ selectedModel: LocalLLMModel) {
        guard selectedModel.isDownloaded,
              !validatingLocalModels.contains(selectedModel) else { return }
        validatingLocalModels.insert(selectedModel)
        dismissSettingsToast()
        let startedAt = ProcessInfo.processInfo.systemUptime

        Task {
            do {
                let result = try await LocalLLMPostProcessor.shared.correctedTextWithTrace(
                    for: "OK",
                    model: selectedModel,
                    requiresEnabled: false,
                    generationProfile: LocalLLMGenerationProfile(
                        reasoningMode: .disabled,
                        maxTokens: 8
                    ),
                    savePromptSnapshot: false
                )
                await MainActor.run {
                    validatingLocalModels.remove(selectedModel)
                    if Self.isFailedLocalValidationOutcome(result.metadata["outcome"]) {
                        let reason = result.metadata["error"] ?? result.metadata["reason"] ?? L10n.text(en: "Model response was not usable.", zh: "模型响应不可用。")
                        presentSettingsToast(L10n.text(en: "Local validation failed: \(reason)", zh: "本地验证失败：\(reason)"), kind: .error)
                    } else {
                        presentSettingsToast(
                            L10n.text(en: "Local model validated in \(Self.milliseconds(since: startedAt)) ms.", zh: "本地模型验证通过，耗时 \(Self.milliseconds(since: startedAt)) ms。"),
                            kind: .success
                        )
                    }
                    model.refreshLocalModelStatus()
                }
            } catch {
                await MainActor.run {
                    validatingLocalModels.remove(selectedModel)
                    presentSettingsToast(L10n.text(en: "Local validation failed: \(error.localizedDescription)", zh: "本地验证失败：\(error.localizedDescription)"), kind: .error)
                    model.refreshLocalModelStatus()
                }
            }
        }
    }

    private static func isFailedLocalValidationOutcome(_ outcome: String?) -> Bool {
        outcome == "failed" || outcome == "skipped" || outcome == "rejected"
    }

    private func presentSettingsToast(_ message: String, kind: SettingsToastKind) {
        let toast = SettingsToast(message: message, kind: kind)
        withAnimation(.easeOut(duration: 0.16)) {
            settingsToast = toast
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard settingsToast?.id == toast.id else { return }
            dismissSettingsToast()
        }
    }

    private func dismissSettingsToast() {
        withAnimation(.easeIn(duration: 0.14)) {
            settingsToast = nil
        }
    }

    private func selectFallbackModelIfNeeded(afterDeleting deletedModel: LocalLLMModel) {
        guard model.selectedLocalLLMModel == deletedModel else { return }

        if let fallbackModel = downloadedLocalModels.first {
            model.selectedLocalLLMModel = fallbackModel
            LocalLLMSettingsStore.selectedModel = fallbackModel
        } else if model.correctionBackend == .local {
            model.localPostProcessingEnabled = false
            CorrectionSettingsStore.postProcessingEnabled = false
        }
    }

    private var downloadedLocalModels: [LocalLLMModel] {
        LocalLLMModel.allCases.filter { $0.isDownloaded }
    }

    private func canDeleteLocalModel(_ selectedModel: LocalLLMModel) -> Bool {
        guard selectedModel.isHuggingFaceModel else { return false }
        return canDeleteLocalModel(
            selectedModel,
            isDownloaded: selectedModel.isDownloaded,
            isDownloading: downloadingLocalModels.contains(selectedModel),
            isDeleting: deletingLocalModels.contains(selectedModel),
            downloadedCount: downloadedLocalModels.count
        )
    }

    private func canDeleteLocalModel(
        _ selectedModel: LocalLLMModel,
        isDownloaded: Bool,
        isDownloading: Bool,
        isDeleting: Bool,
        downloadedCount: Int
    ) -> Bool {
        guard selectedModel.isHuggingFaceModel else { return false }
        guard isDownloaded,
              !isDownloading,
              !isDeleting
        else {
            return false
        }

        if model.correctionBackend == .local, model.localPostProcessingEnabled, downloadedCount <= 1 {
            return false
        }

        return true
    }

    private func deleteHelpText(for selectedModel: LocalLLMModel) -> String {
        guard selectedModel.isHuggingFaceModel else {
            return L10n.text(en: "Local folders are only removed from this list; files are not deleted.", zh: "本地文件夹只会从列表移除，不会删除文件。")
        }
        if model.correctionBackend == .local, model.localPostProcessingEnabled, downloadedLocalModels.count <= 1 {
            return L10n.text(en: "Turn off AI Post-processing or download another model before deleting this one.", zh: "删除前请先关闭 AI 后处理或下载另一个模型。")
        }
        return L10n.text(en: "Delete \(selectedModel.displayName) from the local Hugging Face cache.", zh: "从本地 Hugging Face 缓存删除 \(selectedModel.displayName)。")
    }

    private func downloadedModelAccessory(_ selectedModel: LocalLLMModel) -> some View {
        HStack(spacing: 2) {
            localModelValidationAccessory(selectedModel)

            Button {
                deleteLocalModel(selectedModel)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(canDeleteLocalModel(selectedModel) ? .secondary : .secondary.opacity(0.45))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!canDeleteLocalModel(selectedModel))
            .help(deleteHelpText(for: selectedModel))
        }
        .frame(width: Self.localModelPairAccessoryWidth, alignment: .leading)
    }

    private func localDirectoryModelAccessory(_ selectedModel: LocalLLMModel) -> some View {
        HStack(spacing: selectedModel.isDownloaded ? 2 : 6) {
            if !selectedModel.isDownloaded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 28, height: 28)
                    .help(L10n.text(en: "Local model folder is missing required files", zh: "本地模型文件夹缺少必要文件"))
            } else {
                localModelValidationAccessory(selectedModel)
            }

            Button {
                removeLocalModel(selectedModel)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Remove \(selectedModel.displayName) from the model list", zh: "从模型列表中移除 \(selectedModel.displayName)"))
        }
        .frame(width: selectedModel.isDownloaded ? Self.localModelPairAccessoryWidth : Self.localModelDirectoryAccessoryWidth, alignment: .leading)
    }

    @ViewBuilder
    private func localModelValidationAccessory(_ selectedModel: LocalLLMModel) -> some View {
        if validatingLocalModels.contains(selectedModel) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Button {
                validateLocalModel(selectedModel)
            } label: {
                Image(systemName: "speedometer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedModel.isDownloaded ? .secondary : .secondary.opacity(0.45))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!selectedModel.isDownloaded || validatingLocalModels.contains(selectedModel))
            .help(L10n.text(en: "Validate \(selectedModel.displayName)", zh: "验证 \(selectedModel.displayName)"))
        }
    }

    private var localModelDeletingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 28, height: 28)

            Text(L10n.text(en: "Deleting", zh: "删除中"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.localModelProgressTextWidth, alignment: .leading)
        }
        .frame(width: Self.localModelActivityAccessoryWidth, alignment: .leading)
    }

    private func downloadProgressView(progress: Double) -> some View {
        let normalizedProgress = min(max(progress, 0), 1)

        return ProgressView(value: normalizedProgress, total: 1)
            .progressViewStyle(.circular)
            .controlSize(.small)
            .frame(width: 28, height: 28)
            .frame(width: Self.localModelProgressAccessoryWidth, alignment: .leading)
    }

    private func compactStatusText(_ text: String, isHealthy: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(isHealthy ? .green : .orange)
    }

    private var correctionDebugBackendMenu: some View {
        Menu {
            Button {
                correctionDebugBackend = .remote
            } label: {
                correctionDebugMenuItem(
                    title: correctionDebugRemoteTitle,
                    isSelected: correctionDebugBackend == .remote
                )
            }

            Divider()

            ForEach(LocalLLMModel.allCases) { localModel in
                Button {
                    correctionDebugBackend = .local
                    correctionDebugModel = localModel
                } label: {
                    correctionDebugMenuItem(
                        title: localModel.displayName,
                        isSelected: correctionDebugBackend == .local && correctionDebugModel == localModel
                    )
                }
            }
        } label: {
            Text(correctionDebugSelectionTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            .font(.system(size: 12))
            .frame(width: 220, alignment: .leading)
        }
        .disabled(isRunningCorrectionDebug)
        .help(correctionDebugSelectionHelp)
    }

    @ViewBuilder
    private func correctionDebugMenuItem(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)

            Spacer(minLength: 16)

            Group {
                if isSelected {
                    Image(systemName: "checkmark")
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 12)
        }
    }

    private var correctionDebugSelectionTitle: String {
        switch correctionDebugBackend {
        case .local:
            return correctionDebugModel.displayName
        case .remote:
            return correctionDebugRemoteTitle
        }
    }

    private var correctionDebugRemoteTitle: String {
        guard let profile = model.selectedRemoteLLMProfile else {
            return L10n.text(en: "Remote", zh: "远端")
        }
        let remoteModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteModel.isEmpty else {
            return profile.displayName
        }
        return "\(profile.displayName) · \(remoteModel)"
    }

    private var correctionDebugSelectionBinding: Binding<CorrectionDebugSelection> {
        Binding(
            get: {
                switch correctionDebugBackend {
                case .remote:
                    return .remote
                case .local:
                    return .local(correctionDebugModel)
                }
            },
            set: { selection in
                switch selection {
                case .remote:
                    correctionDebugBackend = .remote
                case .local(let localModel):
                    correctionDebugBackend = .local
                    correctionDebugModel = localModel
                }
            }
        )
    }

    private var correctionDebugSelectionHelp: String {
        switch correctionDebugBackend {
        case .local:
            return correctionDebugModel.displayName
        case .remote:
            return model.selectedRemoteLLMProfile?.baseURL ?? ""
        }
    }

    private var correctionDebugSection: some View {
        VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
            HStack(spacing: 8) {
                settingsTitle(L10n.text(en: "Debug Model", zh: "调试模型"))

                Spacer(minLength: 8)

                if isRunningCorrectionDebug {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }

            settingsSection {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        correctionDebugBackendMenu

                        Spacer(minLength: 8)

                        Button(L10n.text(en: "Run", zh: "运行"), action: runCorrectionDebug)
                            .focusable(false)
                            .disabled(isRunningCorrectionDebug || correctionDebugInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(L10n.text(en: "Show in Finder", zh: "在 Finder 中显示"), action: locateCorrectionDebugTrace)
                            .focusable(false)
                            .disabled(correctionDebugTraceURL == nil)
                            .help(L10n.text(en: "Show the latest debug model trace in Finder.", zh: "在 Finder 中显示最新调试模型 trace。"))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    debugInputEditor

                    if !correctionDebugOutput.isEmpty {
                        HStack(spacing: 8) {
                            debugTextLabel(L10n.text(en: "AI Output", zh: "AI 输出"))

                            Spacer(minLength: 8)

                            if !correctionDebugDurationText.isEmpty {
                                Text(correctionDebugDurationText)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        debugOutputView
                    }

                    if let correctionDebugError {
                        Text(correctionDebugError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(3)
                    }

                }
                .padding(12)
            }
        }
    }

    private var diagnoseTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.settingsGroupSpacing) {
                settingsTitle(L10n.text(en: "System", zh: "系统"))

                settingsSection {
                    settingsListRow(L10n.text(en: "Accessibility", zh: "辅助功能"), height: 44) {
                        statusText(model.isKeyboardCaptureActive ? L10n.text(en: "Active", zh: "已启用") : L10n.text(en: "Needs Permission", zh: "需要授权"), isHealthy: model.isKeyboardCaptureActive)
                    }

                    if !model.isKeyboardCaptureActive {
                        settingsDivider()

                        settingsListRow(L10n.text(en: "Access", zh: "权限"), height: 44) {
                            Button(L10n.text(en: "Request Permission", zh: "请求权限"), action: onRequestAccessibility)
                                .focusable(false)
                        }
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "MLX Runtime", zh: "MLX 运行时"), height: 44) {
                        statusText(
                            model.mlxRuntimeDiagnostic.message,
                            isHealthy: model.mlxRuntimeDiagnostic.isAvailable
                        )
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Log", zh: "日志"), height: 44) {
                        HStack(spacing: 8) {
                            Button(L10n.text(en: "Open Log", zh: "打开日志"), action: onOpenLog)
                                .focusable(false)

                            Button(L10n.text(en: "Copy Log Path", zh: "复制日志路径"), action: onCopyLogPath)
                                .focusable(false)
                        }
                    }

                    settingsDivider()

                    settingsListRow(L10n.text(en: "Account", zh: "账号"), height: 44) {
                        Button(L10n.text(en: "Copy Login Debug Info", zh: "复制登录调试信息"), action: onCopyLoginDebugInfo)
                            .focusable(false)
                            .disabled(model.selectedASRProvider.usesWebASR && model.loginStatus != .loggedIn)
                            .help(L10n.text(en: "Copy redacted login state, cookie names, and local credential paths.", zh: "复制已脱敏的登录状态、cookie 名称和本地凭据路径。"))
                    }
                }

                if let error = model.keyboardCaptureError, !model.isKeyboardCaptureActive {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                }

                correctionDebugSection
            }
            .frame(width: Self.settingsGroupWidth, alignment: .topLeading)
        }
    }

    private var debugInputEditor: some View {
        ZStack(alignment: .topLeading) {
            HighlightedPromptTextEditor(text: $correctionDebugInput)
                .frame(height: 58)

            if correctionDebugInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.text(en: "Type to test AI output", zh: "输入文本测试 AI 输出"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var debugOutputView: some View {
        ScrollView {
            Text(correctionDebugOutput.isEmpty ? L10n.text(en: "No output yet.", zh: "还没有输出。") : correctionDebugOutput)
                .font(.system(size: 12))
                .foregroundColor(correctionDebugOutput.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(height: 56)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func debugTextLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func runCorrectionDebug() {
        let input = correctionDebugInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isRunningCorrectionDebug = true
        correctionDebugOutput = ""
        correctionDebugDurationText = ""
        correctionDebugError = nil
        correctionDebugTraceURL = nil
        let selectedBackend = correctionDebugBackend
        let selectedModel = correctionDebugModel

        Task {
            let startedAt = Date()
            let startedAtUptime = ProcessInfo.processInfo.systemUptime
            let result = try? await CorrectionPostProcessor.shared.correctedTextWithTrace(
                for: input,
                requiresEnabled: false,
                backend: selectedBackend,
                localModel: selectedModel
            )
            let traceURL = result.flatMap {
                Self.writeCorrectionDebugTrace(
                    result: $0,
                    input: input,
                    backend: selectedBackend,
                    model: selectedModel,
                    remoteConfiguration: RemoteLLMSettingsStore.currentConfiguration,
                    startedAt: startedAt,
                    durationMilliseconds: Self.milliseconds(since: startedAtUptime)
                )
            }
            await MainActor.run {
                isRunningCorrectionDebug = false
                guard let result else {
                    correctionDebugError = L10n.text(en: "AI post-processing failed without a usable result.", zh: "AI 后处理失败，没有可用结果。")
                    return
                }

                correctionDebugOutput = result.text
                correctionDebugDurationText = Self.formattedDebugDuration(result.timings)
                correctionDebugTraceURL = traceURL
                if traceURL == nil {
                    correctionDebugError = L10n.text(en: "AI post-processing completed, but trace file could not be written.", zh: "AI 后处理已完成，但 trace 文件写入失败。")
                }
            }
        }
    }

    private func locateCorrectionDebugTrace() {
        guard let correctionDebugTraceURL else { return }

        NSWorkspace.shared.activateFileViewerSelecting([correctionDebugTraceURL])
    }

    private static func formattedDebugDuration(_ timings: [TraceTiming]) -> String {
        let totalMilliseconds = timings.first { $0.name == "correction.total" }?.milliseconds
            ?? timings.map(\.milliseconds).reduce(0, +)
        guard totalMilliseconds > 0 else { return "" }
        return L10n.text(en: "Total \(totalMilliseconds) ms", zh: "总计 \(totalMilliseconds) ms")
    }

    private static func writeCorrectionDebugTrace(
        result: LocalLLMPostprocessResult,
        input: String,
        backend: CorrectionBackend,
        model: LocalLLMModel,
        remoteConfiguration: RemoteLLMConfiguration,
        startedAt: Date,
        durationMilliseconds: Int
    ) -> URL? {
        let payload: [String: Any] = [
            "trace_id": UUID().uuidString,
            "type": "correction_debug",
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "duration_ms": durationMilliseconds,
            "outcome": result.metadata["outcome"] ?? "unknown",
            "backend": backend.rawValue,
            "model": [
                "display_name": model.displayName,
                "repository_id": model.repositoryID,
                "downloaded": model.isDownloaded
            ],
            "remote": [
                "provider": remoteConfiguration.provider.rawValue,
                "base_url_host": URL(string: remoteConfiguration.baseURL)?.host ?? "",
                "model": remoteConfiguration.model,
                "configured": remoteConfiguration.isConfigured
            ],
            "raw_transcript": input,
            "corrected_output": result.text,
            "metadata": result.metadata,
            "prompts": [
                "system": result.debugInfo.systemPrompt ?? "",
                "user": result.debugInfo.userPrompt ?? ""
            ],
            "responses": [
                "raw": result.debugInfo.rawResponse ?? "",
                "cleaned": result.debugInfo.cleanedResponse ?? ""
            ],
            "timings": result.timings.map(debugPayload(for:))
        ]
        return TraceFileStore.write(payload: payload, prefix: "correction-debug")
    }

    private static func debugPayload(for timing: TraceTiming) -> [String: Any] {
        [
            "name": timing.name,
            "duration_ms": timing.milliseconds,
            "metadata": timing.metadata
        ]
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private var aboutTab: some View {
        VStack(spacing: 10) {
            Image(nsImage: Self.aboutIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .cornerRadius(14)
                .padding(.bottom, 4)

            Text("Douvo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Text("v\(model.appVersion)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Button(L10n.text(en: "Check for Updates...", zh: "检查更新..."), action: onCheckForUpdates)
                .focusable(false)
                .disabled(!model.canCheckForUpdates)
                .padding(.top, 8)

            Link(Self.repositoryURL.absoluteString, destination: Self.repositoryURL)
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static let repositoryURL = URL(string: "https://github.com/rhinoc/douvo")!
    private static var promptDocumentationURL: URL {
        URL(string: L10n.text(
            en: "https://github.com/rhinoc/douvo/blob/main/docs/advanced-prompts.md",
            zh: "https://github.com/rhinoc/douvo/blob/main/docs/advanced-prompts.zh.md"
        ))!
    }

    private func statusText(_ text: String, isHealthy: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(isHealthy ? .green : .orange)
    }

    private func aiRequiredLabel(_ title: String, isEnabled: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)

            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
                .overlay {
                    TooltipArea(text: L10n.text(en: "Requires AI to take effect.", zh: "需要启用 AI 才会生效。"))
                }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(isEnabled ? .primary : .secondary)
        .opacity(isEnabled ? 1 : Self.disabledFeatureOpacity)
        .contentShape(Rectangle())
        .help(L10n.text(en: "Requires AI to take effect.", zh: "需要启用 AI 才会生效。"))
    }

    private static var aboutIconImage: NSImage {
        if let url = Bundle.main.url(forResource: "Douvo", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        let developmentIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/Douvo.icns")
        if let image = NSImage(contentsOf: developmentIconURL) {
            return image
        }

        return NSApp.applicationIconImage
    }

    private func settingsTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func settingsDocumentationTitle(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)

            Link(destination: Self.promptDocumentationURL) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Open prompt documentation on GitHub", zh: "打开 GitHub 上的提示词说明文档"))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary)
    }

    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        return HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: Self.settingsLabelWidth, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func languageMenuPicker<Option: LanguageMenuOption>(
        selection: Binding<Option>,
        options: [Option],
        width: CGFloat
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { option in
                Text(option.menuTitle).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: width, alignment: .trailing)
    }

    private func settingsSection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsListRow<Content: View>(
        _ title: String,
        height: CGFloat? = 48,
        contentAlignment: Alignment = .trailing,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: Self.settingsRowLabelWidth, alignment: .leading)

            trailing()
                .frame(width: Self.settingsRowContentWidth, alignment: contentAlignment)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .padding(.vertical, height == nil ? 10 : 0)
    }

    private func correctionListRow<Content: View>(
        _ title: String,
        height: CGFloat? = 48,
        labelWidth: CGFloat = Self.correctionLabelWidth,
        contentAlignment: Alignment = .leading,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        correctionListRow(
            height: height,
            labelWidth: labelWidth,
            contentAlignment: contentAlignment,
            label: {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            },
            trailing: trailing
        )
    }

    private func correctionRowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
            .lineLimit(1)
    }

    private func correctionListRow<Label: View, Content: View>(
        height: CGFloat? = 48,
        labelWidth: CGFloat = Self.correctionLabelWidth,
        contentAlignment: Alignment = .leading,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        let contentWidth = Self.correctionRowContentWidth(labelWidth: labelWidth)

        let rowAlignment: VerticalAlignment = height == nil ? .top : .center
        let labelTopPadding: CGFloat = height == nil ? 4 : 0

        return HStack(alignment: rowAlignment, spacing: 12) {
            label()
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, labelTopPadding)

            trailing()
                .frame(width: contentWidth, alignment: contentAlignment)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .padding(.vertical, height == nil ? 10 : 0)
    }

    private func settingsDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 14)
            .padding(.trailing, 14)
    }

    private func compactSettingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: Self.settingsLabelWidth, alignment: .trailing)

            content()
                .frame(width: Self.settingsContentWidth, alignment: .leading)
        }
    }

    fileprivate static let panelWidth: CGFloat = 480
    fileprivate static let panelHeight: CGFloat = 440
    private static let settingsLabelWidth: CGFloat = 90
    private static let settingsContentWidth: CGFloat = 320
    private static let settingsGroupWidth: CGFloat = settingsLabelWidth + 12 + settingsContentWidth
    private static let settingsGroupSpacing: CGFloat = 10
    private static let settingsRowLabelWidth: CGFloat = 112
    private static let settingsRowContentWidth: CGFloat = settingsGroupWidth - 28 - 12 - settingsRowLabelWidth
    private static let correctionLabelWidth: CGFloat = 104
    private static let correctionContentWidth: CGFloat = settingsGroupWidth - 28 - 12 - correctionLabelWidth
    private static let localModelSingleAccessoryWidth: CGFloat = 28
    private static let localModelPairAccessoryWidth: CGFloat = 58
    private static let localModelDirectoryAccessoryWidth: CGFloat = 62
    private static let localModelProgressAccessoryWidth: CGFloat = 28
    private static let localModelActivityAccessoryWidth: CGFloat = 110
    private static let localModelProgressTextWidth: CGFloat = 76
    private static let disabledFeatureOpacity: CGFloat = 0.45

    private static func correctionRowContentWidth(labelWidth: CGFloat) -> CGFloat {
        settingsGroupWidth - 28 - 12 - labelWidth
    }
}

private struct SecureCredentialField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> FocusableSecureTextField {
        let textField = FocusableSecureTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.commit(_:))
        return textField
    }

    func updateNSView(_ textField: FocusableSecureTextField, context: Context) {
        context.coordinator.text = $text
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        private weak var activeTextField: NSTextField?
        private var keyMonitor: Any?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            activeTextField = textField
            installKeyMonitor()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text.wrappedValue = textField.stringValue
            }
            activeTextField = nil
            removeKeyMonitor()
        }

        @objc func commit(_ sender: NSTextField) {
            text.wrappedValue = sender.stringValue
        }

        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
        }

        private func removeKeyMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let textField = activeTextField,
                  textField.window?.firstResponder === textField.currentEditor(),
                  let editor = textField.currentEditor()
            else {
                return event
            }

            switch key {
            case "a":
                editor.selectAll(nil)
                return nil
            case "c":
                editor.copy(nil)
                return nil
            case "v":
                editor.paste(nil)
                text.wrappedValue = textField.stringValue
                return nil
            case "x":
                editor.cut(nil)
                text.wrappedValue = textField.stringValue
                return nil
            default:
                return event
            }
        }
    }
}

private final class FocusableSecureTextField: NSSecureTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if currentEditor() == nil {
            selectText(nil)
        }
    }
}

private struct TooltipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

private struct HighlightedPromptTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PromptScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true

        let textView = PromptTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        scrollView.documentView = textView
        context.coordinator.applyText(text, to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.applyText(text, to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var isApplyingHighlight = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingHighlight,
                  let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
            applyHighlighting(to: textView)
        }

        func applyText(_ newText: String, to textView: NSTextView) {
            guard textView.string != newText else {
                return
            }

            let selectedRanges = textView.selectedRanges
            isApplyingHighlight = true
            textView.string = newText
            restoreSelection(selectedRanges, in: textView)
            isApplyingHighlight = false
            applyHighlighting(to: textView)
        }

        private func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlight,
                  let textStorage = textView.textStorage else {
                return
            }

            let selectedRanges = textView.selectedRanges
            isApplyingHighlight = true

            textStorage.beginEditing()
            let fullRange = NSRange(location: 0, length: textStorage.length)
            if fullRange.length > 0 {
                textStorage.setAttributes(Self.baseAttributes, range: fullRange)
                highlightTemplateTags(in: textStorage)
            }
            textStorage.endEditing()

            textView.typingAttributes = Self.baseAttributes
            restoreSelection(selectedRanges, in: textView)
            isApplyingHighlight = false
        }

        private func highlightTemplateTags(in textStorage: NSTextStorage) {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            Self.variablePattern?.enumerateMatches(in: textStorage.string, range: fullRange) { result, _, _ in
                guard let range = result?.range else { return }
                textStorage.addAttributes(Self.variableAttributes, range: range)
            }
            Self.controlPattern?.enumerateMatches(in: textStorage.string, range: fullRange) { result, _, _ in
                guard let range = result?.range else { return }
                textStorage.addAttributes(Self.controlAttributes, range: range)
            }
        }

        private func restoreSelection(_ selectedRanges: [NSValue], in textView: NSTextView) {
            let maxLength = (textView.string as NSString).length
            let validRanges = selectedRanges.map { selectedRange in
                let range = selectedRange.rangeValue
                let location = min(range.location, maxLength)
                let length = min(range.length, max(0, maxLength - location))
                return NSValue(range: NSRange(location: location, length: length))
            }

            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
        }

        private static let variablePattern = try? NSRegularExpression(
            pattern: #"\{\{\s*(original|selected_text|translation_language|vocabularies|punctuation_style|punctuation_instruction|remove_filler_words|soften_emotional_language|output_style_instruction|environment_context|user_identity)\s*\}\}"#
        )

        private static let controlPattern = try? NSRegularExpression(
            pattern: #"\{\{\s*(#if\s+(original|selected_text|translation_language|vocabularies|punctuation_style|punctuation_instruction|remove_filler_words|soften_emotional_language|output_style_instruction|environment_context|user_identity)|else|/if)\s*\}\}"#
        )

        private static var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private static var variableAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12)
            ]
        }

        private static var controlAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemPurple,
                .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.10)
            ]
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let result = layout(subviews: subviews, maxWidth: maxWidth)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for placement in result.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(
        subviews: Subviews,
        maxWidth: CGFloat
    ) -> (placements: [Placement], size: CGSize) {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }

            placements.append(Placement(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x - spacing)
        }

        let contentHeight = placements.isEmpty ? 0 : y + rowHeight
        return (placements, CGSize(width: min(contentWidth, maxWidth), height: contentHeight))
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

private struct VocabularyChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.text(en: "Remove vocabulary", zh: "移除词条"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(maxWidth: 156)
        .frame(height: 24)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct ResizablePromptTextEditor: View {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isResizing: Bool
    let width: CGFloat
    let placeholder: String
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                HighlightedPromptTextEditor(text: $text)
                    .frame(height: height)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.58))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .frame(width: width, height: height, alignment: .topLeading)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }

            resizeHandle
        }
        .frame(width: width)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var resizeHandle: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.42))
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let startHeight = dragStartHeight ?? height
                    dragStartHeight = startHeight
                    if !isResizing {
                        isResizing = true
                    }

                    let nextHeight = Self.clampedHeight(startHeight + value.translation.height)
                    if abs(height - nextHeight) >= 1 {
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            height = nextHeight
                        }
                    }
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    isResizing = false
                }
        )
        .help(L10n.text(en: "Drag to resize", zh: "拖动调整大小"))
    }

    private static func clampedHeight(_ value: CGFloat) -> CGFloat {
        min(max(value.rounded(), 44), 520)
    }
}

private final class PromptScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard isEditingDocumentView,
              canScrollDocument(for: event) else {
            forwardScrollWheel(event)
            return
        }

        super.scrollWheel(with: event)
    }

    private var isEditingDocumentView: Bool {
        guard let firstResponder = window?.firstResponder else {
            return false
        }

        if firstResponder === documentView {
            return true
        }

        guard let responderView = firstResponder as? NSView else {
            return false
        }

        return responderView.isDescendant(of: self)
    }

    private func canScrollDocument(for event: NSEvent) -> Bool {
        guard let documentView else {
            return false
        }

        let visibleBounds = contentView.bounds
        let documentBounds = documentView.bounds
        let canScrollVertically = documentBounds.height > visibleBounds.height + 1
        let canScrollHorizontally = documentBounds.width > visibleBounds.width + 1
        let hasVerticalDelta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)

        return hasVerticalDelta ? canScrollVertically : canScrollHorizontally
    }

    private func forwardScrollWheel(_ event: NSEvent) {
        if let outerScrollView {
            outerScrollView.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private var outerScrollView: NSScrollView? {
        var currentView = superview
        while let view = currentView {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            currentView = view.superview
        }
        return nil
    }
}

private final class PromptTextView: NSTextView {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "z" where event.modifierFlags.contains(.shift):
            undoManager?.redo()
            return true
        case "z":
            undoManager?.undo()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
