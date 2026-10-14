import AppKit
import SwiftUI
import XCTest
@testable import Glint

/// The pill built, positioned and timed exactly as in the app, but never ordered onto a
/// real screen (`presentsWindow: false`).
@MainActor
final class OSDOverlayPresentationTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testShowBuildsTheBorderlessPanelOnceAndReusesIt() throws {
        let overlay = OSDOverlay(presentsWindow: false, hideDelay: .seconds(30))
        XCTAssertNil(overlay.window)
        XCTAssertFalse(overlay.isVisible)

        overlay.show(icon: "sun.max.fill", value: 40)
        let panel = try XCTUnwrap(overlay.window)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.accessibilityIdentifier(), "glint.osd")
        XCTAssertEqual(panel.frame.size, NSSize(width: 200, height: 28))
        XCTAssertFalse(panel.isVisible, "tests never order the pill onto a real screen")

        overlay.show(icon: "speaker.wave.2.fill", value: 80)
        XCTAssertTrue(overlay.window === panel, "the same panel is reused for the next key press")
    }

    func testPillIsPositionedBelowTheMenuBarOfTheTargetScreen() throws {
        guard let screen = NSScreen.screens.first else { return }   // headless runner: nothing to place on
        let overlay = OSDOverlay(presentsWindow: false, hideDelay: .seconds(30))
        overlay.show(icon: "sun.max.fill", value: 10, on: screen)
        let origin = try XCTUnwrap(overlay.window).frame.origin
        let expected = OSDOverlay.pillOrigin(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame, pillSize: NSSize(width: 200, height: 28)
        )
        XCTAssertEqual(origin.x, expected.x, accuracy: 0.5)
        XCTAssertEqual(origin.y, expected.y, accuracy: 0.5)
    }

    func testPillFadesOutAfterTheHideDelay() {
        let overlay = OSDOverlay(presentsWindow: false, hideDelay: .milliseconds(20))
        overlay.show(icon: "sun.max.fill", value: 55)
        XCTAssertTrue(overlay.isVisible)
        waitUntil { !overlay.isVisible }
        XCTAssertFalse(overlay.isVisible)
    }

    func testAnotherKeyPressRestartsTheHideTimer() {
        let overlay = OSDOverlay(presentsWindow: false, hideDelay: .milliseconds(400))
        overlay.show(icon: "sun.max.fill", value: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        overlay.show(icon: "sun.max.fill", value: 20)       // cancels the first timer
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(overlay.isVisible, "the first timer was cancelled, so 0.5 s after it began the pill is still up")
        waitUntil { !overlay.isVisible }
        XCTAssertFalse(overlay.isVisible)
    }

    func testPillViewRendersAtEveryFillLevel() {
        for value in [0, 1, 50, 100] {
            let host = OffscreenHost(OSDPillView(icon: "sun.max.fill", value: value).background(Color.gray), size: NSSize(width: 200, height: 28))
            XCTAssertEqual(host.hostingView.fittingSize.width, 200, accuracy: 0.5)
            XCTAssertEqual(host.hostingView.fittingSize.height, 28, accuracy: 0.5)
        }
    }
}
