import AppKit

enum StatusItemVisibilityDetector {
    @MainActor
    static func frameInScreenCoordinates(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    static func isLikelyObscured(
        itemFrame: NSRect,
        screenFrame: NSRect,
        auxiliaryTopRightArea: NSRect?
    ) -> Bool {
        guard itemFrame.width > 0, itemFrame.height > 0 else { return false }
        guard NSContainsRect(screenFrame.insetBy(dx: -1, dy: -1), itemFrame) else { return true }
        guard let auxiliaryTopRightArea else { return false }
        return !NSContainsRect(auxiliaryTopRightArea.insetBy(dx: -1, dy: -1), itemFrame)
    }
}

enum StatusItemVisibilityAlertContent {
    static func title(language: AppLanguage = AppLanguageStore.selected) -> String {
        switch language {
        case .english:
            "Douvo icon may be hidden"
        case .simplifiedChinese:
            "Douvo 图标可能被隐藏"
        }
    }

    static func informativeText(
        shortcutNames: [String],
        language: AppLanguage = AppLanguageStore.selected
    ) -> String {
        let baseText: String
        switch language {
        case .english:
            baseText = "Not enough menu bar space was detected. Rearrange menu bar icons to restore Douvo."
        case .simplifiedChinese:
            baseText = "检测到菜单栏空间不足，请整理菜单栏图标以恢复显示。"
        }

        guard !shortcutNames.isEmpty else { return baseText }
        let separator = language == .simplifiedChinese ? "、" : ", "
        let names = shortcutNames.joined(separator: separator)
        let shortcutText = switch language {
        case .english:
            "Keyboard shortcuts (\(names)) are unaffected."
        case .simplifiedChinese:
            "快捷键（\(names)）不受影响。"
        }
        return "\(baseText)\n\(shortcutText)"
    }
}
