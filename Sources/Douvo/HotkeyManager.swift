import AppKit
import Foundation

final class HotkeyManager: @unchecked Sendable {
    enum HotkeyEvent {
        case toggleRecording
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onAvailabilityChanged: ((Bool, String?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetryCount = 30
    private var triggerDown = false
    private var otherKeyPressed = false
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.25
    private var shouldConsumeEscape = false
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

    private(set) var shortcut: HotkeyShortcut {
        didSet {
            HotkeyShortcutStore.save(shortcut)
            onShortcutChanged?(shortcut)
        }
    }

    init() {
        shortcut = HotkeyShortcutStore.load()
        AppLog.info("HotkeyManager init shortcut=\(shortcut.displayName)")
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
        AppLog.info("Hotkey event tap active shortcut=\(shortcut.displayName)")
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

    func resetShortcutToDefault() {
        setShortcut(.defaultShortcut)
    }

    func setShortcut(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        triggerDown = false
        otherKeyPressed = false
        AppLog.info("Trigger shortcut set to \(shortcut.displayName) keyCode=\(shortcut.keyCode)")
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLog.error("Hotkey event tap disabled by system; re-enabling type=\(type.rawValue)")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
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
        if triggerDown, keyCode != shortcut.keyCode {
            otherKeyPressed = true
        }

        if keyCode == 53, shouldConsumeEscape {
            onHotkeyEvent?(.cancel)
            return nil
        }

        guard !shortcut.isModifier, keyCode == shortcut.keyCode else {
            return Unmanaged.passRetained(event)
        }

        if !triggerDown {
            triggerDown = true
            otherKeyPressed = false
        }
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard !shortcut.isModifier, keyCode == shortcut.keyCode, triggerDown else {
            return Unmanaged.passRetained(event)
        }

        triggerDown = false
        fireToggleIfCleanPress()
        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard shortcut.isModifier, keyCode == shortcut.keyCode else {
            return Unmanaged.passRetained(event)
        }

        let isDown = shortcut.flagIsDown(in: event.flags)
        if isDown, !triggerDown {
            triggerDown = true
            otherKeyPressed = false
            return nil
        }

        if !isDown, triggerDown {
            triggerDown = false
            fireToggleIfCleanPress()
            return nil
        }

        return nil
    }

    private func fireToggleIfCleanPress() {
        guard !otherKeyPressed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleTime > debounceInterval {
            lastToggleTime = now
            AppLog.info("Hotkey toggle fired shortcut=\(shortcut.displayName)")
            onHotkeyEvent?(.toggleRecording)
        }
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
