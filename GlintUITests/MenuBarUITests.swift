import XCTest

/// The menu-bar popover content (MenuBarView), hosted in the UI-test harness window.
final class MenuBarUITests: GlintUITestCase {
    func testTwoDisplaysShowNamesValuesAndNA() {
        launch()
        waitForText(display(Self.monitorA, "name"), "Glint Test Monitor A")
        waitForText(display(Self.monitorA, "brightnessValue"), "60%")
        waitForText(display(Self.monitorA, "volumeValue"), "30%")
        XCTAssertEqual(display(Self.monitorA, "brightnessSlider").value as? Double, 60)

        // Monitor B never answers a DDC read: both rows fall back to N/A, no sliders.
        waitForText(display(Self.monitorB, "name"), "Glint Test Monitor B")
        waitForText(display(Self.monitorB, "brightnessNA"), "N/A")
        waitForText(display(Self.monitorB, "volumeNA"), "N/A")
        XCTAssertFalse(display(Self.monitorB, "brightnessSlider").exists)
        XCTAssertFalse(display(Self.monitorB, "volumeSlider").exists)
        XCTAssertFalse(element("glint.menu.empty", in: harness).exists)
    }

    func testNoExternalDisplaysShowsEmptyState() {
        launch(["GLINT_UITEST_DISPLAYS": "none"])
        waitForText(element("glint.menu.empty", in: harness), "No external displays detected")
        XCTAssertFalse(display(Self.monitorA, "name").exists)
        XCTAssertFalse(display(Self.monitorB, "name").exists)
        // The bottom row is still there.
        XCTAssertTrue(element("glint.menu.refresh", in: harness).exists)
    }

    func testSingleDisplayFixture() {
        launch(["GLINT_UITEST_DISPLAYS": "one"])
        waitForText(display(Self.monitorA, "name"), "Glint Test Monitor A")
        XCTAssertFalse(display(Self.monitorB, "name").exists)
    }

    func testStatusRowWhenIntercepting() {
        launch(["GLINT_UITEST_ACCESSIBILITY": "granted"])
        waitForText(element("glint.menu.status", in: harness), "Intercepting keys")
    }

    func testStatusRowWithoutAccessibility() {
        launch(["GLINT_UITEST_ACCESSIBILITY": "denied"])
        waitForText(element("glint.menu.status", in: harness), "Not active")
    }

    func testBrightnessSliderWritesDDCAndSurvivesRefresh() {
        launch()
        let slider = display(Self.monitorA, "brightnessSlider")
        let value = display(Self.monitorA, "brightnessValue")
        waitForText(value, "60%")

        slider.adjust(toNormalizedSliderPosition: 0.25)
        waitUntil("brightness label should follow the slider to roughly 25%") { [unowned self] in
            (18...32).contains(self.percent(value) ?? -1)
        }
        let written = text(of: value)

        // Refresh re-reads every monitor over DDC: the value only survives if the write
        // reached the (fake) monitor.
        element("glint.menu.refresh", in: harness).click()
        waitForText(value, written)
        // Monitor B still can't be read, so it stays N/A.
        waitForText(display(Self.monitorB, "brightnessNA"), "N/A")
    }

    func testVolumeSliderWritesDDCAndSurvivesRefresh() {
        launch()
        let slider = display(Self.monitorA, "volumeSlider")
        let value = display(Self.monitorA, "volumeValue")
        waitForText(value, "30%")

        slider.adjust(toNormalizedSliderPosition: 0.8)
        waitUntil("volume label should follow the slider to roughly 80% (got \(text(of: value)))") { [unowned self] in
            (70...90).contains(self.percent(value) ?? -1)
        }
        let written = text(of: value)

        element("glint.menu.refresh", in: harness).click()
        waitForText(value, written)
        // Brightness was untouched.
        waitForText(display(Self.monitorA, "brightnessValue"), "60%")
    }

    func testQuitTerminatesTheApp() {
        launch()
        element("glint.menu.quit", in: harness).click()
        waitForTermination()
    }
}
