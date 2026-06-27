import AppKit
import Foundation

final class HotkeyManager: @unchecked Sendable {
    enum HotkeyEvent {
        case toggleRecording
        case holdRecordingStarted
        case holdRecordingEnded
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    var onShortcutChanged: (() -> Void)?
    var onAvailabilityChanged: ((Bool, String?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetryCount = 30
    private var toggleTriggerDown = false
    private var holdTriggerDown = false
    private var toggleOtherKeyPressed = false
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.25
    private var shouldConsumeEscape = false
    private var isShortcutHandlingSuspended = false
    private(set) var isEventTapActive = false {
        didSet {
            if isEventTapActive != oldValue {
                onAvailabilityChanged?(isEventTapActive, lastEventTapError)
            }
        }
    }
    private(set) var lastEventTapError: String? {
        didSet {
            onAvailabilityChanged?(isEventTapActive, lastEventTapError)
        }
    }

    private(set) var toggleShortcut: HotkeyShortcut? {
        didSet {
            HotkeyShortcutStore.saveToggleShortcut(toggleShortcut)
            onShortcutChanged?()
        }
    }

    private(set) var holdShortcut: HotkeyShortcut? {
        didSet {
            HotkeyShortcutStore.saveHoldShortcut(holdShortcut)
            onShortcutChanged?()
        }
    }

    init() {
        toggleShortcut = HotkeyShortcutStore.loadToggleShortcut()
        holdShortcut = HotkeyShortcutStore.loadHoldShortcut()
        if let toggleShortcut, holdShortcut == toggleShortcut {
            AppLog.error("Hold shortcut duplicated toggle shortcut; clearing hold shortcut")
            holdShortcut = nil
            HotkeyShortcutStore.saveHoldShortcut(nil)
        }
        AppLog.info("HotkeyManager init toggleShortcut=\(toggleShortcut?.displayName ?? "none") holdShortcut=\(holdShortcut?.displayName ?? "none")")
        Self.requestAccessibilityPermission()
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        if eventTap != nil {
            AppLog.info("Hotkey event tap already active")
            return
        }

        if tryCreateEventTap() {
            retryTimer?.invalidate()
            retryTimer = nil
            retryCount = 0
            return
        }

        Self.requestAccessibilityPermission()
        startRetryTimer()
    }

    private func tryCreateEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isEventTapActive = false
            lastEventTapError = "Accessibility permission is not active"
            AppLog.error("Hotkey event tap creation failed; accessibility permission is not active")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = true
        lastEventTapError = nil
        AppLog.info("Hotkey event tap active toggleShortcut=\(toggleShortcut?.displayName ?? "none") holdShortcut=\(holdShortcut?.displayName ?? "none")")
        return true
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryCount = 0
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            self.retryCount += 1
            if self.tryCreateEventTap() {
                timer.invalidate()
                self.retryTimer = nil
                self.retryCount = 0
                return
            }

            if self.retryCount >= self.maxRetryCount {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    func setEscapeHandlingEnabled(_ enabled: Bool) {
        shouldConsumeEscape = enabled
    }

    func setShortcutHandlingSuspended(_ suspended: Bool) {
        guard isShortcutHandlingSuspended != suspended else { return }
        isShortcutHandlingSuspended = suspended
        resetPressedState()
        AppLog.info("Hotkey shortcut handling suspended=\(suspended)")
    }

    @discardableResult
    func resetShortcutToDefault() -> Bool {
        setToggleShortcut(.defaultShortcut)
    }

    @discardableResult
    func resetHoldShortcutToDefault() -> Bool {
        setHoldShortcut(.defaultHoldShortcut)
    }

    @discardableResult
    func setToggleShortcut(_ shortcut: HotkeyShortcut) -> Bool {
        guard shortcut != holdShortcut else {
            AppLog.error("Rejected duplicate toggle shortcut \(shortcut.displayName)")
            return false
        }
        toggleShortcut = shortcut
        resetPressedState()
        AppLog.info("Toggle shortcut set to \(shortcut.displayName) keyCode=\(shortcut.keyCode)")
        return true
    }

    func clearToggleShortcut() {
        toggleShortcut = nil
        resetPressedState()
        AppLog.info("Toggle shortcut cleared")
    }

    @discardableResult
    func setHoldShortcut(_ shortcut: HotkeyShortcut) -> Bool {
        guard shortcut != toggleShortcut else {
            AppLog.error("Rejected duplicate hold shortcut \(shortcut.displayName)")
            return false
        }
        holdShortcut = shortcut
        resetPressedState()
        AppLog.info("Hold shortcut set to \(shortcut.displayName) keyCode=\(shortcut.keyCode)")
        return true
    }

    func clearHoldShortcut() {
        holdShortcut = nil
        resetPressedState()
        AppLog.info("Hold shortcut cleared")
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLog.error("Hotkey event tap disabled by system; re-enabling type=\(type.rawValue)")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if isShortcutHandlingSuspended {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            return handleKeyDown(event)
        }

        if type == .keyUp {
            return handleKeyUp(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }

        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if toggleTriggerDown, let toggleShortcut, keyCode != toggleShortcut.keyCode {
            toggleOtherKeyPressed = true
        }

        if keyCode == 53, shouldConsumeEscape {
            onHotkeyEvent?(.cancel)
            return nil
        }

        if let holdShortcut, !holdShortcut.isModifier, keyCode == holdShortcut.keyCode {
            if !holdTriggerDown {
                holdTriggerDown = true
                AppLog.info("Hold shortcut down shortcut=\(holdShortcut.displayName)")
                onHotkeyEvent?(.holdRecordingStarted)
            }
            return nil
        }

        guard let toggleShortcut, !toggleShortcut.isModifier, keyCode == toggleShortcut.keyCode else {
            return Unmanaged.passRetained(event)
        }

        if !toggleTriggerDown {
            toggleTriggerDown = true
            toggleOtherKeyPressed = false
        }
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if let holdShortcut, !holdShortcut.isModifier, keyCode == holdShortcut.keyCode, holdTriggerDown {
            holdTriggerDown = false
            AppLog.info("Hold shortcut up shortcut=\(holdShortcut.displayName)")
            onHotkeyEvent?(.holdRecordingEnded)
            return nil
        }

        guard let toggleShortcut, !toggleShortcut.isModifier, keyCode == toggleShortcut.keyCode, toggleTriggerDown else {
            return Unmanaged.passRetained(event)
        }

        toggleTriggerDown = false
        fireToggleIfCleanPress()
        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if let holdShortcut, holdShortcut.isModifier, keyCode == holdShortcut.keyCode {
            let isDown = holdShortcut.flagIsDown(in: event.flags)
            if isDown, !holdTriggerDown {
                holdTriggerDown = true
                AppLog.info("Hold shortcut down shortcut=\(holdShortcut.displayName)")
                onHotkeyEvent?(.holdRecordingStarted)
                return nil
            }

            if !isDown, holdTriggerDown {
                holdTriggerDown = false
                AppLog.info("Hold shortcut up shortcut=\(holdShortcut.displayName)")
                onHotkeyEvent?(.holdRecordingEnded)
                return nil
            }

            return nil
        }

        guard let toggleShortcut, toggleShortcut.isModifier, keyCode == toggleShortcut.keyCode else {
            return Unmanaged.passRetained(event)
        }

        let isDown = toggleShortcut.flagIsDown(in: event.flags)
        if isDown, !toggleTriggerDown {
            toggleTriggerDown = true
            toggleOtherKeyPressed = false
            return nil
        }

        if !isDown, toggleTriggerDown {
            toggleTriggerDown = false
            fireToggleIfCleanPress()
            return nil
        }

        return nil
    }

    private func fireToggleIfCleanPress() {
        guard let toggleShortcut else { return }
        guard !toggleOtherKeyPressed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleTime > debounceInterval {
            lastToggleTime = now
            guard let onHotkeyEvent else {
                AppLog.error("Hotkey toggle dropped: no handler shortcut=\(toggleShortcut.displayName)")
                return
            }
            AppLog.info("Hotkey toggle fired shortcut=\(toggleShortcut.displayName) handler=true")
            onHotkeyEvent(.toggleRecording)
        }
    }

    private func resetPressedState() {
        toggleTriggerDown = false
        holdTriggerDown = false
        toggleOtherKeyPressed = false
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type, event)
}
