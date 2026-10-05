import AppKit
import XCTest
import CoreAudio
@testable import Glint

// MARK: - Preferences

extension XCTestCase {
    /// A Preferences instance backed by a throwaway UserDefaults suite, so tests never read
    /// or write the real com.blainemiller.Glint domain and never touch SMAppService. The
    /// suite is deleted when the test finishes.
    func makePreferences(
        configure: (UserDefaults) -> Void = { _ in },
        loginItem: @escaping (Bool) -> Void = { _ in }
    ) -> (Preferences, UserDefaults) {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        configure(defaults)
        return (Preferences(defaults: defaults, loginItem: loginItem), defaults)
    }
}

// MARK: - Clock / sleep

final class FakeClock {
    var nanos: UInt64 = 1_000_000_000
    func advance(seconds: Double) { nanos += UInt64(seconds * 1_000_000_000) }
}

final class SleepRecorder {
    private(set) var sleeps: [useconds_t] = []
    func sleep(_ micros: useconds_t) { sleeps.append(micros) }
}

// MARK: - DDC transport

/// In-memory monitor(s): each (display, VCP) has a current/max value, and can be made
/// unreadable, unwritable, or unavailable. Records every read and write.
final class FakeDDCTransport: DDCTransport {
    struct Key: Hashable {
        let display: CGDirectDisplayID
        let vcp: UInt8
    }

    var values: [Key: DDCReadResult] = [:]
    var unreadable: Set<Key> = []
    var unwritable: Set<Key> = []
    var unavailableDisplays: Set<CGDirectDisplayID> = []
    /// Number of failing read attempts before a read succeeds (per key).
    var failReadsBeforeSuccess: [Key: Int] = [:]

    private(set) var reads: [Key] = []
    private(set) var writes: [(key: Key, value: UInt16)] = []
    private(set) var invalidateCount = 0

    func set(_ vcp: VCPCode, current: UInt16, max: UInt16, on display: CGDirectDisplayID) {
        values[Key(display: display, vcp: vcp.rawValue)] = DDCReadResult(currentValue: current, maxValue: max)
    }

    func current(_ vcp: VCPCode, on display: CGDirectDisplayID) -> UInt16? {
        values[Key(display: display, vcp: vcp.rawValue)]?.currentValue
    }

    func readCount(_ vcp: VCPCode, on display: CGDirectDisplayID) -> Int {
        reads.filter { $0 == Key(display: display, vcp: vcp.rawValue) }.count
    }

    func writtenValues(_ vcp: VCPCode, on display: CGDirectDisplayID) -> [UInt16] {
        writes.filter { $0.key == Key(display: display, vcp: vcp.rawValue) }.map(\.value)
    }

    func read(command: UInt8, from displayID: CGDirectDisplayID) -> DDCReadAttempt {
        let key = Key(display: displayID, vcp: command)
        reads.append(key)
        if unavailableDisplays.contains(displayID) { return .unavailable }
        if unreadable.contains(key) { return .noReply }
        if let remaining = failReadsBeforeSuccess[key], remaining > 0 {
            failReadsBeforeSuccess[key] = remaining - 1
            return .noReply
        }
        guard let value = values[key] else { return .noReply }
        return .value(value)
    }

    func write(command: UInt8, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        let key = Key(display: displayID, vcp: command)
        writes.append((key, value))
        if unavailableDisplays.contains(displayID) || unwritable.contains(key) { return false }
        let max = values[key]?.maxValue ?? 100
        values[key] = DDCReadResult(currentValue: value, maxValue: max)
        return true
    }

    func invalidatePortCache() {
        invalidateCount += 1
    }
}

func makeDDC(_ transport: FakeDDCTransport, clock: FakeClock = FakeClock(), sleeper: SleepRecorder = SleepRecorder()) -> DDCService {
    DDCService(
        transport: transport,
        busCooldownMicros: 0,
        sleep: { sleeper.sleep($0) },
        now: { clock.nanos }
    )
}

// MARK: - Audio

final class FakeSystemAudio: SystemAudio {
    static let device: AudioDeviceID = 42

    var hasDevice = true
    var name: String? = "MacBook Pro Speakers"
    var transport: UInt32? = kAudioDeviceTransportTypeBuiltIn
    var volume: Float? = 0.5
    var muted: Bool? = false
    private(set) var setVolumeCalls: [Float] = []
    private(set) var setMutedCalls: [Bool] = []

    func defaultOutputDevice() -> AudioDeviceID? { hasDevice ? Self.device : nil }
    func deviceName(of device: AudioDeviceID) -> String? { name }
    func transportType(of device: AudioDeviceID) -> UInt32? { transport }
    func volume(of device: AudioDeviceID) -> Float? { volume }
    func setVolume(_ volume: Float, on device: AudioDeviceID) {
        setVolumeCalls.append(volume)
        self.volume = volume
    }
    func isMuted(_ device: AudioDeviceID) -> Bool? { muted }
    func setMuted(_ muted: Bool, on device: AudioDeviceID) {
        setMutedCalls.append(muted)
        self.muted = muted
    }
}

// MARK: - Display environment

final class FakeDisplayEnvironment: DisplayEnvironment {
    static let builtInID: CGDirectDisplayID = 1

    var externals: [ExternalDisplay] = []
    var builtIn: CGDirectDisplayID? = FakeDisplayEnvironment.builtInID
    var builtInLevel: Float? = 0.5
    var cursor: CGDirectDisplayID?
    private(set) var builtInSets: [Float] = []

    func addExternal(_ id: CGDirectDisplayID, name: String) {
        externals.append(ExternalDisplay(id: id, name: name, vendorNumber: 0x1E6D, modelNumber: id))
    }

    func externalDisplays() -> [ExternalDisplay] { externals }
    func isBuiltIn(_ displayID: CGDirectDisplayID) -> Bool { builtIn == displayID }
    func builtInDisplayID() -> CGDirectDisplayID? { builtIn }
    func builtInBrightness() -> Float? { builtIn == nil ? nil : builtInLevel }
    func setBuiltInBrightness(_ brightness: Float) {
        guard builtIn != nil else { return }
        builtInSets.append(brightness)
        builtInLevel = brightness
    }
    func displayUnderCursor() -> CGDirectDisplayID? { cursor }
}
