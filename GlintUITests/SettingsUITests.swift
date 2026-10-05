import XCTest

/// Settings (SettingsWindowController → SettingsView), opened from the menu.
final class SettingsUITests: GlintUITestCase {
    func testDefaults() {
        launch()
        openSettings()
        waitForToggle(settings("interceptBrightness"), on: true)
        waitForToggle(settings("alwaysInterceptBrightness"), on: false)
        waitForToggle(settings("interceptVolume"), on: true)
        waitForToggle(settings("alwaysInterceptVolume"), on: false)
        waitForToggle(settings("writeOnlyVolume"), on: false)
        waitForToggle(settings("syncWithBuiltIn"), on: true)
        waitForToggle(settings("launchAtLogin"), on: false)
        waitForToggle(settings("hideMenuBarIcon"), on: false)
        waitForToggle(settings("debugLogging"), on: false)
        waitForText(settings("brightnessStep"), "6.25%")
        waitForText(settings("volumeStep"), "6.25%")
        waitForText(settings("aboutTitle"), "Glint")
        XCTAssertFalse(settings("showLogFile").exists)
    }

    func testSubTogglesFollowTheirParent() {
        launch()
        openSettings()
        XCTAssertTrue(settings("alwaysInterceptBrightness").appears(timeout: Self.timeout))
        flip(settings("interceptBrightness"))
        XCTAssertTrue(settings("alwaysInterceptBrightness").disappears(timeout: Self.timeout))

        flip(settings("interceptVolume"))
        XCTAssertTrue(settings("alwaysInterceptVolume").disappears(timeout: Self.timeout))
        XCTAssertFalse(settings("writeOnlyVolume").exists)

        flip(settings("interceptVolume"))
        XCTAssertTrue(settings("alwaysInterceptVolume").appears(timeout: Self.timeout))
        XCTAssertTrue(settings("writeOnlyVolume").exists)
    }

    func testChoicesPersistAcrossRelaunch() {
        launch()
        openSettings()
        choose("10%", in: settings("brightnessStep"))
        choose("2%", in: settings("volumeStep"))
        flip(settings("syncWithBuiltIn"))
        // The login item is a no-op in UI-test mode; only the preference is stored.
        flip(settings("launchAtLogin"))
        app.terminate()

        launch(["GLINT_UITEST_KEEP_DEFAULTS": "1"])
        openSettings()
        waitForText(settings("brightnessStep"), "10%")
        waitForText(settings("volumeStep"), "2%")
        waitForToggle(settings("syncWithBuiltIn"), on: false)
        waitForToggle(settings("launchAtLogin"), on: true)
    }

    func testWriteOnlyVolumeGivesUnreadableMonitorAVolume() {
        launch()
        waitForText(display(Self.monitorB, "volumeNA"), "N/A")
        openSettings()
        flip(settings("writeOnlyVolume"))
        settingsWindow.buttons["_XCUI:CloseWindow"].click()

        element("glint.menu.refresh", in: harness).click()
        // Write-only mode starts an unreadable monitor at 50 % and tracks it in memory.
        waitForText(display(Self.monitorB, "volumeValue"), "50%")
        XCTAssertTrue(display(Self.monitorB, "volumeSlider").exists)
        // Brightness has no write-only mode.
        waitForText(display(Self.monitorB, "brightnessNA"), "N/A")
        // Monitor A still reports its real volume.
        waitForText(display(Self.monitorA, "volumeValue"), "30%")
    }

    func testDebugLoggingRevealsShowLogFile() {
        launch()
        openSettings()
        XCTAssertFalse(settings("showLogFile").exists)
        reveal(settings("debugLogging"))
        flip(settings("debugLogging"))
        XCTAssertTrue(settings("showLogFile").appears(timeout: Self.timeout))
        flip(settings("debugLogging"))
        XCTAssertTrue(settings("showLogFile").disappears(timeout: Self.timeout))
    }

    func testAccessibilityGranted() {
        launch(["GLINT_UITEST_ACCESSIBILITY": "granted"])
        openSettings()
        waitForText(settings("accessibilityStatus"), "Accessibility access granted")
        XCTAssertFalse(settings("openAccessibilitySettings").exists)
    }

    func testAccessibilityRequiredOpensSystemSettings() {
        launch(["GLINT_UITEST_ACCESSIBILITY": "denied"])
        openSettings()
        waitForText(settings("accessibilityStatus"), "Accessibility access required")
        reveal(settings("openAccessibilitySettings"))
        settings("openAccessibilitySettings").click()
        // Recorded instead of opening System Settings.
        waitForText(element("glint.uitest.lastOpenedURL", in: harness),
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testSupportSectionsRenderAndComposeMail() {
        launch()
        openSettings()
        reveal(settingsWindow.buttons["Ask a Question"])
        for title in ["Report an Issue", "Suggest a Feature", "Ask a Question"] {
            XCTAssertTrue(settingsWindow.buttons[title].appears(timeout: Self.timeout), "\(title) row missing")
        }
        XCTAssertTrue(settingsWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'My Other Apps'")).firstMatch.exists)
        reveal(settingsWindow.buttons["Report an Issue"])
        settingsWindow.buttons["Report an Issue"].click()
        waitUntil("Report an Issue should compose a mailto: URL") { [unowned self] in
            self.text(of: self.element("glint.uitest.lastOpenedURL", in: self.harness)).hasPrefix("mailto:")
        }
    }

    func testSettingsWindowIsASingleton() {
        launch()
        openSettings()
        element("glint.menu.settings", in: harness).click()
        XCTAssertTrue(settingsWindow.appears(timeout: Self.timeout))
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == %@", "Glint Settings")).count, 1)
    }

    func testQuitGlintButton() {
        launch()
        openSettings()
        reveal(settings("quit"))
        settings("quit").click()
        waitForTermination()
    }
}
