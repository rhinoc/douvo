import AppKit
import ApplicationServices
import Foundation

enum PromptEnvironmentContext {
    static func current() -> String {
        var lines: [String] = []

        if LocalLLMSettingsStore.includeCurrentTimeContext {
            lines.append(contentsOf: currentTimeLines())
        }

        if LocalLLMSettingsStore.includeFrontmostAppContext {
            lines.append(contentsOf: frontmostAppLines())
        }

        return lines.joined(separator: "\n")
    }

    private static func currentTimeLines() -> [String] {
        let now = Date()
        let timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"

        return [
            "current_time: \(formatter.string(from: now))",
            "weekday: \(weekdayFormatter.string(from: now))",
            "timezone: \(timeZone.identifier)"
        ]
    }

    private static func frontmostAppLines() -> [String] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return []
        }

        var lines: [String] = []
        if let appName = sanitized(app.localizedName) {
            lines.append("frontmost_app: \(appName)")
        }

        if LocalLLMSettingsStore.includeWindowTitleContext,
           let windowTitle = frontmostWindowTitle(for: app),
           let sanitizedTitle = sanitized(windowTitle) {
            lines.append("window_title: \(sanitizedTitle)")
        }

        return lines
    }

    private static func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard focusedResult == .success,
              let window = focusedWindow else {
            return nil
        }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard titleResult == .success else {
            return nil
        }

        return titleValue as? String
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(160))
    }
}
