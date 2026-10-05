import XCTest
@testable import Glint

final class PreferencesTests: XCTestCase {
    // MARK: Defaults

    func testFreshInstallDefaults() {
        let (prefs, _) = makePreferences()
        XCTAssertFalse(prefs.launchAtLogin)
        XCTAssertTrue(prefs.interceptBrightness)
        XCTAssertTrue(prefs.interceptVolume)
        XCTAssertFalse(prefs.alwaysInterceptBrightness)
        XCTAssertFalse(prefs.alwaysInterceptVolume)
        XCTAssertFalse(prefs.writeOnlyVolume)
        XCTAssertEqual(prefs.brightnessStep, 6.25)
        XCTAssertEqual(prefs.volumeStep, 6.25)
        XCTAssertTrue(prefs.syncWithBuiltIn)
        XCTAssertFalse(prefs.hideMenuBarIcon)
        XCTAssertFalse(prefs.debugLogging)
    }

    func testUpgradeFromPre15KeepsSettingsAndGetsDefaultStep() {
        // A 1.4.x domain: user customised toggles but has never seen the step keys.
        let (prefs, _) = makePreferences { d in
            d.set(false, forKey: "interceptVolume")
            d.set(false, forKey: "syncWithBuiltIn")
            d.set(true, forKey: "writeOnlyVolume")
        }
        XCTAssertFalse(prefs.interceptVolume)
        XCTAssertFalse(prefs.syncWithBuiltIn)
        XCTAssertTrue(prefs.writeOnlyVolume)
        XCTAssertEqual(prefs.brightnessStep, Preferences.defaultStep)
        XCTAssertEqual(prefs.volumeStep, Preferences.defaultStep)
    }

    // MARK: Persistence

    func testEveryPreferencePersistsToItsKeyAndReloads() {
        let (prefs, defaults) = makePreferences()
        prefs.launchAtLogin = true
        prefs.interceptBrightness = false
        prefs.interceptVolume = false
        prefs.alwaysInterceptBrightness = true
        prefs.alwaysInterceptVolume = true
        prefs.writeOnlyVolume = true
        prefs.brightnessStep = 2
        prefs.volumeStep = 10
        prefs.syncWithBuiltIn = false
        prefs.hideMenuBarIcon = true
        prefs.debugLogging = true

        XCTAssertEqual(defaults.object(forKey: "launchAtLogin") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "interceptBrightness") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "interceptVolume") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "alwaysInterceptBrightness") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "alwaysInterceptVolume") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "writeOnlyVolume") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "brightnessStep") as? Double, 2)
        XCTAssertEqual(defaults.object(forKey: "volumeStep") as? Double, 10)
        XCTAssertEqual(defaults.object(forKey: "syncWithBuiltIn") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "hideMenuBarIcon") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "debugLogging") as? Bool, true)

        let reloaded = Preferences(defaults: defaults, loginItem: { _ in })
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertFalse(reloaded.interceptBrightness)
        XCTAssertFalse(reloaded.interceptVolume)
        XCTAssertTrue(reloaded.alwaysInterceptBrightness)
        XCTAssertTrue(reloaded.alwaysInterceptVolume)
        XCTAssertTrue(reloaded.writeOnlyVolume)
        XCTAssertEqual(reloaded.brightnessStep, 2)
        XCTAssertEqual(reloaded.volumeStep, 10)
        XCTAssertFalse(reloaded.syncWithBuiltIn)
        XCTAssertTrue(reloaded.hideMenuBarIcon)
        XCTAssertTrue(reloaded.debugLogging)
    }

    // MARK: Side effects

    func testLaunchAtLoginDrivesTheLoginItem() {
        var calls: [Bool] = []
        let (prefs, _) = makePreferences(loginItem: { calls.append($0) })
        XCTAssertEqual(calls, [], "loading preferences must not touch the login item")
        prefs.launchAtLogin = true
        prefs.launchAtLogin = false
        XCTAssertEqual(calls, [true, false])
    }

    func testOtherPreferencesDoNotTouchTheLoginItem() {
        var calls: [Bool] = []
        let (prefs, _) = makePreferences(loginItem: { calls.append($0) })
        prefs.interceptVolume = false
        prefs.hideMenuBarIcon = true
        XCTAssertEqual(calls, [])
    }

    func testHidingTheMenuBarIconPostsVisibilityChange() {
        let (prefs, _) = makePreferences()
        let posted = expectation(forNotification: .glintMenuBarVisibilityChanged, object: nil)
        prefs.hideMenuBarIcon = true
        wait(for: [posted], timeout: 1)
    }

    // MARK: Step size (v1.5.0)

    func testStepOptionsAreTheSettingsPickerValues() {
        XCTAssertEqual(Preferences.stepOptions, [1, 2, 3, 4, 5, 6.25, 8, 10])
        XCTAssertTrue(Preferences.stepOptions.contains(Preferences.defaultStep))
    }

    func testStepFractionForEveryOffered() {
        for option in Preferences.stepOptions {
            XCTAssertEqual(Preferences.stepFraction(option), option / 100, accuracy: 1e-12)
        }
    }

    func testStepFractionClampsToOneToTenPercent() {
        XCTAssertEqual(Preferences.stepFraction(0.5), 0.01, accuracy: 1e-12)
        XCTAssertEqual(Preferences.stepFraction(25), 0.10, accuracy: 1e-12)
    }

    func testStepFractionRejectsInvalidValues() {
        for bad in [0, -3, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(Preferences.stepFraction(bad), 0.0625, accuracy: 1e-12, "\(bad)")
        }
    }

    func testStepToAbsoluteScalesToTheDisplayMax() {
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 100, percent: 6.25), 6)
        XCTAssertEqual(DisplayManager.stepToAbsolute(-1, max: 100, percent: 6.25), -6)
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 100, percent: 2), 2)
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 255, percent: 10), 25)
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 1000, percent: 1), 10)
    }

    func testStepToAbsoluteIsAtLeastOneUnit() {
        // Monitors with tiny ranges (e.g. max 1 or a broken max 0) must still move.
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 1, percent: 6.25), 1)
        XCTAssertEqual(DisplayManager.stepToAbsolute(-1, max: 0, percent: 1), -1)
        XCTAssertEqual(DisplayManager.stepToAbsolute(1, max: 10, percent: 1), 1)
    }
}
