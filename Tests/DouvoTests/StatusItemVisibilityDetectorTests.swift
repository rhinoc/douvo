import AppKit
import XCTest
@testable import Douvo

final class StatusItemVisibilityDetectorTests: XCTestCase {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let rightOfNotch = NSRect(x: 982, y: 1085, width: 746, height: 32)

    func testVisibilityAlertIsShownByDefault() {
        let suiteName = "StatusItemVisibilityDetectorTests.default"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertTrue(StatusItemVisibilityAlertStore.shouldShowAlert(defaults: defaults))
    }

    func testVisibilityAlertCanBeSuppressedPersistently() {
        let suiteName = "StatusItemVisibilityDetectorTests.suppressed"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        StatusItemVisibilityAlertStore.suppressAlert(defaults: defaults)

        XCTAssertFalse(StatusItemVisibilityAlertStore.shouldShowAlert(defaults: defaults))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSpeakingShortcutsIncludeToggleAndHoldInSettingsOrder() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.speakingShortcuts(
                toggleShortcut: .defaultShortcut,
                holdShortcut: .defaultHoldShortcut
            ),
            [.defaultShortcut, .defaultHoldShortcut]
        )
    }

    func testSpeakingShortcutsIncludeOnlyConfiguredShortcut() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.speakingShortcuts(
                toggleShortcut: nil,
                holdShortcut: .defaultHoldShortcut
            ),
            [.defaultHoldShortcut]
        )
    }

    func testSpeakingShortcutsAreEmptyWhenBothAreUnconfigured() {
        XCTAssertTrue(
            StatusItemVisibilityAlertContent.speakingShortcuts(
                toggleShortcut: nil,
                holdShortcut: nil
            ).isEmpty
        )
    }

    func testItemInsideRightOfNotchIsVisible() {
        let itemFrame = NSRect(x: 1650, y: 1088, width: 24, height: 24)

        XCTAssertFalse(StatusItemVisibilityDetector.isLikelyObscured(
            itemFrame: itemFrame,
            screenFrame: screenFrame,
            auxiliaryTopRightArea: rightOfNotch
        ))
    }

    func testItemIntersectingNotchIsLikelyObscured() {
        let itemFrame = NSRect(x: 970, y: 1088, width: 24, height: 24)

        XCTAssertTrue(StatusItemVisibilityDetector.isLikelyObscured(
            itemFrame: itemFrame,
            screenFrame: screenFrame,
            auxiliaryTopRightArea: rightOfNotch
        ))
    }

    func testItemOutsideScreenIsLikelyObscuredWithoutNotch() {
        let itemFrame = NSRect(x: -24, y: 1088, width: 24, height: 24)

        XCTAssertTrue(StatusItemVisibilityDetector.isLikelyObscured(
            itemFrame: itemFrame,
            screenFrame: screenFrame,
            auxiliaryTopRightArea: nil
        ))
    }

    func testLaidOutItemIsVisibleWithoutNotch() {
        let itemFrame = NSRect(x: 1650, y: 1088, width: 24, height: 24)

        XCTAssertFalse(StatusItemVisibilityDetector.isLikelyObscured(
            itemFrame: itemFrame,
            screenFrame: screenFrame,
            auxiliaryTopRightArea: nil
        ))
    }

    func testChineseAlertContentIncludesActiveShortcuts() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.title(language: .simplifiedChinese),
            "Douvo 图标可能被隐藏"
        )
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.informativeText(
                shortcutNames: ["右 Option", "Fn"],
                language: .simplifiedChinese
            ),
            "检测到菜单栏空间不足，请整理菜单栏图标以恢复显示。\n说话快捷键（右 Option、Fn）不受影响。"
        )
    }

    func testEnglishAlertContentIncludesActiveShortcuts() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.title(language: .english),
            "Douvo icon may be hidden"
        )
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.informativeText(
                shortcutNames: ["Right Option", "Fn"],
                language: .english
            ),
            "Not enough menu bar space was detected. Rearrange menu bar icons to restore Douvo.\nSpeaking shortcuts (Right Option, Fn) are unaffected."
        )
    }

    func testEnglishAlertContentUsesSingularForOneSpeakingShortcut() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.informativeText(
                shortcutNames: ["Fn"],
                language: .english
            ),
            "Not enough menu bar space was detected. Rearrange menu bar icons to restore Douvo.\nThe speaking shortcut (Fn) is unaffected."
        )
    }

    func testAlertContentReportsWhenNoSpeakingShortcutIsActive() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.informativeText(
                shortcutNames: [],
                language: .simplifiedChinese
            ),
            "检测到菜单栏空间不足，请整理菜单栏图标以恢复显示。\n当前未设置有效快捷键。"
        )
    }

    func testEnglishAlertContentReportsWhenNoSpeakingShortcutIsActive() {
        XCTAssertEqual(
            StatusItemVisibilityAlertContent.informativeText(
                shortcutNames: [],
                language: .english
            ),
            "Not enough menu bar space was detected. Rearrange menu bar icons to restore Douvo.\nNo valid speaking shortcut is currently configured."
        )
    }
}
