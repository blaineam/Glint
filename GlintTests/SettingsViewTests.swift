import AppKit
import SwiftUI
import XCTest
@testable import Glint

/// The Settings form and the Settings / Support window controllers, hosted off-screen over a
/// throwaway Preferences suite (no SMAppService, no real defaults, no windows shown).
@MainActor
final class SettingsViewTests: XCTestCase {
    private var prefs: Preferences!
    private var interceptor: MediaKeyInterceptor!
    private final class LoginItemLog: @unchecked Sendable { var calls: [Bool] = [] }
    private var loginItems = LoginItemLog()

    override func setUp() async throws {
        try await super.setUp()
        let log = LoginItemLog()
        loginItems = log
        (prefs, _) = makePreferences(loginItem: { log.calls.append($0) })
        let (otherPrefs, _) = makePreferences()
        let manager = makeFakeDisplayManager(
            preferences: otherPrefs, transport: FakeDDCTransport(), audio: FakeSystemAudio(), environment: FakeDisplayEnvironment()
        )
        interceptor = makeFakeInterceptor(preferences: prefs, displayManager: manager)
    }

    private func host() -> OffscreenHost<SettingsView> {
        OffscreenHost(SettingsView(prefs: prefs, interceptor: interceptor), size: NSSize(width: 400, height: 500))
    }

    func testRendersTheFormWithEverySection() {
        let host = host()
        XCTAssertGreaterThan(host.hostingView.fittingSize.height, 200)
        // Every toggle row is present with the defaults: intercept brightness (+ always),
        // intercept volume (+ always, write-only), sync, launch at login, hide icon, debug log.
        XCTAssertEqual(host.switchCount, 9)
    }

    func testSubOptionsAppearAndDisappearWithTheirParentToggles() {
        let host = host()
        XCTAssertEqual(host.switchCount, 9)

        // Turning both intercept toggles off hides their "always" / "write-only" sub-options.
        prefs.interceptBrightness = false
        host.render()
        XCTAssertEqual(host.switchCount, 8)
        prefs.interceptVolume = false
        host.render()
        XCTAssertEqual(host.switchCount, 6)

        prefs.interceptVolume = true
        host.render()
        XCTAssertEqual(host.switchCount, 8, "volume back on restores its two sub-options; brightness stays off")
    }

    func testAccessibilityStateAndDebugLoggingRerenderWithoutTheSwitches() {
        interceptor.isActive = false
        let host = host()
        interceptor.isActive = true
        prefs.debugLogging = true       // reveals the "Show Log File" button, not another switch
        host.render()
        XCTAssertEqual(host.switchCount, 9)
    }

    func testTogglingPreferencesFromTheFormModelReachesTheLoginItemSeam() {
        prefs.launchAtLogin = true
        prefs.launchAtLogin = false
        XCTAssertEqual(loginItems.calls, [true, false])
        _ = host()
    }

    // MARK: - Window controllers

    func testSettingsWindowIsBuiltOnceAndReusedWithoutBeingShown() {
        let controller = SettingsWindowController(presentsWindow: false)
        XCTAssertNil(controller.window)
        controller.show()
        let first = controller.window
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.title, "Glint Settings")
        XCTAssertEqual(first?.styleMask, [.titled, .closable])
        XCTAssertFalse(first?.isReleasedWhenClosed ?? true)
        XCTAssertFalse(first?.isVisible ?? true)
        controller.show()
        XCTAssertTrue(controller.window === first)
        XCTAssertFalse(first?.isVisible ?? true)
    }

    func testSupportWindowIsBuiltOnceAndReusedWithoutBeingShown() {
        let controller = SupportWindowController(presentsWindow: false)
        XCTAssertNil(controller.window)
        controller.show()
        let first = controller.window
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.title, "Support Glint")
        XCTAssertEqual(first?.contentRect(forFrameRect: first?.frame ?? .zero).size, NSSize(width: 440, height: 560))
        XCTAssertFalse(first?.isVisible ?? true)
        controller.show()
        XCTAssertTrue(controller.window === first)
    }
}
