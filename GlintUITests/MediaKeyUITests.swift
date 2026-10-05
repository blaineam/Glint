import XCTest

/// Media keys routed exactly as the event tap routes them (DisplayManager + OSD), driven
/// by the harness's simulated keys: XCUITest cannot synthesize NX_SYSDEFINED events.
/// "Sync with built-in" is on by default, so a key adjusts every DDC monitor together
/// with the built-in display / Mac speakers (both at 50 % in the fixture).
final class MediaKeyUITests: GlintUITestCase {
    private var osdValue: XCUIElement { element("glint.osd.value") }

    private func press(_ key: String) {
        element("glint.uitest.key.\(key)", in: harness).click()
    }

    func testBrightnessUpStepsMonitorAndShowsOSD() {
        launch()
        waitForText(display(Self.monitorA, "brightnessValue"), "60%")
        press("brightnessUp")
        // Default step 6.25 % of 100 → 6.
        waitForText(display(Self.monitorA, "brightnessValue"), "66%")
        waitForText(osdValue, "66")

        press("brightnessDown")
        waitForText(display(Self.monitorA, "brightnessValue"), "60%")
        waitForText(osdValue, "60")
    }

    func testVolumeUpSyncsToSystemVolumeThenSteps() {
        launch()
        waitForText(display(Self.monitorA, "volumeValue"), "30%")
        press("volumeUp")
        // First key press syncs the monitor to the system volume (50 %), then steps 6.
        waitForText(display(Self.monitorA, "volumeValue"), "56%")
        // Audio goes to the built-in speakers, so the OSD shows the system volume.
        waitForText(osdValue, "56")
    }

    func testMuteSilencesMonitorAndShowsZero() {
        launch()
        waitForText(display(Self.monitorA, "volumeValue"), "30%")
        press("mute")
        waitForText(display(Self.monitorA, "volumeValue"), "0%")
        waitForText(osdValue, "0")

        // Unmute restores the volume the monitor had before muting.
        press("mute")
        waitForText(display(Self.monitorA, "volumeValue"), "30%")
    }

    func testLargerBrightnessStepFromSettings() {
        launch()
        openSettings()
        choose("10%", in: settings("brightnessStep"))
        settingsWindow.buttons["_XCUI:CloseWindow"].click()

        press("brightnessUp")
        waitForText(display(Self.monitorA, "brightnessValue"), "70%")
    }

    func testBrightnessKeysPassThroughWhenNotIntercepted() {
        launch()
        openSettings()
        flip(settings("interceptBrightness"))
        settingsWindow.buttons["_XCUI:CloseWindow"].click()

        // Brightness is now left to macOS; volume is still Glint's. Keys are handled
        // in order on one queue, so once the volume OSD shows, the brightness key has
        // already been (not) handled.
        press("brightnessUp")
        press("volumeUp")
        waitForText(osdValue, "56")
        waitForText(display(Self.monitorA, "brightnessValue"), "60%")
    }
}
