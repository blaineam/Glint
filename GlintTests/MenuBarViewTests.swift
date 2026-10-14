import AppKit
import SwiftUI
import XCTest
@testable import Glint

/// The popover content rendered off-screen over fake DDC / CoreAudio / display environments.
/// Nothing here talks to a real monitor: every manager is built over the in-memory fakes.
@MainActor
final class MenuBarViewTests: XCTestCase {
    private var transport: FakeDDCTransport!
    private var audio: FakeSystemAudio!
    private var env: FakeDisplayEnvironment!
    private var prefs: Preferences!

    override func setUp() async throws {
        try await super.setUp()
        transport = FakeDDCTransport()
        audio = FakeSystemAudio()
        env = FakeDisplayEnvironment()
        (prefs, _) = makePreferences()
    }

    private func makeManager() -> DisplayManager {
        makeFakeDisplayManager(preferences: prefs, transport: transport, audio: audio, environment: env)
    }

    private func makeInterceptor(_ manager: DisplayManager, active: Bool) -> MediaKeyInterceptor {
        let interceptor = makeFakeInterceptor(preferences: prefs, displayManager: manager)
        interceptor.isActive = active
        return interceptor
    }

    /// Records which popover buttons were pressed.
    private final class ActionLog: @unchecked Sendable {
        var calls: [String] = []
        var actions: MenuBarActions {
            MenuBarActions(
                showSettings: { [self] in calls.append("settings") },
                showSupport: { [self] in calls.append("support") },
                refresh: { [self] in calls.append("refresh") },
                quit: { [self] in calls.append("quit") }
            )
        }
    }

    // MARK: - States

    func testEmptyStateWhenNoExternalDisplays() {
        let manager = makeManager()
        let view = MenuBarView(displayManager: manager, interceptor: makeInterceptor(manager, active: true), prefs: prefs, actions: ActionLog().actions)
        let host = OffscreenHost(view, size: NSSize(width: 280, height: 200))
        XCTAssertTrue(manager.displays.isEmpty)
        XCTAssertGreaterThan(host.hostingView.fittingSize.height, 40)
    }

    func testPopoverIsFixedWidthAndGrowsWithEachMonitor() {
        env.addExternal(10, name: "LG HDR 4K")
        transport.set(.brightness, current: 40, max: 100, on: 10)
        transport.set(.volume, current: 20, max: 100, on: 10)
        let one = makeManager()
        let oneHost = OffscreenHost(MenuBarView(displayManager: one, interceptor: makeInterceptor(one, active: true), prefs: prefs, actions: ActionLog().actions))

        env.addExternal(11, name: "DELL U2723QE")
        transport.set(.brightness, current: 70, max: 100, on: 11)
        let two = makeManager()
        let twoHost = OffscreenHost(MenuBarView(displayManager: two, interceptor: makeInterceptor(two, active: true), prefs: prefs, actions: ActionLog().actions))

        XCTAssertEqual(oneHost.hostingView.fittingSize.width, 280, accuracy: 0.5)
        XCTAssertEqual(twoHost.hostingView.fittingSize.width, 280, accuracy: 0.5)
        XCTAssertGreaterThan(twoHost.hostingView.fittingSize.height, oneHost.hostingView.fittingSize.height + 30)
        XCTAssertEqual(two.displays.count, 2)
    }

    func testInactiveInterceptorRendersTheNotActiveStatus() {
        env.addExternal(10, name: "LG HDR 4K")
        transport.set(.brightness, current: 40, max: 100, on: 10)
        let manager = makeManager()
        let interceptor = makeInterceptor(manager, active: false)
        let host = OffscreenHost(MenuBarView(displayManager: manager, interceptor: interceptor, prefs: prefs, actions: ActionLog().actions))
        interceptor.isActive = true
        host.render()
        XCTAssertTrue(interceptor.isActive)
        XCTAssertGreaterThan(host.hostingView.fittingSize.height, 100)
    }

    // MARK: - Actions

    func testButtonsRouteToTheInjectedActions() {
        let manager = makeManager()
        let log = ActionLog()
        let view = MenuBarView(displayManager: manager, interceptor: makeInterceptor(manager, active: true), prefs: prefs, actions: log.actions)
        view.actions.showSettings()
        view.actions.showSupport()
        view.actions.refresh()
        view.actions.quit()
        XCTAssertEqual(log.calls, ["settings", "support", "refresh", "quit"])
    }

    func testLiveRefreshActionRereadsTheMonitors() {
        let manager = makeManager()
        XCTAssertTrue(manager.displays.isEmpty)
        env.addExternal(10, name: "LG HDR 4K")
        transport.set(.brightness, current: 40, max: 100, on: 10)

        MenuBarActions.live(displayManager: manager).refresh()

        XCTAssertEqual(manager.displays.map(\.id), [10])
        XCTAssertEqual(manager.displays.first?.brightness, 40)
    }

    // MARK: - DisplayControlView sliders

    private func controlView(sync: Bool, id: CGDirectDisplayID = 10) -> (DisplayControlView, DisplayManager) {
        env.addExternal(10, name: "LG HDR 4K")
        env.addExternal(11, name: "DELL U2723QE")
        transport.set(.brightness, current: 40, max: 100, on: 10)
        transport.set(.volume, current: 20, max: 100, on: 10)
        transport.set(.brightness, current: 70, max: 100, on: 11)
        prefs.syncWithBuiltIn = sync
        let manager = makeManager()
        let display = manager.displays.first { $0.id == id }!
        return (DisplayControlView(display: display, displayManager: manager, prefs: prefs), manager)
    }

    func testBrightnessSliderMovesOnlyItsMonitorWhenNotSyncing() {
        let (view, manager) = controlView(sync: false)
        view.brightnessSliderChanged(to: 55)
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [55])
        XCTAssertTrue(transport.writtenValues(.brightness, on: 11).isEmpty)
        XCTAssertEqual(manager.displays.first { $0.id == 10 }?.brightness, 55)
        XCTAssertTrue(env.builtInSets.isEmpty)
    }

    func testBrightnessSliderMovesEveryDisplayWhenSyncing() {
        let (view, _) = controlView(sync: true)
        view.brightnessSliderChanged(to: 30)
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [30])
        XCTAssertEqual(transport.writtenValues(.brightness, on: 11), [30])
        XCTAssertEqual(env.builtInSets, [0.3])
    }

    func testVolumeSliderWritesThatMonitorsVolume() {
        let (view, manager) = controlView(sync: true)
        view.volumeSliderChanged(to: 65)
        XCTAssertEqual(transport.writtenValues(.volume, on: 10), [65])
        XCTAssertEqual(manager.displays.first { $0.id == 10 }?.volume, 65)
    }

    func testSlidersIgnoreAMonitorThatReportsNoRange() {
        let (view, _) = controlView(sync: true, id: 11)   // Dell: no DDC volume
        view.volumeSliderChanged(to: 10)
        XCTAssertTrue(transport.writtenValues(.volume, on: 11).isEmpty)

        var blank = view.display
        blank.maxBrightness = 0
        let noRange = DisplayControlView(display: blank, displayManager: view.displayManager, prefs: prefs)
        noRange.brightnessSliderChanged(to: 10)
        XCTAssertTrue(transport.writtenValues(.brightness, on: 11).isEmpty)
    }

    // MARK: - DisplayControlView rendering

    func testRendersSlidersForAMonitorWithDDCAndNAForOneWithout() {
        let (ddcView, manager) = controlView(sync: false)
        let ddcHost = OffscreenHost(ddcView, size: NSSize(width: 280, height: 120))
        let dell = manager.displays.first { $0.id == 11 }!
        XCTAssertNil(dell.volume)
        let naHost = OffscreenHost(DisplayControlView(display: dell, displayManager: manager, prefs: prefs), size: NSSize(width: 280, height: 120))
        XCTAssertGreaterThan(ddcHost.hostingView.fittingSize.height, 40)
        XCTAssertGreaterThan(naHost.hostingView.fittingSize.height, 40)
    }

    func testRendersAMonitorWithNeitherControl() {
        let manager = makeManager()
        let bare = ExternalDisplay(id: 99, name: "Mystery Monitor", vendorNumber: 1, modelNumber: 2)
        let host = OffscreenHost(DisplayControlView(display: bare, displayManager: manager, prefs: prefs), size: NSSize(width: 280, height: 120))
        XCTAssertGreaterThan(host.hostingView.fittingSize.height, 40)
    }
}
