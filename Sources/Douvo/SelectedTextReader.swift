import AppKit
import ApplicationServices
import Foundation

enum SelectedTextReadResult: Equatable {
    case none
    case text(String)
    case tooLong
}

enum SelectedTextReader {
    static let maxSelectionCharacters = 500
    private static let copyFallbackDelay: TimeInterval = 0.08

    static func currentSelection(maxCharacters: Int = maxSelectionCharacters) -> SelectedTextReadResult {
        let axTrusted = AXIsProcessTrusted()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            AppLog.info("Selection edit read result=none reason=no_frontmost_app axTrusted=\(axTrusted)")
            return .none
        }

        let appName = app.localizedName ?? "unknown"
        let bundleIdentifier = app.bundleIdentifier ?? "unknown"
        AppLog.info(
            "Selection edit read start app=\(logValue(appName)) bundle=\(logValue(bundleIdentifier)) pid=\(app.processIdentifier) axTrusted=\(axTrusted)"
        )

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedResult = focusedUIElement(in: appElement)
        guard let focusedElement = focusedResult.element else {
            AppLog.info(
                "Selection edit read result=none reason=focused_element_unavailable focusedAX=\(focusedResult.axErrorDescription) focusedType=\(focusedResult.valueTypeDescription)"
            )
            return copyFallbackSelection(maxCharacters: maxCharacters, reason: "focused_element_unavailable")
        }

        let role = attributeString(kAXRoleAttribute, in: focusedElement) ?? "unknown"
        let subrole = attributeString(kAXSubroleAttribute, in: focusedElement) ?? "unknown"
        let selectedResult = selectedText(in: focusedElement)
        guard selectedResult.axError == .success else {
            AppLog.info(
                "Selection edit read result=none reason=selected_text_unavailable selectedAX=\(selectedResult.axErrorDescription) role=\(logValue(role)) subrole=\(logValue(subrole))"
            )
            return copyFallbackSelection(maxCharacters: maxCharacters, reason: "selected_text_unavailable")
        }

        let result = validate(selectedResult.text, maxCharacters: maxCharacters)
        switch result {
        case .none:
            AppLog.info(
                "Selection edit read result=none reason=empty_selected_text role=\(logValue(role)) subrole=\(logValue(subrole))"
            )
            return copyFallbackSelection(maxCharacters: maxCharacters, reason: "empty_selected_text")
        case .tooLong:
            AppLog.info(
                "Selection edit read result=too_long selectedChars=\(selectedResult.text?.count ?? 0) maxChars=\(maxCharacters) role=\(logValue(role)) subrole=\(logValue(subrole))"
            )
        case .text(let text):
            AppLog.info(
                "Selection edit read result=text selectedChars=\(text.count) role=\(logValue(role)) subrole=\(logValue(subrole))"
            )
        }
        return result
    }

    static func validate(_ text: String?, maxCharacters: Int = maxSelectionCharacters) -> SelectedTextReadResult {
        guard let text else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard trimmed.count <= maxCharacters else { return .tooLong }
        return .text(trimmed)
    }

    private struct FocusedElementResult {
        let element: AXUIElement?
        let axError: AXError
        let valueTypeDescription: String

        var axErrorDescription: String {
            SelectedTextReader.axErrorDescription(axError)
        }
    }

    private struct SelectedTextResult {
        let text: String?
        let axError: AXError

        var axErrorDescription: String {
            SelectedTextReader.axErrorDescription(axError)
        }
    }

    private struct PasteboardSnapshot {
        let changeCount: Int
        let items: [PasteboardItemSnapshot]
    }

    private struct PasteboardItemSnapshot {
        let values: [(type: NSPasteboard.PasteboardType, value: Any)]
    }

    private static func copyFallbackSelection(
        maxCharacters: Int,
        reason: String
    ) -> SelectedTextReadResult {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboardSnapshot(from: pasteboard)
        AppLog.info(
            "Selection edit copy fallback start reason=\(reason) previousChangeCount=\(snapshot.changeCount) previousItems=\(snapshot.items.count)"
        )

        postCommandC()
        RunLoop.current.run(until: Date().addingTimeInterval(copyFallbackDelay))

        let copiedChangeCount = pasteboard.changeCount
        guard copiedChangeCount != snapshot.changeCount else {
            AppLog.info("Selection edit copy fallback result=none reason=clipboard_unchanged")
            return .none
        }

        let copiedText = pasteboard.string(forType: .string)
        let result = validate(copiedText, maxCharacters: maxCharacters)
        restorePasteboard(snapshot, to: pasteboard)

        switch result {
        case .none:
            AppLog.info(
                "Selection edit copy fallback result=none reason=empty_copied_text copiedChangeCount=\(copiedChangeCount)"
            )
        case .tooLong:
            AppLog.info(
                "Selection edit copy fallback result=too_long copiedChars=\(copiedText?.count ?? 0) maxChars=\(maxCharacters) copiedChangeCount=\(copiedChangeCount)"
            )
        case .text(let text):
            AppLog.info(
                "Selection edit copy fallback result=text selectedChars=\(text.count) copiedChangeCount=\(copiedChangeCount)"
            )
        }
        return result
    }

    private static func pasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let itemSnapshots = (pasteboard.pasteboardItems ?? []).map { item in
            let values = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, value: Any)? in
                guard let value = item.propertyList(forType: type) else { return nil }
                return (type, value)
            }
            return PasteboardItemSnapshot(values: values)
        }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: itemSnapshots)
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for value in snapshotItem.values {
                item.setPropertyList(value.value, forType: value.type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
        AppLog.info("Selection edit copy fallback restored clipboard previousChangeCount=\(snapshot.changeCount)")
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func focusedUIElement(in appElement: AXUIElement) -> FocusedElementResult {
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard result == .success,
              let focusedValue else {
            return FocusedElementResult(
                element: nil,
                axError: result,
                valueTypeDescription: focusedValue.map(typeDescription) ?? "nil"
            )
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return FocusedElementResult(
                element: nil,
                axError: result,
                valueTypeDescription: typeDescription(focusedValue)
            )
        }
        return FocusedElementResult(
            element: (focusedValue as! AXUIElement),
            axError: result,
            valueTypeDescription: "AXUIElement"
        )
    }

    private static func selectedText(in element: AXUIElement) -> SelectedTextResult {
        var selectedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard result == .success else {
            return SelectedTextResult(text: nil, axError: result)
        }
        return SelectedTextResult(text: selectedValue as? String, axError: result)
    }

    private static func attributeString(_ attribute: String, in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func axErrorDescription(_ error: AXError) -> String {
        switch error {
        case .success:
            "success"
        case .failure:
            "failure"
        case .illegalArgument:
            "illegal_argument"
        case .invalidUIElement:
            "invalid_ui_element"
        case .invalidUIElementObserver:
            "invalid_ui_element_observer"
        case .cannotComplete:
            "cannot_complete"
        case .attributeUnsupported:
            "attribute_unsupported"
        case .actionUnsupported:
            "action_unsupported"
        case .notificationUnsupported:
            "notification_unsupported"
        case .notImplemented:
            "not_implemented"
        case .notificationAlreadyRegistered:
            "notification_already_registered"
        case .notificationNotRegistered:
            "notification_not_registered"
        case .apiDisabled:
            "api_disabled"
        case .noValue:
            "no_value"
        case .parameterizedAttributeUnsupported:
            "parameterized_attribute_unsupported"
        case .notEnoughPrecision:
            "not_enough_precision"
        @unknown default:
            "unknown_\(error.rawValue)"
        }
    }

    private static func typeDescription(_ value: CFTypeRef) -> String {
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return "String"
        }
        if typeID == AXUIElementGetTypeID() {
            return "AXUIElement"
        }
        if typeID == CFArrayGetTypeID() {
            return "Array"
        }
        if typeID == CFBooleanGetTypeID() {
            return "Bool"
        }
        if typeID == CFNumberGetTypeID() {
            return "Number"
        }
        return "CFType(\(typeID))"
    }

    private static func logValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }
}
