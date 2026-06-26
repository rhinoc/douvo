import AppKit
import SwiftUI

@MainActor
final class ShortcutCapturePanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var model: SettingsPanelModel?
    private var onCapture: ((HotkeyShortcut) -> Void)?
    private var onCancel: (() -> Void)?
    private var isClosingFromCode = false

    func show(
        currentShortcut: HotkeyShortcut,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        logPath: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?,
        onCapture: @escaping (HotkeyShortcut) -> Void,
        onReset: @escaping () -> Void,
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
        self.onCancel = onCancel

        let model = SettingsPanelModel(
            shortcutName: currentShortcut.settingsDisplayName,
            resetShortcutName: HotkeyShortcut.defaultShortcut.settingsDisplayName,
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
            onReset: onReset,
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
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 380)

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

    func complete(with shortcut: HotkeyShortcut) {
        model?.shortcutName = shortcut.settingsDisplayName
        model?.isCapturingShortcut = false
        clearFocus()
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

    private func startLocalMonitor() {
        stopLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in
                    self.model?.isCapturingShortcut = false
                    self.stopLocalMonitor()
                    self.clearFocus()
                }
                return nil
            }

            guard let shortcut = HotkeyShortcut.from(event: event) else {
                return nil
            }

            Task { @MainActor in
                self.stopLocalMonitor()
                self.onCapture?(shortcut)
            }
            return nil
        }
    }

    private func stopLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
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
}

private final class SettingsPanelModel: ObservableObject {
    @Published var shortcutName: String
    @Published var loginStatus: LoginStatus
    let resetShortcutName: String
    @Published var isKeyboardCaptureActive: Bool
    @Published var keyboardCaptureError: String?
    @Published var isCapturingShortcut: Bool = false
    @Published var canCheckForUpdates: Bool = false
    let appVersion: String
    let logPath: String
    let microphoneDevices: [AudioInputDevice]
    @Published var selectedMicrophoneUID: String?

    init(
        shortcutName: String,
        resetShortcutName: String,
        loginStatus: LoginStatus,
        isKeyboardCaptureActive: Bool,
        keyboardCaptureError: String?,
        appVersion: String,
        logPath: String,
        microphoneDevices: [AudioInputDevice],
        selectedMicrophoneUID: String?
    ) {
        self.shortcutName = shortcutName
        self.resetShortcutName = resetShortcutName
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

private struct SettingsPanelView: View {
    @ObservedObject var model: SettingsPanelModel
    let onBeginCapture: () -> Void
    let onEndCapture: () -> Void
    let onReset: () -> Void
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
        .frame(width: 420, height: 380)
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
            model.isCapturingShortcut = false
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
            .frame(width: 82, height: 52)
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
            settingsRow("Trigger") {
                HStack(spacing: 8) {
                    Button {
                        model.isCapturingShortcut = true
                        onBeginCapture()
                    } label: {
                        Text(model.shortcutName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 178, height: 34)
                            .background(shortcutBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(model.isCapturingShortcut ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 2)
                            )
                            .accessibilityLabel("Current trigger key \(model.shortcutName)")
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Click to set trigger key")

                    Button {
                        model.isCapturingShortcut = false
                        onReset()
                        model.shortcutName = model.resetShortcutName
                        onEndCapture()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Reset trigger key")
                }
            }

            if model.isCapturingShortcut {
                Text("Press any key to update the trigger.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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

    private var shortcutBackground: Color {
        model.isCapturingShortcut ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08)
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
                Text(model.isLoggedIn ? "Logged in" : "Not logged in")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(model.isLoggedIn ? .primary : .secondary)
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
                Text(model.isKeyboardCaptureActive ? "Active" : "Needs Permission")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(model.isKeyboardCaptureActive ? .green : .orange)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
