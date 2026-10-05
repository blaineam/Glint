import AppKit
import XCTest

/// Launches Glint in its DEBUG-only `-UITestMode` (fixture monitors, stubbed
/// Accessibility, throwaway defaults, no event tap) and gives tests small helpers.
///
/// The fixture: "Glint Test Monitor A" (id 101) answers DDC with brightness 60 % and
/// volume 30 %; "Glint Test Monitor B" (id 102) answers no DDC reads (N/A) but accepts
/// writes. The built-in display and speakers sit at 50 %.
@MainActor
class GlintUITestCase: XCTestCase {
    var app: XCUIApplication!

    static let monitorA = 101
    static let monitorB = 102
    static let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
    }

    /// Launches with the given fixture environment. Pinned to English so labels and the
    /// percent formatting ("6.25%") are deterministic.
    func launch(_ environment: [String: String] = [:], waitForHarness: Bool = true) {
        app.launchArguments = ["-UITestMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = environment
        app.launch()
        if waitForHarness {
            XCTAssertTrue(harness.appears(timeout: Self.timeout), "UI-test harness window did not open")
        }
    }

    /// The "Glint Menu (UI Test)" window: the popover's MenuBarView plus simulated media keys.
    var harness: XCUIElement { app.windows["Glint Menu (UI Test)"] }
    var settingsWindow: XCUIElement { app.windows["Glint Settings"] }
    var supportWindow: XCUIElement { app.windows["Support Glint"] }

    /// Any element under `root` with the accessibility identifier `id`.
    func element(_ id: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func display(_ id: Int, _ part: String, in root: XCUIElement? = nil) -> XCUIElement {
        element("glint.display.\(id).\(part)", in: root ?? harness)
    }

    /// Text shown by a static text (its value on macOS; falls back to the label).
    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Waits until `element`'s text equals `expected`.
    func waitForText(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = GlintUITestCase.timeout,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(timeout: timeout), "\(element) missing", file: file, line: line)
        if text(of: element) == expected { return }
        let predicate = NSPredicate { [unowned self] _, _ in self.text(of: element) == expected }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected \"\(expected)\", got \"\(text(of: element))\"", file: file, line: line)
    }

    /// Waits until `condition` holds.
    func waitUntil(_ description: String, timeout: TimeInterval = GlintUITestCase.timeout,
                   file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, description, file: file, line: line)
    }

    /// Percent shown by a "NN%" label.
    func percent(_ element: XCUIElement) -> Int? {
        Int(text(of: element).replacingOccurrences(of: "%", with: ""))
    }

    /// A toggle's on/off state.
    func isOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber { return number.boolValue }
        if let string = element.value as? String { return string == "1" || string.lowercased() == "on" }
        return false
    }

    func waitForToggle(_ element: XCUIElement, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(timeout: Self.timeout), "\(element) missing", file: file, line: line)
        waitUntil("toggle \(element.identifier) should be \(on ? "on" : "off")", file: file, line: line) { [unowned self] in
            self.isOn(element) == on
        }
    }

    /// Opens Settings from the harness menu and returns its window.
    @discardableResult
    func openSettings() -> XCUIElement {
        element("glint.menu.settings", in: harness).click()
        XCTAssertTrue(settingsWindow.appears(timeout: Self.timeout), "Settings window did not open")
        // The menu's Settings… button calls NSApp.deactivate() right after showing the
        // window (to dismiss the popover), so the window can end up behind another app's
        // window and its controls aren't hittable. Bring Glint back to the front.
        app.activate()
        return settingsWindow
    }

    func settings(_ id: String) -> XCUIElement {
        element("glint.settings.\(id)", in: settingsWindow)
    }

    /// Scrolls the Settings form until `element` is fully on screen (much faster than
    /// letting XCUITest scroll it into view on click, and independent of where the
    /// window opened).
    func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(), "\(element) missing", file: file, line: line)
        let scrollView = settingsWindow.scrollViews.firstMatch
        for _ in 0..<12 {
            let visible = scrollView.frame.insetBy(dx: 0, dy: 8)
            let frame = element.frame
            if visible.contains(frame) { return }
            scrollView.scroll(byDeltaX: 0, deltaY: frame.midY > visible.midY ? -120 : 120)
        }
        XCTFail("could not scroll \(element) into view", file: file, line: line)
    }

    /// Clicks a toggle and waits for it to flip.
    func flip(_ toggle: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(toggle.appears(timeout: Self.timeout), "\(toggle) missing", file: file, line: line)
        if settingsWindow.exists { reveal(toggle, file: file, line: line) }
        let wasOn = isOn(toggle)
        toggle.click()
        waitForToggle(toggle, on: !wasOn, file: file, line: line)
    }

    /// Picks `option` (e.g. "10%") from a pop-up picker.
    func choose(_ option: String, in picker: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(picker.appears(timeout: Self.timeout), "\(picker) missing", file: file, line: line)
        if settingsWindow.exists { reveal(picker, file: file, line: line) }
        picker.click()
        let item = app.menuItems[option]
        XCTAssertTrue(item.appears(timeout: Self.timeout), "menu item \(option) missing", file: file, line: line)
        item.click()
        waitForText(picker, option, file: file, line: line)
    }

    func waitForTermination(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .notRunning, timeout: Self.timeout), "Glint did not quit", file: file, line: line)
    }
}

extension XCUIElement {
    /// `waitForExistence` that returns at once when the element is already there
    /// (waitForExistence itself always polls for about a second).
    func appears(timeout: TimeInterval = GlintUITestCase.timeout) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }

    /// `waitForNonExistence` that returns at once when the element is already gone.
    func disappears(timeout: TimeInterval = GlintUITestCase.timeout) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }
}
