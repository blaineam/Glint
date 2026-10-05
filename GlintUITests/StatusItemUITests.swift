import AppKit
import XCTest

/// The real NSStatusItem, its popover, invisible mode and app reopen.
final class StatusItemUITests: GlintUITestCase {
    private var statusItem: XCUIElement { app.statusItems["glint.statusItem"] }
    private var popover: XCUIElement { app.popovers.firstMatch }

    func testStatusItemOpensPopoverWithDisplays() {
        launch()
        XCTAssertTrue(statusItem.appears(timeout: Self.timeout))
        statusItem.click()
        XCTAssertTrue(popover.appears(timeout: Self.timeout))
        waitForText(display(Self.monitorA, "name", in: popover), "Glint Test Monitor A")
        waitForText(display(Self.monitorA, "brightnessValue", in: popover), "60%")
        waitForText(element("glint.menu.status", in: popover), "Intercepting keys")

        // Clicking the item again closes it.
        statusItem.click()
        XCTAssertTrue(popover.disappears(timeout: Self.timeout))
    }

    func testReopenWithIconShowsPopover() {
        launch()
        XCTAssertTrue(statusItem.appears(timeout: Self.timeout))
        element("glint.uitest.reopen", in: harness).click()
        XCTAssertTrue(popover.appears(timeout: Self.timeout))
        XCTAssertTrue(element("glint.menu.settings", in: popover).exists)
    }

    func testHideMenuBarIconRemovesAndRestoresStatusItem() {
        launch()
        XCTAssertTrue(statusItem.appears(timeout: Self.timeout))
        openSettings()
        flip(settings("hideMenuBarIcon"))
        XCTAssertTrue(statusItem.disappears(timeout: Self.timeout))
        flip(settings("hideMenuBarIcon"))
        XCTAssertTrue(statusItem.appears(timeout: Self.timeout))
    }

    /// Invisible mode: no status item, and opening Glint again (a real LaunchServices
    /// reopen of the running app) goes straight to Settings.
    func testReopenInInvisibleModeOpensSettings() throws {
        launch(["GLINT_UITEST_HIDE_ICON": "1", "GLINT_UITEST_NO_HARNESS": "1"], waitForHarness: false)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.timeout) || app.state == .runningForeground)
        XCTAssertFalse(statusItem.exists)
        XCTAssertFalse(settingsWindow.exists)

        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.blainemiller.Glint.debug")
            .first { $0.bundleURL?.path.contains("/Build/Products/") == true })
        let bundleURL = try XCTUnwrap(running.bundleURL)
        let opened = expectation(description: "reopen delivered")
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: Self.timeout)

        XCTAssertTrue(settingsWindow.appears(timeout: Self.timeout))
        waitForToggle(settings("hideMenuBarIcon"), on: true)
        XCTAssertFalse(statusItem.exists)
    }
}
