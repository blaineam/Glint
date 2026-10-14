import AppKit
import CoreAudio
import XCTest
@testable import Glint

/// The real CoreAudio / CoreGraphics / IOKit-backed implementations, exercised through
/// read-only queries only. Nothing here changes volume, mute, brightness or sends a DDC
/// command: the mutating calls are only ever aimed at `kAudioObjectUnknown` (CoreAudio
/// refuses them), the built-in panel's brightness setter is never called, and the IOKit DDC
/// transport is only handed a built-in display ID (which it rejects before any I2C traffic).
final class SystemBackendsTests: XCTestCase {
    // MARK: - CoreAudio

    func testDefaultOutputDeviceIsDescribedConsistently() {
        let audio = CoreAudioSystemAudio()
        guard let device = audio.defaultOutputDevice() else { return }   // no output device on this runner
        XCTAssertNotEqual(device, AudioDeviceID(kAudioObjectUnknown))
        if let name = audio.deviceName(of: device) { XCTAssertFalse(name.isEmpty) }
        _ = audio.transportType(of: device)
        if let volume = audio.volume(of: device) {
            XCTAssertGreaterThanOrEqual(volume, 0)
            XCTAssertLessThanOrEqual(volume, 1)
        }
        _ = audio.isMuted(device)
    }

    func testUnknownAudioDeviceAnswersNothing() {
        let audio = CoreAudioSystemAudio()
        let unknown = AudioDeviceID(kAudioObjectUnknown)
        XCTAssertNil(audio.deviceName(of: unknown))
        XCTAssertNil(audio.transportType(of: unknown))
        XCTAssertNil(audio.volume(of: unknown))
        XCTAssertNil(audio.isMuted(unknown))
        // CoreAudio reports the unknown object as not settable, so neither call writes anything.
        audio.setVolume(0.5, on: unknown)
        audio.setMuted(true, on: unknown)
    }

    // MARK: - Displays

    func testExternalDisplaysExcludeTheBuiltInPanelAndCarryIdentity() {
        let environment = SystemDisplayEnvironment()
        for display in environment.externalDisplays() {
            XCTAssertFalse(environment.isBuiltIn(display.id))
            XCTAssertFalse(display.name.isEmpty)
            XCTAssertEqual(display.vendorNumber, CGDisplayVendorNumber(display.id))
            XCTAssertEqual(display.modelNumber, CGDisplayModelNumber(display.id))
            XCTAssertNil(display.brightness, "the environment reports facts only; DDC state is read by DisplayManager")
        }
    }

    func testBuiltInPanelFactsAgreeWithCoreGraphics() {
        let environment = SystemDisplayEnvironment()
        let builtIn = environment.builtInDisplayID()
        if let builtIn {
            XCTAssertTrue(environment.isBuiltIn(builtIn))
            XCTAssertNotEqual(CGDisplayIsBuiltin(builtIn), 0)
            if let level = environment.builtInBrightness() {
                XCTAssertGreaterThanOrEqual(level, 0)
                XCTAssertLessThanOrEqual(level, 1)
            }
        } else {
            XCTAssertNil(environment.builtInBrightness())
        }
    }

    func testDisplayUnderCursorIsAnActiveDisplayWhenKnown() {
        let environment = SystemDisplayEnvironment()
        if let id = environment.displayUnderCursor() {
            var active = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetActiveDisplayList(16, &active, &count)
            XCTAssertTrue(active.prefix(Int(count)).contains(id))
        }
    }

    // MARK: - IOKit DDC transport (no bus traffic)

    func testIOKitTransportRejectsABuiltInDisplayWithoutTouchingTheBus() {
        let environment = SystemDisplayEnvironment()
        guard let builtIn = environment.builtInDisplayID() else { return }   // desktop Mac: no safe display to aim at
        let transport = IOKitDDCTransport()
        transport.invalidatePortCache()
        // Built-in panels have no DDC: the transport bails out before enumerating any port.
        switch transport.read(command: VCPCode.brightness.rawValue, from: builtIn) {
        case .value: XCTFail("a built-in panel cannot answer DDC")
        case .noReply, .unavailable: break
        }
        XCTAssertFalse(transport.write(command: VCPCode.brightness.rawValue, value: 50, to: builtIn))
    }
}
