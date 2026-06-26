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
        currentToggleShortcut: HotkeyShortcut,
        currentHoldShortcut: HotkeyShortcut?,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        logPath: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?,
        onCapture: @escaping (HotkeyShortcutSlot, HotkeyShortcut) -> Bool,
        onCaptureStateChanged: @escaping (Bool) -> Void,
        onResetToggle: @escaping () -> Void,
        onClearHold: @escaping () -> Void,
        onSelectMicrophone: @escaping (String?) -> Void,
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
            toggleShortcutName: currentToggleShortcut.settingsDisplayName,
            holdShortcutName: Self.holdShortcutName(currentHoldShortcut),
            resetToggleShortcutName: HotkeyShortcut.defaultShortcut.settingsDisplayName,
            loginStatus: loginStatus,
            isKeyboardCaptureActive: isKeyboardCaptureActive,
            keyboardCaptureError: keyboardCaptureError,
            appVersion: appVersion,
            logPath: logPath,
            microphoneDevices: microphoneDevices,
            selectedMicrophoneUID: selectedMicrophoneUID
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
            onClearHold: onClearHold,
            onSelectMicrophone: onSelectMicrophone,
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
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 420)

        if panel == nil {
            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Settings"
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
            model?.toggleShortcutName = shortcut.settingsDisplayName
        case .hold:
            model?.holdShortcutName = shortcut.settingsDisplayName
        }
        model?.capturingShortcut = nil
        model?.shortcutErrorMessage = nil
        clearFocus()
    }

    func showShortcutConflict(for slot: HotkeyShortcutSlot) {
        model?.capturingShortcut = nil
        switch slot {
        case .toggle:
            model?.shortcutErrorMessage = "Short press and hold-to-talk must use different keys."
        case .hold:
            model?.shortcutErrorMessage = "Hold-to-talk and short press must use different keys."
        }
        clearFocus()
    }

    func refreshShortcuts(toggleShortcut: HotkeyShortcut, holdShortcut: HotkeyShortcut?) {
        model?.toggleShortcutName = toggleShortcut.settingsDisplayName
        model?.holdShortcutName = Self.holdShortcutName(holdShortcut)
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

    private static func holdShortcutName(_ shortcut: HotkeyShortcut?) -> String {
        shortcut?.settingsDisplayName ?? "Not Set"
    }
}

private final class SettingsPanelModel: ObservableObject {
    @Published var toggleShortcutName: String
    @Published var holdShortcutName: String
    @Published var loginStatus: LoginStatus
    let resetToggleShortcutName: String
    @Published var isKeyboardCaptureActive: Bool
    @Published var keyboardCaptureError: String?
    @Published var capturingShortcut: HotkeyShortcutSlot?
    @Published var shortcutErrorMessage: String?
    @Published var canCheckForUpdates: Bool = false
    let appVersion: String
    let logPath: String
    let microphoneDevices: [AudioInputDevice]
    @Published var selectedMicrophoneUID: String?

    init(
        toggleShortcutName: String,
        holdShortcutName: String,
        resetToggleShortcutName: String,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        logPath: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?
    ) {
        self.toggleShortcutName = toggleShortcutName
        self.holdShortcutName = holdShortcutName
        self.resetToggleShortcutName = resetToggleShortcutName
        self.loginStatus = loginStatus
        self.isKeyboardCaptureActive = isKeyboardCaptureActive
        self.keyboardCaptureError = keyboardCaptureError
        self.appVersion = appVersion
        self.logPath = logPath
        self.microphoneDevices = microphoneDevices
        self.selectedMicrophoneUID = selectedMicrophoneUID
    }

    var isLoggedIn: Bool {
        loginStatus == .loggedIn
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case account = "Account"
    case diagnose = "Diagnose"
    case about = "About"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general:
            return "keyboard"
        case .account:
            return "person.crop.circle"
        case .diagnose:
            return "wrench.and.screwdriver"
        case .about:
            return "info.circle"
        }
    }
}

private extension HotkeyShortcutSlot {
    var accessibilityName: String {
        switch self {
        case .toggle:
            return "Short press"
        case .hold:
            return "Hold-to-talk"
        }
    }

    var helpName: String {
        switch self {
        case .toggle:
            return "short press"
        case .hold:
            return "hold-to-talk"
        }
    }
}

private struct SettingsPanelView: View {
    @ObservedObject var model: SettingsPanelModel
    let onBeginCapture: () -> Void
    let onEndCapture: () -> Void
    let onResetToggle: () -> Void
    let onClearHold: () -> Void
    let onSelectMicrophone: (String?) -> Void
    let onLogin: () -> Void
    let onLogout: () -> Void
    let onCopyLoginDebugInfo: () -> Void
    let onRepairLogin: () -> Void
    let onCopyLogPath: () -> Void
    let onOpenLog: () -> Void
    let onCheckForUpdates: () -> Void
    let onRequestAccessibility: () -> Void
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.top, 12)
                .padding(.horizontal, 18)

            Divider()
                .padding(.top, 12)

            tabContent
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 460, height: 420)
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
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
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(selectedTab == tab ? .primary : .secondary)
            .frame(width: 90, height: 52)
            .background(tabBackground(for: tab), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func tabBackground(for tab: SettingsTab) -> Color {
        selectedTab == tab ? Color.secondary.opacity(0.16) : Color.clear
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .account:
            accountTab
        case .diagnose:
            diagnoseTab
        case .about:
            aboutTab
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsRow("Short Press") {
                shortcutButtons(
                    slot: .toggle,
                    name: model.toggleShortcutName,
                    resetIcon: "arrow.counterclockwise",
                    resetHelp: "Reset short press key",
                    onReset: {
                        model.capturingShortcut = nil
                        model.shortcutErrorMessage = nil
                        onResetToggle()
                        model.toggleShortcutName = model.resetToggleShortcutName
                        onEndCapture()
                    }
                )
            }

            settingsRow("Hold") {
                shortcutButtons(
                    slot: .hold,
                    name: model.holdShortcutName,
                    resetIcon: "xmark",
                    resetHelp: "Clear hold-to-talk key",
                    onReset: {
                        model.capturingShortcut = nil
                        model.shortcutErrorMessage = nil
                        onClearHold()
                        model.holdShortcutName = "Not Set"
                        onEndCapture()
                    }
                )
            }

            if let message = shortcutStatusText {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(model.shortcutErrorMessage == nil ? .secondary : .red)
                    .padding(.leading, 112)
            }

            settingsRow("Microphone") {
                Picker("", selection: microphoneBinding) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.microphoneDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 240, alignment: .leading)
            }
        }
    }

    private func shortcutButtons(
        slot: HotkeyShortcutSlot,
        name: String,
        resetIcon: String,
        resetHelp: String,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                model.capturingShortcut = slot
                model.shortcutErrorMessage = nil
                onBeginCapture()
            } label: {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 178, height: 34)
                    .background(shortcutBackground(for: slot), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(model.capturingShortcut == slot ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 2)
                    )
                    .accessibilityLabel("\(slot.accessibilityName) key \(name)")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Click to set \(slot.helpName) key")

            Button(action: onReset) {
                Image(systemName: resetIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help(resetHelp)
        }
    }

    private func shortcutBackground(for slot: HotkeyShortcutSlot) -> Color {
        model.capturingShortcut == slot ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08)
    }

    private var shortcutStatusText: String? {
        if let shortcutErrorMessage = model.shortcutErrorMessage {
            return shortcutErrorMessage
        }

        guard let capturingShortcut = model.capturingShortcut else {
            return nil
        }
        return "Press any key to update \(capturingShortcut.helpName)."
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

    private var accountTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsRow("Status") {
                statusText(model.isLoggedIn ? "Logged in" : "Not logged in", isHealthy: model.isLoggedIn)
            }

            settingsRow("Account") {
                if model.isLoggedIn {
                    HStack(spacing: 8) {
                        Button("Refresh Credentials", action: onRepairLogin)
                            .focusable(false)

                        Button("Log Out") {
                            onLogout()
                            model.loginStatus = .notLoggedIn
                        }
                        .focusable(false)
                    }
                } else {
                    Button("Log In", action: onLogin)
                        .focusable(false)
                }
            }

            settingsRow("Debug") {
                Button("Copy Login Debug Info", action: onCopyLoginDebugInfo)
                    .focusable(false)
                    .disabled(!model.isLoggedIn)
                    .help("Copy redacted login state, cookie names, and local credential paths.")
            }
        }
    }

    private var diagnoseTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsRow("Keyboard") {
                statusText(model.isKeyboardCaptureActive ? "Active" : "Needs Permission", isHealthy: model.isKeyboardCaptureActive)
            }

            if !model.isKeyboardCaptureActive {
                settingsRow("Permission") {
                    Button("Request Permission", action: onRequestAccessibility)
                        .focusable(false)
                }
            }

            if let error = model.keyboardCaptureError, !model.isKeyboardCaptureActive {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 112)
            }

            settingsRow("Log") {
                HStack(spacing: 8) {
                    Button("Open Log", action: onOpenLog)
                        .focusable(false)

                    Button("Copy Log Path", action: onCopyLogPath)
                        .focusable(false)
                }
            }

            Text(model.logPath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 112)
        }
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

            Text("Version \(model.appVersion)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Button("Check for Updates...", action: onCheckForUpdates)
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

    private func statusText(_ text: String, isHealthy: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isHealthy ? .green : .orange)
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

    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
