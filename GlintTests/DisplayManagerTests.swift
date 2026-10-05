import CoreAudio
import XCTest
@testable import Glint

/// Brightness / volume / mute routing over fake DDC, CoreAudio and display environment.
final class DisplayManagerTests: XCTestCase {
    private let lg: CGDirectDisplayID = 10
    private let dell: CGDirectDisplayID = 11

    private var transport: FakeDDCTransport!
    private var clock: FakeClock!
    private var audio: FakeSystemAudio!
    private var env: FakeDisplayEnvironment!
    private var prefs: Preferences!

    override func setUp() {
        super.setUp()
        transport = FakeDDCTransport()
        clock = FakeClock()
        audio = FakeSystemAudio()
        env = FakeDisplayEnvironment()
        (prefs, _) = makePreferences()
    }

    /// Builds a manager over the fakes and runs the initial display refresh.
    private func makeManager(sync: Bool, writeOnly: Bool = false) -> DisplayManager {
        prefs.syncWithBuiltIn = sync
        prefs.writeOnlyVolume = writeOnly
        let manager = DisplayManager(preferences: prefs, ddc: makeDDC(transport, clock: clock), audio: audio, environment: env)
        manager.refresh()
        return manager
    }

    private func display(_ id: CGDirectDisplayID, in manager: DisplayManager) -> ExternalDisplay? {
        manager.displays.first { $0.id == id }
    }

    /// Two monitors: LG (brightness 40/100, volume 20/100) and Dell (brightness 70/100, no DDC volume).
    private func twoMonitors() {
        env.addExternal(lg, name: "LG HDR 4K")
        env.addExternal(dell, name: "DELL U2723QE")
        transport.set(.brightness, current: 40, max: 100, on: lg)
        transport.set(.volume, current: 20, max: 100, on: lg)
        transport.set(.brightness, current: 70, max: 100, on: dell)
    }

    // MARK: - refresh

    func testRefreshProbesDDCPerDisplay() {
        twoMonitors()
        let generic: CGDirectDisplayID = 12
        env.addExternal(generic, name: "Generic Monitor")
        let manager = makeManager(sync: false)

        XCTAssertEqual(manager.displays.map(\.id), [lg, dell, generic])
        let lgDisplay = display(lg, in: manager)
        XCTAssertEqual(lgDisplay?.brightness, 40)
        XCTAssertEqual(lgDisplay?.maxBrightness, 100)
        XCTAssertEqual(lgDisplay?.volume, 20)
        XCTAssertEqual(lgDisplay?.ddcBrightnessAvailable, true)
        XCTAssertEqual(lgDisplay?.ddcVolumeAvailable, true)

        XCTAssertEqual(display(dell, in: manager)?.ddcBrightnessAvailable, true)
        XCTAssertEqual(display(dell, in: manager)?.ddcVolumeAvailable, false)
        XCTAssertNil(display(dell, in: manager)?.volume)

        XCTAssertEqual(display(generic, in: manager)?.ddcBrightnessAvailable, false)
        XCTAssertEqual(display(generic, in: manager)?.ddcVolumeAvailable, false)
        XCTAssertTrue(manager.ddcBrightnessAvailable)
        XCTAssertTrue(manager.ddcVolumeAvailable)
    }

    func testRefreshInvalidatesPortMappingFirst() {
        _ = makeManager(sync: false)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testZeroMaxFromMonitorIsTreatedAs100() {
        env.addExternal(lg, name: "LG")
        transport.set(.brightness, current: 30, max: 0, on: lg)
        transport.set(.volume, current: 10, max: 0, on: lg)
        let manager = makeManager(sync: false)
        XCTAssertEqual(display(lg, in: manager)?.maxBrightness, 100)
        XCTAssertEqual(display(lg, in: manager)?.maxVolume, 100)
        XCTAssertEqual(display(lg, in: manager)?.brightnessPercent, 30)
    }

    func testNoDDCMeansNothingAvailable() {
        env.addExternal(lg, name: "LG")
        let manager = makeManager(sync: false)
        XCTAssertFalse(manager.ddcBrightnessAvailable)
        XCTAssertFalse(manager.ddcVolumeAvailable)
    }

    func testWriteOnlyVolumeAssumesHalfVolumeWhenReadsFail() {
        twoMonitors()
        let manager = makeManager(sync: false, writeOnly: true)
        XCTAssertEqual(display(dell, in: manager)?.volume, 50)
        XCTAssertEqual(display(dell, in: manager)?.maxVolume, 100)
        XCTAssertEqual(display(dell, in: manager)?.ddcVolumeAvailable, true)
        XCTAssertEqual(display(lg, in: manager)?.volume, 20, "a readable monitor keeps its real volume")
    }

    // MARK: - Brightness: cursor-only (sync off)

    func testCursorModeAdjustsOnlyTheDisplayUnderTheCursor() {
        twoMonitors()
        let manager = makeManager(sync: false)
        env.cursor = dell

        manager.adjustBrightness(by: 1)

        XCTAssertEqual(display(dell, in: manager)?.brightness, 76)
        XCTAssertEqual(transport.writtenValues(.brightness, on: dell), [76])
        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [])
        XCTAssertEqual(env.builtInSets, [])
    }

    func testCursorModeHonoursTheBrightnessStep() {
        twoMonitors()
        let manager = makeManager(sync: false)
        prefs.brightnessStep = 2
        env.cursor = lg
        manager.adjustBrightness(by: -1)
        XCTAssertEqual(display(lg, in: manager)?.brightness, 38)
    }

    func testCursorOnBuiltInAdjustsOnlyTheBuiltInPanel() {
        twoMonitors()
        let manager = makeManager(sync: false)
        env.cursor = FakeDisplayEnvironment.builtInID
        env.builtInLevel = 0.5

        manager.adjustBrightness(by: 1)

        XCTAssertEqual(env.builtInLevel ?? 0, 0.5625, accuracy: 1e-6)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testBuiltInBrightnessClampsToOne() {
        let manager = makeManager(sync: false)
        env.cursor = FakeDisplayEnvironment.builtInID
        env.builtInLevel = 0.98
        manager.adjustBrightness(by: 1)
        XCTAssertEqual(env.builtInLevel ?? 0, 1.0, accuracy: 1e-6)
        env.builtInLevel = 0.01
        manager.adjustBrightness(by: -1)
        XCTAssertEqual(env.builtInLevel ?? 1, 0.0, accuracy: 1e-6)
    }

    func testCursorModeDoesNothingWithoutACursorDisplay() {
        twoMonitors()
        let manager = makeManager(sync: false)
        env.cursor = nil
        manager.adjustBrightness(by: 1)
        env.cursor = 999
        manager.adjustBrightness(by: 1)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(env.builtInSets, [])
    }

    // MARK: - Brightness: sync mode

    func testSyncModeFirstKeystrokeSyncsEverythingToTheCursorDisplayThenMovesInLockstep() {
        twoMonitors()
        transport.set(.brightness, current: 80, max: 100, on: lg)
        transport.set(.brightness, current: 20, max: 100, on: dell)
        env.builtInLevel = 0.5
        let manager = makeManager(sync: true)
        env.cursor = lg

        manager.adjustBrightness(by: 1)

        // Dell first jumps to the LG's 80 %, then everything steps 6 %.
        XCTAssertEqual(transport.writtenValues(.brightness, on: dell), [80, 86])
        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [86])
        XCTAssertEqual(display(lg, in: manager)?.brightness, 86)
        XCTAssertEqual(display(dell, in: manager)?.brightness, 86)
        XCTAssertEqual(env.builtInSets.count, 2)
        XCTAssertEqual(env.builtInSets[0], 0.80, accuracy: 1e-6)
        XCTAssertEqual(env.builtInSets[1], 0.8625, accuracy: 1e-6)
    }

    func testSyncHappensOnlyOnTheFirstKeystroke() {
        twoMonitors()
        transport.set(.brightness, current: 80, max: 100, on: lg)
        let manager = makeManager(sync: true)
        env.cursor = lg
        manager.adjustBrightness(by: 1)

        // The Dell is changed on its own buttons; after the cache expires the next key press
        // must step from the Dell's own value rather than re-syncing it to the LG.
        transport.set(.brightness, current: 30, max: 100, on: dell)
        clock.advance(seconds: 3)
        manager.adjustBrightness(by: 1)

        XCTAssertEqual(display(dell, in: manager)?.brightness, 36)
        XCTAssertEqual(display(lg, in: manager)?.brightness, 92)
    }

    func testScreenReconfigurationReArmsTheSync() {
        twoMonitors()
        transport.set(.brightness, current: 80, max: 100, on: lg)
        let manager = makeManager(sync: true)
        env.cursor = lg
        manager.adjustBrightness(by: 1)               // both → 86
        transport.set(.brightness, current: 30, max: 100, on: dell)

        manager.screenParametersChanged()             // display plugged / rearranged
        XCTAssertEqual(display(dell, in: manager)?.brightness, 30, "refresh re-reads the monitors")
        XCTAssertEqual(transport.invalidateCount, 2)

        manager.adjustBrightness(by: 1)
        XCTAssertEqual(transport.writtenValues(.brightness, on: dell).suffix(2), [86, 92], "re-synced to LG's 86 then stepped")
    }

    func testSyncFromBuiltInPanelPullsExternalsToItsLevel() {
        env.addExternal(lg, name: "LG")
        transport.set(.brightness, current: 80, max: 100, on: lg)
        env.builtInLevel = 0.3
        let manager = makeManager(sync: true)
        env.cursor = FakeDisplayEnvironment.builtInID

        manager.adjustBrightness(by: 1)

        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [30, 36])
        XCTAssertEqual(env.builtInSets.count, 1, "the built-in is the sync source, so it's only stepped")
        XCTAssertEqual(env.builtInLevel ?? 0, 0.3625, accuracy: 1e-6)
    }

    func testSyncModeWithoutBuiltInPanelOnlyDrivesExternals() {
        twoMonitors()
        env.builtIn = nil
        let manager = makeManager(sync: true)
        env.cursor = lg
        manager.adjustBrightness(by: -1)
        XCTAssertEqual(display(lg, in: manager)?.brightness, 34)
        XCTAssertEqual(display(dell, in: manager)?.brightness, 34)
        XCTAssertEqual(env.builtInSets, [])
    }

    // MARK: - Brightness: absolute

    func testSetBrightnessConvertsPercentToTheMonitorsRange() {
        env.addExternal(lg, name: "LG")
        transport.set(.brightness, current: 0, max: 255, on: lg)
        let manager = makeManager(sync: false)
        manager.setBrightness(50, for: lg)
        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [127])
        XCTAssertEqual(display(lg, in: manager)?.brightness, 127)
        XCTAssertEqual(display(lg, in: manager)?.brightnessPercent, 50)
    }

    func testKeyPressRightAfterASliderChangeStepsFromTheSliderValue() {
        // Menu-bar slider sets 80 %, then a brightness key within the 2 s cache window must
        // step from 80, not jump back to the value cached by the previous key press.
        env.addExternal(lg, name: "LG")
        transport.set(.brightness, current: 40, max: 100, on: lg)
        let manager = makeManager(sync: false)
        env.cursor = lg

        manager.adjustBrightness(by: 1)            // 46, cached
        manager.setBrightness(80, for: lg)         // slider
        manager.adjustBrightness(by: 1)

        XCTAssertEqual(display(lg, in: manager)?.brightness, 86)
        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [46, 80, 86])
    }

    func testSetBrightnessKeepsOldValueWhenTheWriteFails() {
        env.addExternal(lg, name: "LG")
        transport.set(.brightness, current: 40, max: 100, on: lg)
        let manager = makeManager(sync: false)
        transport.unwritable.insert(.init(display: lg, vcp: VCPCode.brightness.rawValue))
        manager.setBrightness(90, for: lg)
        XCTAssertEqual(display(lg, in: manager)?.brightness, 40)
    }

    func testSetBrightnessIgnoresDisplaysWithoutDDCBrightness() {
        env.addExternal(lg, name: "LG")
        let manager = makeManager(sync: false)
        manager.setBrightness(50, for: lg)
        manager.setBrightness(50, for: 999)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testSetBrightnessForAllIncludesTheBuiltInPanel() {
        twoMonitors()
        let manager = makeManager(sync: false)
        manager.setBrightnessForAll(30)
        XCTAssertEqual(transport.writtenValues(.brightness, on: lg), [30])
        XCTAssertEqual(transport.writtenValues(.brightness, on: dell), [30])
        XCTAssertEqual(env.builtInLevel ?? 0, 0.30, accuracy: 1e-6)
    }

    func testBrightnessPercentForBuiltInAndExternal() {
        twoMonitors()
        let manager = makeManager(sync: false)
        env.builtInLevel = 0.42
        XCTAssertEqual(manager.brightnessPercent(for: FakeDisplayEnvironment.builtInID), 42)
        XCTAssertEqual(manager.brightnessPercent(for: lg), 40)
        XCTAssertNil(manager.brightnessPercent(for: 999))
        env.builtInLevel = nil
        XCTAssertNil(manager.brightnessPercent(for: FakeDisplayEnvironment.builtInID))
    }

    // MARK: - Volume routing

    func testSyncModeDrivesMonitorAndSystemVolumeAndSyncsMonitorFirst() {
        twoMonitors()
        audio.volume = 0.5
        audio.muted = true
        let manager = makeManager(sync: true)

        manager.adjustVolume(by: 1)

        // LG pulled to system 50 %, then stepped; the cache seeded by the sync means no re-read.
        XCTAssertEqual(transport.writtenValues(.volume, on: lg), [50, 56])
        XCTAssertEqual(transport.readCount(.volume, on: lg), 1, "only the refresh read")
        XCTAssertEqual(display(lg, in: manager)?.volume, 56)
        XCTAssertEqual(audio.volume ?? 0, 0.5625, accuracy: 1e-6)
        XCTAssertEqual(audio.muted, false, "volume up unmutes")
    }

    func testDisplayAudioRouteDrivesOnlyDDC() {
        twoMonitors()
        audio.transport = kAudioDeviceTransportTypeHDMI
        audio.name = "LG HDR 4K"
        let manager = makeManager(sync: false)

        manager.adjustVolume(by: 1)

        XCTAssertEqual(display(lg, in: manager)?.volume, 26)
        XCTAssertEqual(audio.setVolumeCalls, [])
        XCTAssertEqual(audio.setMutedCalls, [])
    }

    func testSpeakerRouteDrivesOnlySystemVolume() {
        twoMonitors()
        let manager = makeManager(sync: false)
        audio.volume = 0.5

        manager.adjustVolume(by: -1)

        XCTAssertEqual(audio.volume ?? 0, 0.4375, accuracy: 1e-6)
        XCTAssertEqual(transport.writtenValues(.volume, on: lg), [])
    }

    func testSystemVolumeHonoursTheVolumeStepAndClamps() {
        let manager = makeManager(sync: false)
        prefs.volumeStep = 10
        audio.volume = 0.95
        manager.adjustVolume(by: 1)
        XCTAssertEqual(audio.volume ?? 0, 1.0, accuracy: 1e-6)
        audio.volume = 0.05
        manager.adjustVolume(by: -1)
        XCTAssertEqual(audio.volume ?? 1, 0.0, accuracy: 1e-6)
    }

    func testVolumeDownDoesNotUnmute() {
        let manager = makeManager(sync: false)
        audio.muted = true
        manager.adjustVolume(by: -1)
        XCTAssertEqual(audio.muted, true)
        XCTAssertEqual(audio.setMutedCalls, [])
    }

    func testWriteOnlyVolumeStepsFromInMemoryStateAndSeedsTheCache() {
        twoMonitors()
        audio.transport = kAudioDeviceTransportTypeDisplayPort
        let manager = makeManager(sync: false, writeOnly: true)
        let readsAfterRefresh = transport.readCount(.volume, on: dell)

        manager.adjustVolume(by: 1)
        XCTAssertEqual(transport.writtenValues(.volume, on: dell), [56])
        XCTAssertEqual(display(dell, in: manager)?.volume, 56)

        manager.adjustVolume(by: 1)
        XCTAssertEqual(transport.writtenValues(.volume, on: dell), [56, 62])
        XCTAssertEqual(transport.readCount(.volume, on: dell), readsAfterRefresh + DDCService.maxReadAttempts,
                       "the second press uses the cache seeded by the write instead of re-reading")
    }

    func testWithoutWriteOnlyAnUnreadableMonitorIsLeftAlone() {
        twoMonitors()
        audio.transport = kAudioDeviceTransportTypeDisplayPort
        let manager = makeManager(sync: false, writeOnly: false)
        manager.adjustVolume(by: 1)
        XCTAssertEqual(transport.writtenValues(.volume, on: dell), [])
        XCTAssertNil(display(dell, in: manager)?.volume)
    }

    func testSetVolumeSeedsTheCache() {
        twoMonitors()
        audio.transport = kAudioDeviceTransportTypeHDMI
        let manager = makeManager(sync: false)
        manager.setVolume(70, for: lg)
        manager.adjustVolume(by: 1)
        XCTAssertEqual(transport.writtenValues(.volume, on: lg), [70, 76])
        XCTAssertEqual(transport.readCount(.volume, on: lg), 1, "only the refresh read")
    }

    func testCurrentVolumePercentFollowsTheRoute() {
        twoMonitors()
        let manager = makeManager(sync: false)
        audio.volume = 0.33
        XCTAssertEqual(manager.currentVolumePercent(), 33)
        audio.transport = kAudioDeviceTransportTypeHDMI
        XCTAssertEqual(manager.currentVolumePercent(), 20)
    }

    // MARK: - Mute

    func testMuteOnDisplayAudioTogglesDDCVolume() {
        env.addExternal(lg, name: "LG")
        transport.set(.volume, current: 40, max: 100, on: lg)
        audio.transport = kAudioDeviceTransportTypeHDMI
        let manager = makeManager(sync: false)

        XCTAssertTrue(manager.toggleMute())
        XCTAssertEqual(display(lg, in: manager)?.volume, 0)
        XCTAssertFalse(manager.toggleMute())
        XCTAssertEqual(display(lg, in: manager)?.volume, 50)
        XCTAssertEqual(audio.setMutedCalls, [], "system mute untouched when audio goes to the monitor")
    }

    func testMuteOnSpeakersTogglesSystemMuteOnly() {
        twoMonitors()
        let manager = makeManager(sync: false)
        audio.muted = false
        XCTAssertTrue(manager.toggleMute())
        XCTAssertEqual(audio.muted, true)
        XCTAssertFalse(manager.toggleMute())
        XCTAssertEqual(audio.muted, false)
        XCTAssertEqual(transport.writtenValues(.volume, on: lg), [])
    }

    func testMuteInSyncModeMutesBothAndReportsSystemState() {
        env.addExternal(lg, name: "LG")
        transport.set(.volume, current: 40, max: 100, on: lg)
        audio.muted = false
        let manager = makeManager(sync: true)
        XCTAssertTrue(manager.toggleMute())
        XCTAssertEqual(display(lg, in: manager)?.volume, 0)
        XCTAssertEqual(audio.muted, true)
    }

    func testMuteWithMixedMonitorsSilencesEverything() {
        // KNOWN BUG (reported, not fixed here): with several monitors each one is toggled
        // independently and the returned state is the LAST monitor's. If one monitor is
        // already at 0, pressing Mute unmutes it to 50 % and the OSD says "unmuted" while
        // the other monitor was just silenced.
        twoMonitors()
        transport.set(.volume, current: 40, max: 100, on: lg)
        transport.set(.volume, current: 0, max: 100, on: dell)
        audio.transport = kAudioDeviceTransportTypeHDMI
        let manager = makeManager(sync: false)

        XCTExpectFailure("toggleMute toggles each display independently and reports the last display's state")
        let muted = manager.toggleMute()
        XCTAssertTrue(muted)
        XCTAssertEqual(display(lg, in: manager)?.volume, 0)
        XCTAssertEqual(display(dell, in: manager)?.volume, 0)
    }

    func testUnmuteRestoresThePreviousVolume() {
        // KNOWN LIMITATION (reported): DDC "mute" writes volume 0 and unmute always writes
        // 50 %, so a monitor at 20 % comes back much louder than before.
        env.addExternal(lg, name: "LG")
        transport.set(.volume, current: 20, max: 100, on: lg)
        audio.transport = kAudioDeviceTransportTypeHDMI
        let manager = makeManager(sync: false)

        _ = manager.toggleMute()
        _ = manager.toggleMute()
        XCTExpectFailure("unmute restores a fixed 50% instead of the pre-mute volume")
        XCTAssertEqual(display(lg, in: manager)?.volume, 20)
    }

    // MARK: - Audio output detection

    func testHDMIAndDisplayPortOutputAreDisplayAudio() {
        let manager = makeManager(sync: false)
        audio.name = "Something"
        audio.transport = kAudioDeviceTransportTypeHDMI
        XCTAssertTrue(manager.isAudioOutputDisplayBased())
        audio.transport = kAudioDeviceTransportTypeDisplayPort
        XCTAssertTrue(manager.isAudioOutputDisplayBased())
    }

    func testUSBOrThunderboltHubCountsOnlyWhenNamedAfterAMonitor() {
        twoMonitors()
        let manager = makeManager(sync: false)
        audio.transport = kAudioDeviceTransportTypeUSB
        audio.name = "LG HDR 4K"
        XCTAssertTrue(manager.isAudioOutputDisplayBased())
        audio.name = "USB Audio DAC"
        XCTAssertFalse(manager.isAudioOutputDisplayBased())
        audio.transport = kAudioDeviceTransportTypeThunderbolt
        audio.name = "DELL U2723QE"
        XCTAssertTrue(manager.isAudioOutputDisplayBased())
    }

    func testSpeakersBluetoothAndMissingDeviceAreNotDisplayAudio() {
        twoMonitors()
        let manager = makeManager(sync: false)
        XCTAssertFalse(manager.isAudioOutputDisplayBased())
        audio.transport = kAudioDeviceTransportTypeBluetooth
        audio.name = "AirPods Pro"
        XCTAssertFalse(manager.isAudioOutputDisplayBased())
        audio.transport = nil
        audio.name = nil
        XCTAssertFalse(manager.isAudioOutputDisplayBased())
        audio.hasDevice = false
        audio.transport = kAudioDeviceTransportTypeHDMI
        XCTAssertFalse(manager.isAudioOutputDisplayBased())
    }

    func testUnknownTransportFallsBackToNameMatch() {
        twoMonitors()
        let manager = makeManager(sync: false)
        audio.transport = nil
        audio.name = "LG HDR 4K"
        XCTAssertTrue(manager.isAudioOutputDisplayBased())
    }

    func testIsDisplayAudioShortCircuitsForHDMIAndDisplayPort() {
        var asked = 0
        XCTAssertTrue(DisplayManager.isDisplayAudio(transportType: kAudioDeviceTransportTypeHDMI) { asked += 1; return false })
        XCTAssertTrue(DisplayManager.isDisplayAudio(transportType: kAudioDeviceTransportTypeDisplayPort) { asked += 1; return false })
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(DisplayManager.isDisplayAudio(transportType: kAudioDeviceTransportTypeUSB) { false })
        XCTAssertTrue(DisplayManager.isDisplayAudio(transportType: kAudioDeviceTransportTypeUSB) { true })
        XCTAssertFalse(DisplayManager.isDisplayAudio(transportType: kAudioDeviceTransportTypeBuiltIn) { false })
        XCTAssertTrue(DisplayManager.isDisplayAudio(transportType: nil) { true })
    }

    // MARK: - Name matching

    private func matches(_ audioName: String, _ displays: [String]) -> Bool {
        DisplayManager.audioNameMatchesDisplay(audioName: audioName, displayNames: displays)
    }

    func testNameContainmentMatches() {
        XCTAssertTrue(matches("LG HDR 4K", ["LG HDR 4K (2)"]))
        XCTAssertTrue(matches("Studio Display", ["Studio Display"]))
    }

    func testNameMatchIsCaseInsensitive() {
        XCTAssertTrue(matches("dell u2723qe", ["DELL U2723QE"]))
    }

    func testReorderedWordsMatch() {
        XCTAssertTrue(matches("4K LG HDR", ["LG HDR 4K"]))
    }

    func testTwoSharedWordsMatch() {
        XCTAssertTrue(matches("LG ULTRAFINE Audio", ["LG UltraFine Display"]))
    }

    func testSingleSharedWordDoesNotMatch() {
        XCTAssertFalse(matches("LG Speakers", ["LG ULTRAFINE"]))
        XCTAssertFalse(matches("MacBook Pro Speakers", ["DELL U2723QE"]))
    }

    func testAnyOfSeveralDisplaysCanMatch() {
        XCTAssertTrue(matches("DELL U2723QE", ["LG HDR 4K", "DELL U2723QE"]))
        XCTAssertFalse(matches("DELL U2723QE", []))
    }

    func testEmptyAudioNameMatchesNothing() {
        XCTAssertFalse(matches("", ["LG HDR 4K"]))
    }

    // MARK: - ExternalDisplay

    func testPercentRounding() {
        var display = ExternalDisplay(id: 1, name: "X", vendorNumber: 0, modelNumber: 0)
        XCTAssertEqual(display.brightnessPercent, 0, "no DDC → 0")
        display.brightness = 1
        display.maxBrightness = 3
        XCTAssertEqual(display.brightnessPercent, 33)
        display.brightness = 2
        XCTAssertEqual(display.brightnessPercent, 67)
        display.maxBrightness = 0
        XCTAssertEqual(display.brightnessPercent, 0, "max 0 must not divide by zero")

        display.volume = 127
        display.maxVolume = 255
        XCTAssertEqual(display.volumePercent, 50)
        display.maxVolume = nil
        XCTAssertEqual(display.volumePercent, 0)
    }
}
