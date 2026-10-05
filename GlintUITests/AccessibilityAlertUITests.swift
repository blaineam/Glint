import XCTest

/// The launch-time Accessibility alert (shown when the event tap can't be created).
final class AccessibilityAlertUITests: GlintUITestCase {
    private var alert: XCUIElement { app.dialogs.firstMatch }

    private func launchWithAlert() {
        launch(["GLINT_UITEST_ACCESSIBILITY": "denied", "GLINT_UITEST_SHOW_ACCESSIBILITY_ALERT": "1"],
               waitForHarness: false)
        let title = app.staticTexts["Accessibility Access Required"]
        XCTAssertTrue(title.appears(timeout: Self.timeout), "Accessibility alert did not appear")
        XCTAssertTrue(app.buttons["Open System Settings"].exists)
        XCTAssertTrue(app.buttons["Later"].exists)
    }

    func testLaterDismissesAlertAndShowsInactiveStatus() {
        launchWithAlert()
        app.buttons["Later"].click()
        XCTAssertTrue(harness.appears(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Accessibility Access Required"].exists)
        waitForText(element("glint.menu.status", in: harness), "Not active")
        waitForText(element("glint.uitest.lastOpenedURL", in: harness), "-")
    }

    func testOpenSystemSettingsGoesToAccessibilityPane() {
        launchWithAlert()
        app.buttons["Open System Settings"].click()
        XCTAssertTrue(harness.appears(timeout: Self.timeout))
        waitForText(element("glint.uitest.lastOpenedURL", in: harness),
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}
