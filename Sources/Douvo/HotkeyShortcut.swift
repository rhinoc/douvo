import AppKit
import CoreGraphics
import Foundation

struct HotkeyShortcut: Codable, Equatable {
    enum Kind: String, Codable {
        case modifier
        case regular
    }

    let keyCode: Int64
    let kind: Kind
    let flagMask: UInt64
    let displayName: String

    static let defaultShortcut = HotkeyShortcut(
        keyCode: 61,
        kind: .modifier,
        flagMask: CGEventFlags.maskAlternate.rawValue,
        displayName: "Right Option"
    )

    static let defaultHoldShortcut = HotkeyShortcut(
        keyCode: 63,
        kind: .modifier,
        flagMask: 0x800000,
        displayName: "Fn"
    )

    var isModifier: Bool {
        kind == .modifier
    }

    var compactDisplayName: String {
        switch displayName {
        case "Left Command", "Right Command":
            return "⌘"
        case "Left Option", "Right Option":
            return "⌥"
        case "Left Control", "Right Control":
            return "⌃"
        case "Left Shift", "Right Shift":
            return "⇧"
        case "Left Arrow":
            return "←"
        case "Right Arrow":
            return "→"
        case "Up Arrow":
            return "↑"
        case "Down Arrow":
            return "↓"
        default:
            return displayName
        }
    }

    var settingsDisplayName: String {
        guard isModifier else { return displayName }
        let symbol = compactDisplayName
        guard symbol != displayName else { return displayName }
        return "\(displayName) \(symbol)"
    }

    func flagIsDown(in flags: CGEventFlags) -> Bool {
        flagMask != 0 && (flags.rawValue & flagMask) != 0
    }

    static func from(event: CGEvent, type: CGEventType) -> HotkeyShortcut? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, let modifier = modifierShortcut(for: keyCode) {
            return modifier
        }

        if type == .keyDown {
            return regularShortcut(for: keyCode)
        }

        return nil
    }

    static func from(event: NSEvent) -> HotkeyShortcut? {
        let keyCode = Int64(event.keyCode)
        if event.type == .flagsChanged, let modifier = modifierShortcut(for: keyCode) {
            return modifier
        }

        if event.type == .keyDown {
            return regularShortcut(for: keyCode)
        }

        return nil
    }

    static func modifierShortcut(for keyCode: Int64) -> HotkeyShortcut? {
        switch keyCode {
        case 54:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskCommand.rawValue, displayName: "Right Command")
        case 55:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskCommand.rawValue, displayName: "Left Command")
        case 56:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskShift.rawValue, displayName: "Left Shift")
        case 58:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskAlternate.rawValue, displayName: "Left Option")
        case 59:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskControl.rawValue, displayName: "Left Control")
        case 60:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskShift.rawValue, displayName: "Right Shift")
        case 61:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskAlternate.rawValue, displayName: "Right Option")
        case 62:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: CGEventFlags.maskControl.rawValue, displayName: "Right Control")
        case 63:
            return HotkeyShortcut(keyCode: keyCode, kind: .modifier, flagMask: 0x800000, displayName: "Fn")
        default:
            return nil
        }
    }

    static func regularShortcut(for keyCode: Int64) -> HotkeyShortcut {
        HotkeyShortcut(keyCode: keyCode, kind: .regular, flagMask: 0, displayName: regularKeyName(for: keyCode))
    }

    private static func regularKeyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Escape", 64: "F17", 65: "Keypad .",
            67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
            76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0",
            83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
            87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8",
            92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "Left Arrow",
            124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

enum HotkeyShortcutSlot {
    case toggle
    case hold
}

enum HotkeyShortcutStore {
    private static let toggleKey = "triggerShortcut"
    private static let toggleDisabledKey = "triggerShortcutDisabled"
    private static let holdKey = "holdTriggerShortcut"

    static func loadToggleShortcut() -> HotkeyShortcut? {
        if UserDefaults.standard.bool(forKey: toggleDisabledKey) {
            return nil
        }

        guard let data = UserDefaults.standard.data(forKey: toggleKey),
              let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) else {
            return .defaultShortcut
        }
        return shortcut
    }

    static func saveToggleShortcut(_ shortcut: HotkeyShortcut?) {
        guard let shortcut else {
            UserDefaults.standard.set(true, forKey: toggleDisabledKey)
            UserDefaults.standard.removeObject(forKey: toggleKey)
            return
        }

        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(false, forKey: toggleDisabledKey)
        UserDefaults.standard.set(data, forKey: toggleKey)
    }

    static func loadHoldShortcut() -> HotkeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: holdKey) else {
            return nil
        }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    static func saveHoldShortcut(_ shortcut: HotkeyShortcut?) {
        guard let shortcut else {
            UserDefaults.standard.removeObject(forKey: holdKey)
            return
        }

        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: holdKey)
    }
}
