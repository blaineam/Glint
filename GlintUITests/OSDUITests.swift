import XCTest

/// The OSD pill (OSDOverlay panel), shown at launch via GLINT_UITEST_OSD. In UI-test
/// mode it stays up for 30 s instead of 1.2 s so it can be read.
final class OSDUITests: GlintUITestCase {
    func testBrightnessPill() {
        launch(["GLINT_UITEST_OSD": "brightness:40"])
        waitForText(element("glint.osd.value"), "40")
        XCTAssertEqual(element("glint.osd.icon").label, "Brightness Higher")
    }

    func testMutedPill() {
        launch(["GLINT_UITEST_OSD": "mute"])
        waitForText(element("glint.osd.value"), "0")
        XCTAssertNotEqual(element("glint.osd.icon").label, "Brightness Higher")
    }
}
