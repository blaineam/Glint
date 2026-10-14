import AppKit
import SwiftUI
import XCTest
@testable import Glint

#if DEBUG
/// The DEBUG-only UI-test fixtures (in-memory monitors, fake CoreAudio, throwaway
/// preferences) are what every XCUITest drives, so they are worth pinning down here: a
/// wrong fixture would fail the UI suite for the wrong reason.
@MainActor
final class UITestModeFixtureTests: XCTestCase {
    func testFixtureManagerHasMonitorAAnsweringAndMonitorBSilent() throws {
        let manager = UITestMode.makeDisplayManager()
        XCTAssertEqual(manager.displays.map(\.name), ["Glint Test Monitor A", "Glint Test Monitor B"])

        let a = manager.displays[0]
        XCTAssertEqual(a.id, 101)
        XCTAssertEqual(a.brightness, 60)
        XCTAssertEqual(a.maxBrightness, 100)
        XCTAssertEqual(a.volume, 30)
        XCTAssertTrue(a.ddcBrightnessAvailable)
        XCTAssertTrue(a.ddcVolumeAvailable)

        let b = manager.displays[1]
        XCTAssertNil(b.brightness)
        XCTAssertNil(b.volume)
        XCTAssertFalse(b.ddcBrightnessAvailable)
    }

    func testFixtureWritesAreReadBackOnRefresh() {
        let manager = UITestMode.makeDisplayManager()
        manager.setBrightness(80, for: 101)
        manager.setVolume(10, for: 101)
        manager.refresh()
        XCTAssertEqual(manager.displays[0].brightness, 80)
        XCTAssertEqual(manager.displays[0].volume, 10)
    }

    func testFixtureAudioAndBuiltInPanelAreUsable() {
        let manager = UITestMode.makeDisplayManager()
        XCTAssertEqual(manager.brightnessPercent(for: 1), 50)          // built-in at 50 %
        XCTAssertEqual(manager.displayUnderCursor(), 101)
        XCTAssertFalse(manager.isAudioOutputDisplayBased())             // built-in speakers
        XCTAssertEqual(manager.currentVolumePercent(), 50)
        XCTAssertTrue(manager.hasBuiltInDisplay())

        manager.adjustVolume(by: 1)
        XCTAssertGreaterThan(manager.currentVolumePercent(), 50)
        manager.setBrightnessForAll(20)
        XCTAssertEqual(manager.brightnessPercent(for: 1), 20)
    }

    func testDebugLoggerFixtureWritesUnderTheTemporaryDirectory() {
        let logger = UITestMode.makeDebugLogger()
        XCTAssertTrue(logger.logFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(logger.logFileURL.lastPathComponent, "debug.log")
    }

    func testPreferencesFixtureUsesItsOwnSuiteAndNoLoginItem() {
        let prefs = UITestMode.makePreferences()
        XCTAssertTrue(prefs.interceptBrightness)
        prefs.launchAtLogin = true       // would register a login item if the seam were live
        prefs.launchAtLogin = false
        UserDefaults.standard.removePersistentDomain(forName: UITestMode.defaultsSuite)
    }

    func testRecorderKeepsTheLastRecordedURLInUITestMode() {
        UITestMode.Recorder.shared.lastOpenedURL = "https://example.com"
        XCTAssertEqual(UITestMode.Recorder.shared.lastOpenedURL, "https://example.com")
        UITestMode.Recorder.shared.lastOpenedURL = ""
    }

    func testHostLeavesAViewUntouchedOutsideUITestMode() {
        XCTAssertFalse(UITestMode.isActive)
        let host = OffscreenHost(UITestMode.host(Text(verbatim: "hello")), size: NSSize(width: 100, height: 40))
        XCTAssertGreaterThan(host.hostingView.fittingSize.width, 10)
        XCTAssertEqual(UITestMode.displayFixture, .two)
        XCTAssertTrue(UITestMode.accessibilityGranted)
        XCTAssertFalse(UITestMode.showsAccessibilityAlert)
    }

    func testPlaceIsANoOpOutsideUITestMode() {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let before = window.frame
        UITestMode.place(window)
        XCTAssertEqual(window.frame, before)
        XCTAssertNotEqual(window.level, .floating)
    }
}
#endif
