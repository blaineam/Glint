import XCTest
@testable import Glint

/// Whether Glint swallows a media key. Consuming a key it can't act on kills the user's
/// brightness/volume keys entirely, so the pass-through matrix matters as much as routing.
final class MediaKeyTests: XCTestCase {
    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h, spelled out as an independent oracle.
    private let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    private let play = 16, next = 17, illuminationUp = 21

    private func data1(keyCode: Int, state: Int) -> Int { (keyCode << 16) | (state << 8) }

    private func action(
        _ keyCode: Int, down: Bool = true, prefs: Preferences,
        ddcBrightness: Bool = true, ddcVolume: Bool = true
    ) -> MediaKeyInterceptor.Action {
        MediaKeyInterceptor.action(
            for: MediaKey(keyCode: keyCode, isDown: down), prefs: prefs,
            ddcBrightnessAvailable: ddcBrightness, ddcVolumeAvailable: ddcVolume
        )
    }

    // MARK: decode

    func testDecodesKeyDown() {
        let key = MediaKey(data1: data1(keyCode: brightnessUp, state: 0x0A))
        XCTAssertEqual(key, MediaKey(keyCode: brightnessUp, isDown: true))
    }

    func testDecodesKeyUpAndRepeatFlag() {
        XCTAssertEqual(MediaKey(data1: data1(keyCode: soundDown, state: 0x0B)), MediaKey(keyCode: soundDown, isDown: false))
        // Low bit of the flags byte is the repeat flag; state byte stays 0x0A for a held key.
        XCTAssertEqual(MediaKey(data1: data1(keyCode: soundUp, state: 0x0A) | 0x1), MediaKey(keyCode: soundUp, isDown: true))
    }

    func testDecodeIgnoresBitsAboveThe32BitPayload() {
        let key = MediaKey(data1: (1 << 40) | data1(keyCode: mute, state: 0x0A))
        XCTAssertEqual(key, MediaKey(keyCode: mute, isDown: true))
    }

    // MARK: routing

    func testDefaultPreferencesRouteEveryKey() {
        let (prefs, _) = makePreferences()
        XCTAssertEqual(action(brightnessUp, prefs: prefs), .brightness(1))
        XCTAssertEqual(action(brightnessDown, prefs: prefs), .brightness(-1))
        XCTAssertEqual(action(soundUp, prefs: prefs), .volume(1))
        XCTAssertEqual(action(soundDown, prefs: prefs), .volume(-1))
        XCTAssertEqual(action(mute, prefs: prefs), .toggleMute)
    }

    func testKeyUpAlwaysPassesThrough() {
        let (prefs, _) = makePreferences()
        for key in [brightnessUp, brightnessDown, soundUp, soundDown, mute] {
            XCTAssertEqual(action(key, down: false, prefs: prefs), .passThrough, "key \(key)")
        }
    }

    func testUnrelatedMediaKeysPassThrough() {
        let (prefs, _) = makePreferences { $0.set(true, forKey: "alwaysInterceptVolume"); $0.set(true, forKey: "alwaysInterceptBrightness") }
        for key in [play, next, illuminationUp, 99] {
            XCTAssertEqual(action(key, prefs: prefs), .passThrough, "key \(key)")
        }
    }

    func testBrightnessInterceptionDisabledPassesThrough() {
        let (prefs, _) = makePreferences { $0.set(false, forKey: "interceptBrightness"); $0.set(true, forKey: "alwaysInterceptBrightness") }
        XCTAssertEqual(action(brightnessUp, prefs: prefs), .passThrough)
        XCTAssertEqual(action(brightnessDown, prefs: prefs), .passThrough)
        XCTAssertEqual(action(soundUp, prefs: prefs), .volume(1), "volume is independent")
    }

    func testBrightnessWithoutDDCPassesThroughToMacOS() {
        let (prefs, _) = makePreferences()
        XCTAssertEqual(action(brightnessUp, prefs: prefs, ddcBrightness: false), .passThrough)
        XCTAssertEqual(action(brightnessDown, prefs: prefs, ddcBrightness: false), .passThrough)
    }

    func testAlwaysInterceptBrightnessConsumesWithoutDDC() {
        let (prefs, _) = makePreferences { $0.set(true, forKey: "alwaysInterceptBrightness") }
        XCTAssertEqual(action(brightnessUp, prefs: prefs, ddcBrightness: false), .brightness(1))
    }

    func testVolumeInterceptionDisabledPassesThroughVolumeAndMute() {
        let (prefs, _) = makePreferences { $0.set(false, forKey: "interceptVolume"); $0.set(true, forKey: "alwaysInterceptVolume") }
        XCTAssertEqual(action(soundUp, prefs: prefs), .passThrough)
        XCTAssertEqual(action(soundDown, prefs: prefs), .passThrough)
        XCTAssertEqual(action(mute, prefs: prefs), .passThrough)
        XCTAssertEqual(action(brightnessUp, prefs: prefs), .brightness(1))
    }

    func testVolumeWithoutDDCPassesThroughUnlessAlwaysIntercept() {
        let (prefs, _) = makePreferences()
        XCTAssertEqual(action(soundUp, prefs: prefs, ddcVolume: false), .passThrough)
        XCTAssertEqual(action(mute, prefs: prefs, ddcVolume: false), .passThrough)

        prefs.alwaysInterceptVolume = true
        XCTAssertEqual(action(soundUp, prefs: prefs, ddcVolume: false), .volume(1))
        XCTAssertEqual(action(mute, prefs: prefs, ddcVolume: false), .toggleMute)
    }

    func testDDCAvailabilityIsOnlyQueriedWhenNeeded() {
        // The availability check touches DisplayManager.shared in the app; it must not be
        // evaluated for key-ups or when "always intercept" already decides.
        let (prefs, _) = makePreferences { $0.set(true, forKey: "alwaysInterceptBrightness") }
        var queried = 0
        func probe() -> Bool { queried += 1; return true }
        _ = MediaKeyInterceptor.action(for: MediaKey(keyCode: brightnessUp, isDown: false), prefs: prefs,
                                       ddcBrightnessAvailable: probe(), ddcVolumeAvailable: probe())
        _ = MediaKeyInterceptor.action(for: MediaKey(keyCode: brightnessUp, isDown: true), prefs: prefs,
                                       ddcBrightnessAvailable: probe(), ddcVolumeAvailable: probe())
        XCTAssertEqual(queried, 0)
    }
}
