import XCTest
@testable import Glint

/// Which DCPAVServiceProxy (physical port) DDC goes to. Regression guard for v1.4.4: on a
/// Mac mini every port publishes a proxy even when empty, so "display N = proxy N" wrote
/// to an empty HDMI port while the monitor sat on Thunderbolt.
final class DDCPortSelectionTests: XCTestCase {
    private func order(
        proxies: Int, position: Int?, displays: Int, cached: Int? = nil, edid: [Int] = []
    ) -> [Int] {
        DDCPortSelection.candidateOrder(
            proxyCount: proxies, displayPosition: position, externalDisplayCount: displays,
            cachedIndex: cached, edidMatchIndices: edid
        )
    }

    // MARK: candidateOrder

    func testSingleDisplaySinglePort() {
        XCTAssertEqual(order(proxies: 1, position: 0, displays: 1), [0])
    }

    func testNoProxiesYieldsNoCandidates() {
        XCTAssertEqual(order(proxies: 0, position: 0, displays: 1), [])
    }

    func testMacMiniOneDisplayTwoPortsProbesBothGuessFirst() {
        // HDMI (index 0) empty, Thunderbolt (index 1) has the monitor: both must be tried.
        XCTAssertEqual(order(proxies: 2, position: 0, displays: 1), [0, 1])
        XCTAssertEqual(order(proxies: 3, position: 0, displays: 1), [0, 1, 2])
    }

    func testTwoDisplaysTwoPortsDoNotFallThroughToTheNeighbour() {
        // Without EDID evidence each display only gets its positional port, so a monitor
        // without DDC can't end up driving the other monitor.
        XCTAssertEqual(order(proxies: 2, position: 0, displays: 2), [0])
        XCTAssertEqual(order(proxies: 2, position: 1, displays: 2), [1])
    }

    func testTwoDisplaysThreePortsShareOnlyTheUnclaimedPort() {
        XCTAssertEqual(order(proxies: 3, position: 0, displays: 2), [0, 2])
        XCTAssertEqual(order(proxies: 3, position: 1, displays: 2), [1, 2])
    }

    func testEDIDMatchOutranksPositionalGuessEvenOnAClaimedPort() {
        // Display 0 is physically on port 1 (CG order and port order disagree).
        XCTAssertEqual(order(proxies: 2, position: 0, displays: 2, edid: [1]), [1, 0])
    }

    func testCachedPortComesFirst() {
        XCTAssertEqual(order(proxies: 3, position: 0, displays: 1, cached: 2, edid: [1]), [2, 1, 0])
    }

    func testNoDuplicatesWhenSourcesAgree() {
        let result = order(proxies: 2, position: 0, displays: 1, cached: 1, edid: [1])
        XCTAssertEqual(result, [1, 0])
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testDisplayMissingFromCGListGuessesPortZero() {
        XCTAssertEqual(order(proxies: 2, position: nil, displays: 1), [0, 1])
    }

    func testMoreDisplaysThanPortsClampsTheGuess() {
        // Third display, two ports: guess clamps to the last port, other ports are claimed.
        XCTAssertEqual(order(proxies: 2, position: 2, displays: 3), [1])
    }

    func testAllIndicesAreInRange() {
        for proxies in 1...4 {
            for displays in 1...4 {
                for position in 0..<displays {
                    let result = order(proxies: proxies, position: position, displays: displays)
                    XCTAssertFalse(result.isEmpty)
                    XCTAssertTrue(result.allSatisfy { (0..<proxies).contains($0) }, "\(proxies)/\(displays)/\(position): \(result)")
                }
            }
        }
    }

    // MARK: writeTarget

    func testCachedPortWinsWithoutProbing() {
        var probed = 0
        let target = DDCPortSelection.writeTarget(candidateCount: 3, cachedIndex: 2, command: 0x10) { _, _ in
            probed += 1; return true
        }
        XCTAssertEqual(target, .init(index: 2, reason: .cached))
        XCTAssertEqual(probed, 0)
    }

    func testSingleCandidateIsUsedWithoutProbing() {
        var probed = 0
        let target = DDCPortSelection.writeTarget(candidateCount: 1, cachedIndex: nil, command: 0x62) { _, _ in
            probed += 1; return false
        }
        XCTAssertEqual(target, .init(index: 0, reason: .onlyCandidate))
        XCTAssertEqual(probed, 0)
    }

    func testNoCandidatesYieldsNil() {
        XCTAssertNil(DDCPortSelection.writeTarget(candidateCount: 0, cachedIndex: nil, command: 0x10) { _, _ in true })
    }

    func testProbesTheRequestedVCPAcrossPortsFirst() {
        var calls: [(Int, UInt8)] = []
        let target = DDCPortSelection.writeTarget(candidateCount: 2, cachedIndex: nil, command: 0x62) { index, vcp in
            calls.append((index, vcp)); return index == 1 && vcp == 0x62
        }
        XCTAssertEqual(target, .init(index: 1, reason: .probed))
        XCTAssertEqual(calls.map(\.0), [0, 1])
        XCTAssertEqual(calls.map(\.1), [0x62, 0x62])
    }

    func testFallsBackToBrightnessProbeForWriteOnlyVolume() {
        // Monitor ignores volume reads but answers brightness — still pick its port.
        var calls: [(Int, UInt8)] = []
        let target = DDCPortSelection.writeTarget(candidateCount: 2, cachedIndex: nil, command: 0x62) { index, vcp in
            calls.append((index, vcp)); return index == 1 && vcp == 0x10
        }
        XCTAssertEqual(target, .init(index: 1, reason: .probed))
        XCTAssertEqual(calls.map(\.1), [0x62, 0x62, 0x10, 0x10])
    }

    func testBrightnessIsNotProbedTwice() {
        var calls = 0
        _ = DDCPortSelection.writeTarget(candidateCount: 2, cachedIndex: nil, command: 0x10) { _, _ in
            calls += 1; return false
        }
        XCTAssertEqual(calls, 2)
    }

    func testFallsBackToFirstCandidateWhenNothingAnswers() {
        let target = DDCPortSelection.writeTarget(candidateCount: 3, cachedIndex: nil, command: 0x62) { _, _ in false }
        XCTAssertEqual(target, .init(index: 0, reason: .fallback))
    }

    // MARK: DDCPortMemory

    func testMemoryRemembersByRegistryIDNotPosition() {
        var memory = DDCPortMemory()
        XCTAssertNil(memory.index(for: 7, in: [0xA, 0xB]))
        XCTAssertTrue(memory.remember(0xB, for: 7))
        XCTAssertFalse(memory.remember(0xB, for: 7), "re-remembering the same port is a no-op")
        XCTAssertEqual(memory.index(for: 7, in: [0xA, 0xB]), 1)
        XCTAssertEqual(memory.index(for: 7, in: [0xB, 0xA]), 0, "follows the proxy if enumeration order changes")
        XCTAssertNil(memory.index(for: 7, in: [0xA]), "proxy gone → no cached index")
        XCTAssertNil(memory.index(for: 8, in: [0xA, 0xB]), "per display")
    }

    func testMemoryRemoveAllForgetsEverything() {
        var memory = DDCPortMemory()
        memory.remember(0xA, for: 1)
        memory.remember(0xB, for: 2)
        memory.removeAll()
        XCTAssertNil(memory.index(for: 1, in: [0xA, 0xB]))
        XCTAssertNil(memory.index(for: 2, in: [0xA, 0xB]))
    }
}
