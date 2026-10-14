import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Glint

/// The event-tap plumbing around `MediaKeyInterceptor.action`: start/stop, decoding a real
/// NX_SYSDEFINED CGEvent, consuming vs passing the key, the C callback, and the DDC/OSD work
/// that follows. The tap is a plain Mach port and the display stack is the in-memory fakes,
/// so no keyboard tap is installed and no monitor is touched.
@MainActor
final class MediaKeyInterceptorTests: XCTestCase {
    private var transport: FakeDDCTransport!
    private var audio: FakeSystemAudio!
    private var env: FakeDisplayEnvironment!
    private var prefs: Preferences!
    private var manager: DisplayManager!
    private var osd: [(icon: String, value: Int)] = []
    private var osdArrived: XCTestExpectation?
    private var ports: [CFMachPort] = []

    override func setUp() async throws {
        try await super.setUp()
        transport = FakeDDCTransport()
        audio = FakeSystemAudio()
        env = FakeDisplayEnvironment()
        (prefs, _) = makePreferences()
        prefs.syncWithBuiltIn = false
        osd = []
        env.addExternal(10, name: "LG HDR 4K")
        env.cursor = 10
        transport.set(.brightness, current: 50, max: 100, on: 10)
        transport.set(.volume, current: 20, max: 100, on: 10)
        manager = makeFakeDisplayManager(preferences: prefs, transport: transport, audio: audio, environment: env)
    }

    override func tearDown() async throws {
        for port in ports { CFMachPortInvalidate(port) }
        ports = []
        try await super.tearDown()
    }

    private func makeInterceptor(
        factory: MediaKeyInterceptor.TapFactory? = nil,
        switchTap: @escaping MediaKeyInterceptor.TapSwitch = { _, _ in }
    ) -> MediaKeyInterceptor {
        MediaKeyInterceptor(
            preferences: { [unowned self] in prefs },
            displayManager: { [unowned self] in manager },
            tapFactory: factory ?? { [unowned self] _, _ in
                let port = makeFakeTapPort()
                ports.append(port)
                return port
            },
            tapSwitch: switchTap,
            presentOSD: { [unowned self] icon, value, _ in
                osd.append((icon, value))
                osdArrived?.fulfill()
            }
        )
    }

    /// A real NX_SYSDEFINED "aux control button" event, as the HID system delivers media keys.
    private func mediaKeyEvent(_ keyCode: Int32, down: Bool = true, subtype: Int16 = 8) throws -> CGEvent {
        let data1 = (Int(keyCode) << 16) | ((down ? 0x0A : 0x0B) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: subtype, data1: data1, data2: -1
        )
        return try XCTUnwrap(event?.cgEvent)
    }

    private let proxy = OpaquePointer(bitPattern: 0x1)!
    private let systemDefined = CGEventType(rawValue: 14)!

    /// Presses a key through `handleMediaKey` and waits for the queued DDC work and OSD.
    private func press(_ keyCode: Int32, on interceptor: MediaKeyInterceptor, expectOSD: Bool = true) throws -> CGEvent? {
        osdArrived = expectOSD ? expectation(description: "OSD shown") : nil
        let result = interceptor.handleMediaKey(proxy: proxy, type: systemDefined, event: try mediaKeyEvent(keyCode))
        if expectOSD { wait(for: [osdArrived!], timeout: 5) }
        interceptor.waitForPendingWork()
        return result
    }

    // MARK: - start / stop

    func testStartInstallsTheTapAndStopRemovesIt() {
        var switches: [Bool] = []
        var masks: [CGEventMask] = []
        let interceptor = makeInterceptor(
            factory: { [unowned self] mask, _ in
                masks.append(mask)
                let port = makeFakeTapPort()
                ports.append(port)
                return port
            },
            switchTap: { _, enabled in switches.append(enabled) }
        )
        XCTAssertFalse(interceptor.isActive)

        interceptor.start()
        XCTAssertTrue(interceptor.isActive)
        XCTAssertEqual(switches, [true])
        XCTAssertEqual(masks.count, 1)
        let mask = masks[0]
        XCTAssertNotEqual(mask & (1 << 14), 0, "NX_SYSDEFINED must be in the mask")
        XCTAssertNotEqual(mask & (1 << CGEventType.keyDown.rawValue), 0)

        interceptor.start()                       // already running: no second tap
        XCTAssertEqual(masks.count, 1)
        XCTAssertEqual(switches, [true])

        interceptor.stop()
        XCTAssertFalse(interceptor.isActive)
        XCTAssertEqual(switches, [true, false])

        interceptor.stop()                        // stopping twice is harmless
        XCTAssertEqual(switches, [true, false])
    }

    func testStartWithoutAccessibilityLeavesTheInterceptorInactive() {
        let interceptor = makeInterceptor(factory: { _, _ in nil })
        interceptor.start()
        XCTAssertFalse(interceptor.isActive)
        interceptor.stop()
        XCTAssertFalse(interceptor.isActive)
    }

    func testCanRestartAfterStop() {
        var created = 0
        let interceptor = makeInterceptor(factory: { [unowned self] _, _ in
            created += 1
            let port = makeFakeTapPort()
            ports.append(port)
            return port
        })
        interceptor.start()
        interceptor.stop()
        interceptor.start()
        XCTAssertEqual(created, 2)
        XCTAssertTrue(interceptor.isActive)
    }

    // MARK: - handleMediaKey

    func testBrightnessKeyIsConsumedAndStepsTheCursorMonitor() throws {
        let interceptor = makeInterceptor()
        let result = try press(Int32(NX_KEYTYPE_BRIGHTNESS_UP), on: interceptor)
        XCTAssertNil(result, "a handled key is swallowed so macOS never sees it")
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [56])   // 50 + 6.25% of 100, truncated
        XCTAssertEqual(osd.map(\.icon), ["sun.max.fill"])
        XCTAssertEqual(osd.map(\.value), [56])
    }

    func testBrightnessDownLowersIt() throws {
        let interceptor = makeInterceptor()
        _ = try press(Int32(NX_KEYTYPE_BRIGHTNESS_DOWN), on: interceptor)
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [44])
        XCTAssertEqual(osd.map(\.value), [44])
    }

    func testVolumeKeysStepTheSystemOutputAndShowTheSpeakerPill() throws {
        let interceptor = makeInterceptor()
        let up = try press(Int32(NX_KEYTYPE_SOUND_UP), on: interceptor)
        XCTAssertNil(up)
        XCTAssertEqual(audio.setVolumeCalls.count, 1)
        XCTAssertEqual(audio.setVolumeCalls[0], 0.5625, accuracy: 0.0001)
        XCTAssertEqual(osd.map(\.icon), ["speaker.wave.2.fill"])
        XCTAssertEqual(osd.map(\.value), [56])
    }

    func testMuteKeyTogglesAndShowsTheSlashedSpeaker() throws {
        let interceptor = makeInterceptor()
        let result = try press(Int32(NX_KEYTYPE_MUTE), on: interceptor)
        XCTAssertNil(result)
        XCTAssertEqual(audio.setMutedCalls, [true])
        XCTAssertEqual(osd.map(\.icon), ["speaker.slash.fill"])
        XCTAssertEqual(osd.map(\.value), [0])

        _ = try press(Int32(NX_KEYTYPE_MUTE), on: interceptor)
        XCTAssertEqual(audio.setMutedCalls, [true, false])
        XCTAssertEqual(osd.map(\.icon), ["speaker.slash.fill", "speaker.wave.2.fill"])
    }

    func testKeyIsPassedThroughWhenInterceptionIsOff() throws {
        prefs.interceptBrightness = false
        let interceptor = makeInterceptor()
        let result = try press(Int32(NX_KEYTYPE_BRIGHTNESS_UP), on: interceptor, expectOSD: false)
        XCTAssertNotNil(result)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(osd.isEmpty)
    }

    func testUnrelatedMediaKeysAndKeyUpsPassThrough() throws {
        let interceptor = makeInterceptor()
        XCTAssertNotNil(try press(Int32(NX_KEYTYPE_PLAY), on: interceptor, expectOSD: false))
        let up = interceptor.handleMediaKey(
            proxy: proxy, type: systemDefined, event: try mediaKeyEvent(Int32(NX_KEYTYPE_BRIGHTNESS_UP), down: false)
        )
        XCTAssertNotNil(up)
        interceptor.waitForPendingWork()
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testOtherEventTypesAndSubtypesPassThrough() throws {
        let interceptor = makeInterceptor()
        let keyDown = try mediaKeyEvent(Int32(NX_KEYTYPE_BRIGHTNESS_UP))
        XCTAssertNotNil(interceptor.handleMediaKey(proxy: proxy, type: .keyDown, event: keyDown))

        let otherSubtype = try mediaKeyEvent(Int32(NX_KEYTYPE_BRIGHTNESS_UP), subtype: 7)
        XCTAssertNotNil(interceptor.handleMediaKey(proxy: proxy, type: systemDefined, event: otherSubtype))
        interceptor.waitForPendingWork()
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testNoDDCMonitorMeansBrightnessKeysAreLeftToMacOS() throws {
        env.externals = []
        manager.refresh()
        let interceptor = makeInterceptor()
        let result = try press(Int32(NX_KEYTYPE_BRIGHTNESS_UP), on: interceptor, expectOSD: false)
        XCTAssertNotNil(result)
    }

    // MARK: - simulate (UI-test hook)

    func testSimulateRoutesAKeyExactlyLikeTheTap() {
        let interceptor = makeInterceptor()
        osdArrived = expectation(description: "OSD shown")
        interceptor.simulate(MediaKey(keyCode: Int(NX_KEYTYPE_BRIGHTNESS_UP), isDown: true))
        wait(for: [osdArrived!], timeout: 5)
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [56])

        interceptor.simulate(MediaKey(keyCode: Int(NX_KEYTYPE_BRIGHTNESS_UP), isDown: false))   // key-up: nothing
        interceptor.waitForPendingWork()
        XCTAssertEqual(transport.writtenValues(.brightness, on: 10), [56])
    }

    // MARK: - C callback

    func testCallbackPassesEventsThroughWhenThereIsNoInterceptor() throws {
        let event = try mediaKeyEvent(Int32(NX_KEYTYPE_BRIGHTNESS_UP))
        let result = mediaKeyCallback(proxy: proxy, type: systemDefined, event: event, userInfo: nil)
        XCTAssertNotNil(result)
        result?.release()
    }

    func testCallbackHandsMediaKeysToTheInterceptor() throws {
        let interceptor = makeInterceptor()
        let userInfo = Unmanaged.passUnretained(interceptor).toOpaque()

        osdArrived = expectation(description: "OSD shown")
        let consumed = mediaKeyCallback(proxy: proxy, type: systemDefined, event: try mediaKeyEvent(Int32(NX_KEYTYPE_BRIGHTNESS_UP)), userInfo: userInfo)
        XCTAssertNil(consumed)
        wait(for: [osdArrived!], timeout: 5)

        let passed = mediaKeyCallback(proxy: proxy, type: systemDefined, event: try mediaKeyEvent(Int32(NX_KEYTYPE_PLAY)), userInfo: userInfo)
        XCTAssertNotNil(passed)
        passed?.release()
    }

    func testCallbackReEnablesATapMacOSDisabled() throws {
        var switches: [Bool] = []
        let interceptor = makeInterceptor(switchTap: { _, enabled in switches.append(enabled) })
        interceptor.start()                       // switches == [true]
        let userInfo = Unmanaged.passUnretained(interceptor).toOpaque()

        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let result = mediaKeyCallback(proxy: proxy, type: type, event: try mediaKeyEvent(Int32(NX_KEYTYPE_MUTE)), userInfo: userInfo)
            XCTAssertNotNil(result, "the event itself is never dropped")
            result?.release()
        }
        // The re-enable hops to the main queue.
        let deadline = Date().addingTimeInterval(5)
        while switches.count < 3 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(switches, [true, true, true])

        let noInterceptor = mediaKeyCallback(proxy: proxy, type: .tapDisabledByTimeout, event: try mediaKeyEvent(Int32(NX_KEYTYPE_MUTE)), userInfo: nil)
        XCTAssertNotNil(noInterceptor)
        noInterceptor?.release()
    }
}
