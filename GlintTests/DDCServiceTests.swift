import XCTest
@testable import Glint

/// DDCService's cache, clamping and retry policy over a fake transport and fake clock.
final class DDCServiceTests: XCTestCase {
    private let display: CGDirectDisplayID = 5
    private var transport: FakeDDCTransport!
    private var clock: FakeClock!
    private var sleeper: SleepRecorder!
    private var ddc: DDCService!

    override func setUp() {
        super.setUp()
        transport = FakeDDCTransport()
        clock = FakeClock()
        sleeper = SleepRecorder()
        ddc = makeDDC(transport, clock: clock, sleeper: sleeper)
    }

    // MARK: adjust

    func testAdjustWritesCurrentPlusDelta() {
        transport.set(.brightness, current: 40, max: 100, on: display)
        let result = ddc.adjust(vcp: .brightness, by: 6, on: display)
        XCTAssertEqual(result?.currentValue, 46)
        XCTAssertEqual(result?.maxValue, 100)
        XCTAssertEqual(transport.writtenValues(.brightness, on: display), [46])
    }

    func testAdjustUpClampsAtMax() {
        transport.set(.brightness, current: 95, max: 100, on: display)
        XCTAssertEqual(ddc.adjust(vcp: .brightness, by: 10, on: display)?.currentValue, 100)
        XCTAssertEqual(transport.writtenValues(.brightness, on: display), [100])
    }

    func testAdjustUpClampsAtNonStandardMax() {
        transport.set(.volume, current: 30, max: 32, on: display)
        XCTAssertEqual(ddc.adjust(vcp: .volume, by: 5, on: display)?.currentValue, 32)
    }

    func testAdjustDownClampsAtZero() {
        transport.set(.brightness, current: 3, max: 100, on: display)
        XCTAssertEqual(ddc.adjust(vcp: .brightness, by: -10, on: display)?.currentValue, 0)
        XCTAssertEqual(transport.writtenValues(.brightness, on: display), [0])
    }

    func testAdjustReturnsNilWhenTheReadFails() {
        transport.unreadable.insert(.init(display: display, vcp: VCPCode.brightness.rawValue))
        XCTAssertNil(ddc.adjust(vcp: .brightness, by: 1, on: display))
        XCTAssertTrue(transport.writes.isEmpty, "never write a guess when the current value is unknown")
    }

    // MARK: cache

    func testSecondAdjustWithinTTLUsesCacheAndAccumulates() {
        transport.set(.brightness, current: 40, max: 100, on: display)
        _ = ddc.adjust(vcp: .brightness, by: 6, on: display)
        clock.advance(seconds: 1.9)
        let second = ddc.adjust(vcp: .brightness, by: 6, on: display)
        XCTAssertEqual(second?.currentValue, 52)
        XCTAssertEqual(transport.readCount(.brightness, on: display), 1, "rate-limited monitors must not be re-read per key press")
    }

    func testCacheExpiresAfterTwoSeconds() {
        transport.set(.brightness, current: 40, max: 100, on: display)
        _ = ddc.adjust(vcp: .brightness, by: 6, on: display)
        // The user changed brightness on the monitor's own buttons meanwhile.
        transport.set(.brightness, current: 10, max: 100, on: display)
        clock.advance(seconds: 2.0)
        XCTAssertEqual(ddc.adjust(vcp: .brightness, by: 6, on: display)?.currentValue, 16)
        XCTAssertEqual(transport.readCount(.brightness, on: display), 2)
    }

    func testFailedWriteDoesNotUpdateTheCache() {
        let key = FakeDDCTransport.Key(display: display, vcp: VCPCode.brightness.rawValue)
        transport.set(.brightness, current: 40, max: 100, on: display)
        transport.unwritable.insert(key)
        XCTAssertNil(ddc.adjust(vcp: .brightness, by: 6, on: display))

        transport.unwritable.remove(key)
        // Still within TTL: the cache must hold the read value (40), not the failed 46.
        XCTAssertEqual(ddc.adjust(vcp: .brightness, by: 6, on: display)?.currentValue, 46)
    }

    func testUpdateCacheSeedsTheNextAdjustWithoutARead() {
        transport.set(.volume, current: 0, max: 100, on: display)
        ddc.updateCache(vcp: .volume, displayID: display, newValue: 70, maxValue: 100)
        XCTAssertEqual(ddc.adjust(vcp: .volume, by: 5, on: display)?.currentValue, 75)
        XCTAssertEqual(transport.readCount(.volume, on: display), 0)
    }

    func testCacheIsKeyedPerDisplayAndVCP() {
        let other: CGDirectDisplayID = 6
        transport.set(.brightness, current: 40, max: 100, on: display)
        transport.set(.volume, current: 20, max: 100, on: display)
        transport.set(.brightness, current: 80, max: 100, on: other)

        _ = ddc.adjust(vcp: .brightness, by: 1, on: display)
        XCTAssertEqual(ddc.adjust(vcp: .volume, by: 1, on: display)?.currentValue, 21)
        XCTAssertEqual(ddc.adjust(vcp: .brightness, by: 1, on: other)?.currentValue, 81)
        XCTAssertEqual(transport.reads.count, 3)
    }

    func testCachedReadReportsHitsAndMisses() {
        transport.set(.brightness, current: 40, max: 100, on: display)
        let miss = ddc.cachedRead(vcp: .brightness, from: display)
        XCTAssertEqual(miss?.wasCacheHit, false)
        XCTAssertEqual(miss?.result.currentValue, 40)

        transport.set(.brightness, current: 99, max: 100, on: display)
        let hit = ddc.cachedRead(vcp: .brightness, from: display)
        XCTAssertEqual(hit?.wasCacheHit, true)
        XCTAssertEqual(hit?.result.currentValue, 40)

        clock.advance(seconds: 3)
        XCTAssertEqual(ddc.cachedRead(vcp: .brightness, from: display)?.result.currentValue, 99)
    }

    func testPlainReadBypassesCache() {
        transport.set(.brightness, current: 40, max: 100, on: display)
        ddc.updateCache(vcp: .brightness, displayID: display, newValue: 10, maxValue: 100)
        XCTAssertEqual(ddc.read(vcp: .brightness, from: display)?.currentValue, 40)
    }

    // MARK: retries and cooldown

    /// The production 100 ms cooldown, with sleeps recorded instead of performed.
    private func slowDDC() -> DDCService {
        let sleeper = self.sleeper!
        let clock = self.clock!
        return DDCService(transport: transport, busCooldownMicros: 100_000,
                          sleep: { sleeper.sleep($0) }, now: { clock.nanos })
    }

    func testReadRetriesThreeTimesWithExponentialBackoffThenGivesUp() {
        let ddc = slowDDC()
        transport.unreadable.insert(.init(display: display, vcp: VCPCode.brightness.rawValue))
        XCTAssertNil(ddc.read(vcp: .brightness, from: display))
        XCTAssertEqual(transport.readCount(.brightness, on: display), 3)
        XCTAssertEqual(sleeper.sleeps, [100_000, 200_000, 400_000])
    }

    func testReadSucceedsOnARetry() {
        let key = FakeDDCTransport.Key(display: display, vcp: VCPCode.volume.rawValue)
        transport.set(.volume, current: 33, max: 100, on: display)
        transport.failReadsBeforeSuccess[key] = 2
        XCTAssertEqual(ddc.read(vcp: .volume, from: display)?.currentValue, 33)
        XCTAssertEqual(transport.readCount(.volume, on: display), 3)
    }

    func testUnavailableDisplayIsNotRetried() {
        transport.unavailableDisplays.insert(display)
        XCTAssertNil(ddc.read(vcp: .brightness, from: display))
        XCTAssertEqual(transport.reads.count, 1)
    }

    func testWriteWaitsOneCooldownFirst() {
        let ddc = slowDDC()
        XCTAssertTrue(ddc.write(vcp: .brightness, value: 10, to: display))
        XCTAssertEqual(sleeper.sleeps, [100_000])
        XCTAssertEqual(transport.writtenValues(.brightness, on: display), [10])
    }

    func testWriteReportsTransportFailure() {
        transport.unwritable.insert(.init(display: display, vcp: VCPCode.volume.rawValue))
        XCTAssertFalse(ddc.write(vcp: .volume, value: 10, to: display))
    }

    func testInvalidateServiceCacheForgetsPortMapping() {
        ddc.invalidateServiceCache()
        XCTAssertEqual(transport.invalidateCount, 1)
    }
}
