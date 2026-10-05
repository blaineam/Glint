import XCTest

/// The Support window (SupportWindowController → MillerKit SupportWindowContent).
final class SupportWindowUITests: GlintUITestCase {
    func testSupportWindowOpensFromMenuOnce() {
        launch()
        element("glint.menu.support", in: harness).click()
        XCTAssertTrue(supportWindow.appears(timeout: Self.timeout))
        app.activate() // Support… deactivates Glint too (see openSettings()).
        XCTAssertTrue(supportWindow.buttons["Report an Issue"].appears(timeout: Self.timeout))
        XCTAssertTrue(supportWindow.buttons["Ask a Question"].exists)

        // A second click re-fronts the same window.
        element("glint.menu.support", in: harness).click()
        XCTAssertTrue(supportWindow.appears(timeout: Self.timeout))
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == %@", "Support Glint")).count, 1)
        app.activate()

        XCTAssertTrue(supportWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'My Other Apps'")).firstMatch.exists)
        supportWindow.buttons["Suggest a Feature"].click()
        waitUntil("Suggest a Feature should compose a mailto: URL") { [unowned self] in
            self.text(of: self.element("glint.uitest.lastOpenedURL", in: self.harness)).hasPrefix("mailto:")
        }
    }
}
