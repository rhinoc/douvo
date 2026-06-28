import AppKit
import SwiftUI
import XCTest
@testable import Douvo

@MainActor
final class AppMenuTests: XCTestCase {
    func testMainMenuIncludesQuitCommandKeyEquivalent() {
        let menu = AppMenuFactory.makeMainMenu(
            settingsAction: nil,
            quitAction: #selector(NSApplication.terminate(_:))
        )

        let appMenu = menu.items.first?.submenu
        let quitItem = appMenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) }

        XCTAssertEqual(quitItem?.keyEquivalent, "q")
        XCTAssertEqual(quitItem?.keyEquivalentModifierMask, .command)
    }

    func testMainMenuSettingsTitleDoesNotUseEllipsis() {
        let menu = AppMenuFactory.makeMainMenu(
            settingsAction: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            quitAction: #selector(NSApplication.terminate(_:))
        )

        let appMenu = menu.items.first?.submenu
        let settingsItem = appMenu?.items.first {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        }

        XCTAssertFalse(settingsItem?.title.contains("...") ?? true)
        XCTAssertFalse(settingsItem?.title.contains("…") ?? true)
    }

    func testMainMenuIncludesStandardAppAndEditItems() {
        let menu = AppMenuFactory.makeMainMenu(
            settingsAction: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            quitAction: #selector(NSApplication.terminate(_:))
        )

        let appMenu = menu.items.first?.submenu
        XCTAssertNotNil(appMenu?.items.first { $0.action == #selector(NSApplication.hide(_:)) })
        XCTAssertNotNil(appMenu?.items.first { $0.action == #selector(NSApplication.hideOtherApplications(_:)) })
        XCTAssertNotNil(appMenu?.items.first { $0.action == #selector(NSApplication.unhideAllApplications(_:)) })

        let editMenu = menu.items.dropFirst().first?.submenu
        XCTAssertNotNil(editMenu?.items.first { $0.action == #selector(NSText.copy(_:)) })
        XCTAssertNotNil(editMenu?.items.first { $0.action == #selector(NSText.paste(_:)) })
        XCTAssertNotNil(editMenu?.items.first { $0.action == #selector(NSText.selectAll(_:)) })
    }

    func testStatusMenuActionTitlesDoNotUseEllipsis() {
        let menu = NSMenu()

        AppDelegate.rebuildStatusMenu(
            menu,
            provider: .web,
            loginStatus: .loggedIn,
            lastTranscript: "",
            canCheckForUpdates: true,
            target: nil
        )

        let settingsItem = menu.items.first { $0.action == NSSelectorFromString("showSettings") }
        let updateItem = menu.items.first { $0.action == NSSelectorFromString("checkForUpdates") }

        XCTAssertFalse(settingsItem?.title.contains("...") ?? true)
        XCTAssertFalse(settingsItem?.title.contains("…") ?? true)
        XCTAssertFalse(updateItem?.title.contains("...") ?? true)
        XCTAssertFalse(updateItem?.title.contains("…") ?? true)
    }

    func testSettingsHostingViewAcceptsFirstMouse() {
        let hostingView = SettingsHostingView(rootView: Text("Settings"))

        XCTAssertTrue(hostingView.acceptsFirstMouse(for: nil))
    }

    func testSettingsWindowActivatesBeforeInactiveFirstMouse() {
        XCTAssertTrue(
            SettingsPanelWindow.shouldActivateBeforeHandlingMouseDown(
                eventType: .leftMouseDown,
                isKeyWindow: false,
                isAppActive: true
            )
        )
        XCTAssertTrue(
            SettingsPanelWindow.shouldActivateBeforeHandlingMouseDown(
                eventType: .leftMouseDown,
                isKeyWindow: true,
                isAppActive: false
            )
        )
        XCTAssertFalse(
            SettingsPanelWindow.shouldActivateBeforeHandlingMouseDown(
                eventType: .leftMouseDown,
                isKeyWindow: true,
                isAppActive: true
            )
        )
        XCTAssertFalse(
            SettingsPanelWindow.shouldActivateBeforeHandlingMouseDown(
                eventType: .keyDown,
                isKeyWindow: false,
                isAppActive: false
            )
        )
    }

    func testLocalModelAccessoryColumnsStayCompactOutsideDownloadingState() {
        XCTAssertLessThanOrEqual(SettingsPanelLayoutMetrics.localModelActionColumnWidth, 64)
        XCTAssertEqual(
            SettingsPanelLayoutMetrics.localModelDownloadAccessoryWidth,
            SettingsPanelLayoutMetrics.localModelActionColumnWidth
        )
    }
}
