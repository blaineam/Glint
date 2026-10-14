import AppKit
import XCTest
@testable import Glint

/// The app delegate's launch and reopen routing. Under XCTest `applicationDidFinishLaunching`
/// deliberately does nothing (no status item, no event tap, no alert), so these tests drive
/// the reopen path with a throwaway Preferences and a settings controller that never shows.
@MainActor
final class AppDelegateTests: XCTestCase {
    private var prefs: Preferences!
    private var settings: SettingsWindowController!
    private var delegate: AppDelegate!

    override func setUp() async throws {
        try await super.setUp()
        (prefs, _) = makePreferences()
        settings = SettingsWindowController(presentsWindow: false)
        delegate = AppDelegate(preferences: prefs, settings: settings)
    }

    func testLaunchUnderXCTestInstallsNothing() {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNil(settings.window)
    }

    func testReopenInInvisibleModeOpensSettings() {
        prefs.hideMenuBarIcon = true
        XCTAssertNil(settings.window)
        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertFalse(handled, "AppKit must not also open its own window")
        XCTAssertNotNil(settings.window)
        XCTAssertEqual(settings.window?.title, "Glint Settings")
    }

    func testReopenWithAMenuBarIconDoesNotOpenSettings() {
        prefs.hideMenuBarIcon = false
        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertFalse(handled)
        XCTAssertNil(settings.window, "with the icon showing, reopen toggles the popover instead")
    }

    func testMenuBarVisibilityNotificationNameIsStable() {
        XCTAssertEqual(Notification.Name.glintMenuBarVisibilityChanged.rawValue, "glintMenuBarVisibilityChanged")
    }
}
