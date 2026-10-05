import AppKit
import IOKit

// RTLD_DEFAULT is a C macro ((void *) -2) that Swift cannot import directly.
private nonisolated(unsafe) let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)

// MARK: - DDC/CI VCP Codes

enum VCPCode: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case audioMute = 0x8D
    case powerMode = 0xD6
}

// MARK: - DDC Result

struct DDCReadResult {
    let currentValue: UInt16
    let maxValue: UInt16
}

// MARK: - DDC/CI packets

/// Pure DDC/CI framing: the bytes Glint puts on the wire and how it parses replies.
/// Kept free of IOKit so the protocol can be unit-tested byte for byte.
enum DDCPacket {
    /// Checksum seed for host-originated packets: destination 0x6E XOR source 0x51.
    static let hostChecksumSeed: UInt8 = 0x6E ^ 0x51

    private static func checksummed(_ payload: [UInt8], seed: UInt8) -> [UInt8] {
        var checksum = seed
        for byte in payload { checksum ^= byte }
        return payload + [checksum]
    }

    /// IOAVService SET VCP Feature: [length|0x80, 0x03, vcp, value_hi, value_lo, checksum].
    /// The 0x51 source address is passed to IOAVServiceWriteI2C separately, so it is only
    /// folded into the checksum.
    static func avSetVCP(command: UInt8, value: UInt16) -> [UInt8] {
        checksummed([0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)], seed: hostChecksumSeed)
    }

    /// IOAVService GET VCP Feature request: [length|0x80, 0x01, vcp, checksum].
    static func avGetVCP(command: UInt8) -> [UInt8] {
        checksummed([0x82, 0x01, command], seed: hostChecksumSeed)
    }

    /// IOFramebuffer I2C SET VCP: the 0x51 source byte is part of the buffer, checksum
    /// seeded with the 0x6E destination address.
    static func i2cSetVCP(command: UInt8, value: UInt16) -> [UInt8] {
        checksummed([0x51, 0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)], seed: 0x6E)
    }

    /// IOFramebuffer I2C GET VCP request.
    static func i2cGetVCP(command: UInt8) -> [UInt8] {
        checksummed([0x51, 0x82, 0x01, command], seed: 0x6E)
    }

    /// Parses an IOAVService VCP reply. Expected:
    /// [source, length, 0x02, result_code, vcp_opcode, type_code, max_hi, max_lo, cur_hi, cur_lo, checksum]
    /// The reply is located by the first 0x02 (feature reply opcode); returns nil when it is
    /// missing, truncated, or doesn't echo `command`.
    static func parseAVReply(_ reply: [UInt8], command: UInt8) -> DDCReadResult? {
        guard let replyStart = reply.firstIndex(of: 0x02),
              replyStart + 8 <= reply.count,
              reply[replyStart + 2] == command else {
            return nil
        }
        let maxValue = (UInt16(reply[replyStart + 4]) << 8) | UInt16(reply[replyStart + 5])
        let currentValue = (UInt16(reply[replyStart + 6]) << 8) | UInt16(reply[replyStart + 7])
        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
    }

    /// Parses an IOFramebuffer I2C VCP reply (fixed layout, opcode at index 2).
    static func parseI2CReply(_ reply: [UInt8], command: UInt8) -> DDCReadResult? {
        guard reply.count >= 11,
              reply[2] == 0x02,
              reply[4] == command else {
            return nil
        }
        let maxValue = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let currentValue = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
    }
}

// MARK: - Port selection

/// Pure decisions about which DCPAVServiceProxy (physical port) a display is on.
enum DDCPortSelection {
    /// Orders proxy indices by how likely each is to be the port the display is attached to:
    ///   1. the proxy that already answered DDC for this display (cached),
    ///   2. proxies whose dcp subtree publishes this display's EDID UUID,
    ///   3. the proxy at the display's position in CoreGraphics' external-display order
    ///      (the historical guess; position 0 when the display isn't in that list),
    ///   4. proxies no other connected display would claim by that positional rule.
    /// Ports another display would claim positionally are left out unless the EDID says
    /// otherwise, so a display without DDC support can't fall through to its neighbour.
    static func candidateOrder(
        proxyCount: Int,
        displayPosition: Int?,
        externalDisplayCount: Int,
        cachedIndex: Int?,
        edidMatchIndices: [Int]
    ) -> [Int] {
        guard proxyCount > 0 else { return [] }
        let guessIndex = min(displayPosition ?? 0, proxyCount - 1)
        // Indices the other connected displays would pick by the same positional rule.
        let claimedByOthers = Set((0..<min(externalDisplayCount, proxyCount)).filter { $0 != guessIndex })

        var order: [Int] = []
        func append(_ index: Int) {
            if !order.contains(index) { order.append(index) }
        }
        if let cachedIndex { append(cachedIndex) }
        for index in edidMatchIndices { append(index) }
        append(guessIndex)
        for index in 0..<proxyCount where !claimedByOthers.contains(index) {
            append(index)
        }
        return order
    }

    struct WriteTarget: Equatable {
        enum Reason: Equatable {
            /// The port already answered for this display.
            case cached
            /// Only one candidate — nothing to choose between.
            case onlyCandidate
            /// The port answered a probe read (the caller should remember it).
            case probed
            /// Nothing answered (write-only monitor) — first candidate.
            case fallback
        }
        let index: Int
        let reason: Reason
    }

    /// Picks the port a write should go to. Prefers the port that already answered a read for
    /// this display; otherwise probes the candidates with a read (the VCP being written, then
    /// brightness) so the write can't land on an empty or neighbouring port. Falls back to the
    /// first candidate when nothing answers (write-only monitors).
    static func writeTarget(
        candidateCount: Int,
        cachedIndex: Int?,
        command: UInt8,
        probe: (_ candidateIndex: Int, _ vcp: UInt8) -> Bool
    ) -> WriteTarget? {
        guard candidateCount > 0 else { return nil }
        if let cachedIndex, cachedIndex < candidateCount {
            return WriteTarget(index: cachedIndex, reason: .cached)
        }
        if candidateCount == 1 { return WriteTarget(index: 0, reason: .onlyCandidate) }

        var probes = [command]
        if command != VCPCode.brightness.rawValue { probes.append(VCPCode.brightness.rawValue) }
        for vcp in probes {
            for index in 0..<candidateCount where probe(index, vcp) {
                return WriteTarget(index: index, reason: .probed)
            }
        }
        return WriteTarget(index: 0, reason: .fallback)
    }
}

/// Registry entry ID of the DCPAVServiceProxy that last answered DDC for each display.
/// Machines such as the Mac mini publish one proxy per physical port even when the
/// port is empty, so the display→port mapping has to be discovered, not assumed by index.
struct DDCPortMemory {
    private var resolvedProxyIDs: [CGDirectDisplayID: UInt64] = [:]

    /// Position of the remembered proxy for `displayID` among `registryIDs`, if still present.
    func index(for displayID: CGDirectDisplayID, in registryIDs: [UInt64]) -> Int? {
        guard let cached = resolvedProxyIDs[displayID] else { return nil }
        return registryIDs.firstIndex(of: cached)
    }

    /// Records the proxy that answered; returns false when it was already remembered.
    @discardableResult
    mutating func remember(_ registryID: UInt64, for displayID: CGDirectDisplayID) -> Bool {
        guard resolvedProxyIDs[displayID] != registryID else { return false }
        resolvedProxyIDs[displayID] = registryID
        return true
    }

    mutating func removeAll() {
        resolvedProxyIDs.removeAll()
    }
}

// MARK: - Transport

/// Outcome of one raw DDC read attempt.
enum DDCReadAttempt {
    case value(DDCReadResult)
    /// The display didn't answer (or answered garbage) — worth retrying.
    case noReply
    /// No route to the display at all (e.g. no framebuffer) — retrying is pointless.
    case unavailable
}

/// One raw DDC/CI exchange with a display. `DDCService` layers serialisation, bus
/// cooldown, retries and the read cache on top. Always called on DDCService's queue.
protocol DDCTransport: AnyObject {
    func read(command: UInt8, from displayID: CGDirectDisplayID) -> DDCReadAttempt
    func write(command: UInt8, value: UInt16, to displayID: CGDirectDisplayID) -> Bool
    /// Forget any display→port mapping (displays were reconfigured).
    func invalidatePortCache()
}

// MARK: - DDC Service

/// Sends DDC/CI commands to external displays over I2C.
/// Uses IOAVService on Apple Silicon, IOFramebuffer I2C on Intel.
final class DDCService: @unchecked Sendable {
    static let shared = DDCService(transport: IOKitDDCTransport())

    private let transport: DDCTransport

    // Serial queue — all I2C operations go through here to prevent bus collisions.
    private let ddcQueue = DispatchQueue(label: "com.glint.ddc", qos: .userInteractive)
    // Minimum gap between any two I2C operations (read or write).
    private let busCooldownMicros: useconds_t
    private let sleep: (useconds_t) -> Void
    /// Monotonic clock in nanoseconds.
    private let now: () -> UInt64

    // TTL read cache — avoids hammering DDC reads on rate-limited monitors (e.g. LG).
    private struct CacheEntry {
        let result: DDCReadResult
        let timestamp: UInt64 // monotonic nanos of the real DDC read or write update
    }
    private struct CacheKey: Hashable {
        let displayID: CGDirectDisplayID
        let vcp: UInt8
    }
    private var readCache: [CacheKey: CacheEntry] = [:]
    static let cacheTTLNanos: UInt64 = 2_000_000_000 // 2 seconds
    static let maxReadAttempts = 3

    /// `busCooldownMicros`, `sleep` and `now` are injectable so tests run without real
    /// delays; the app uses a 100 ms cooldown, `usleep` and the uptime clock.
    init(
        transport: DDCTransport,
        busCooldownMicros: useconds_t = 100_000,
        sleep: @escaping (useconds_t) -> Void = { _ = usleep($0) },
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.transport = transport
        self.busCooldownMicros = busCooldownMicros
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Public API

    private let log = DebugLogger.shared

    func read(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> DDCReadResult? {
        ddcQueue.sync {
            readImpl(vcp: code, from: displayID)
        }
    }

    func write(vcp code: VCPCode, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        ddcQueue.sync {
            writeImpl(vcp: code, value: value, to: displayID)
        }
    }

    /// Forgets which port each display answered on. Call when displays are (re)connected —
    /// a display ID can come back on a different physical port.
    func invalidateServiceCache() {
        ddcQueue.sync { transport.invalidatePortCache() }
    }

    // MARK: - Cached Read/Write

    private func freshEntry(for key: CacheKey) -> CacheEntry? {
        guard let entry = readCache[key] else { return nil }
        let current = now()
        let elapsed = current >= entry.timestamp ? current - entry.timestamp : 0
        return elapsed < Self.cacheTTLNanos ? entry : nil
    }

    /// Returns a cached DDC read if within TTL, otherwise performs a real read and caches it.
    func cachedRead(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> (result: DDCReadResult, wasCacheHit: Bool)? {
        ddcQueue.sync {
            let key = CacheKey(displayID: displayID, vcp: code.rawValue)
            if let entry = freshEntry(for: key) {
                log.log("DDC CACHE HIT vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) current=\(entry.result.currentValue)")
                return (entry.result, true)
            }

            // Cache miss — do a real DDC read
            guard let result = readImpl(vcp: code, from: displayID) else { return nil }
            readCache[key] = CacheEntry(result: result, timestamp: now())
            return (result, false)
        }
    }

    /// Updates the cached value after a successful write (avoids needing another read).
    func updateCache(vcp code: VCPCode, displayID: CGDirectDisplayID, newValue: UInt16, maxValue: UInt16) {
        ddcQueue.sync {
            let key = CacheKey(displayID: displayID, vcp: code.rawValue)
            readCache[key] = CacheEntry(
                result: DDCReadResult(currentValue: newValue, maxValue: maxValue),
                timestamp: now()
            )
        }
    }

    /// Adjusts a VCP value by a relative amount, clamped to [0, max].
    /// Uses the TTL read cache to avoid excessive DDC reads on rate-limited monitors.
    func adjust(vcp code: VCPCode, by delta: Int, on displayID: CGDirectDisplayID) -> DDCReadResult? {
        ddcQueue.sync {
            let key = CacheKey(displayID: displayID, vcp: code.rawValue)
            let current: DDCReadResult
            var didRealRead = false

            if let entry = freshEntry(for: key) {
                log.log("DDC CACHE HIT vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) current=\(entry.result.currentValue)")
                current = entry.result
            } else {
                guard let result = readImpl(vcp: code, from: displayID) else { return nil }
                readCache[key] = CacheEntry(result: result, timestamp: now())
                current = result
                didRealRead = true
            }

            let newValue = UInt16(clamping: Int(current.currentValue) + delta)
            let clamped = min(newValue, current.maxValue)
            log.log("DDC ADJUST vcp=0x\(String(code.rawValue, radix: 16)) current=\(current.currentValue) delta=\(delta) new=\(clamped) max=\(current.maxValue) cacheHit=\(!didRealRead)")

            if writeImpl(vcp: code, value: clamped, to: displayID) {
                readCache[key] = CacheEntry(
                    result: DDCReadResult(currentValue: clamped, maxValue: current.maxValue),
                    timestamp: now()
                )
                return DDCReadResult(currentValue: clamped, maxValue: current.maxValue)
            }
            return nil
        }
    }

    // MARK: - Internal (must be called on ddcQueue)

    /// Raw DDC read — enforces bus cooldown with exponential backoff retries.
    /// Retries up to 3 times with 100ms, 200ms, 400ms delays on failure.
    private func readImpl(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> DDCReadResult? {
        let maxRetries = Self.maxReadAttempts
        for attempt in 0..<maxRetries {
            let delay = busCooldownMicros * useconds_t(1 << attempt) // 100ms, 200ms, 400ms
            sleep(delay)
            log.log("DDC READ vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) attempt=\(attempt + 1)/\(maxRetries) delay=\(delay / 1000)ms")
            switch transport.read(command: code.rawValue, from: displayID) {
            case .value(let r):
                log.log("DDC READ OK: current=\(r.currentValue) max=\(r.maxValue)")
                return r
            case .unavailable:
                return nil
            case .noReply:
                log.log("DDC READ FAILED: nil result for vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID), \(attempt < maxRetries - 1 ? "retrying..." : "giving up")")
            }
        }
        return nil
    }

    /// Raw DDC write — enforces bus cooldown.
    private func writeImpl(vcp code: VCPCode, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        sleep(busCooldownMicros)
        log.log("DDC WRITE vcp=0x\(String(code.rawValue, radix: 16)) value=\(value) display=\(displayID)")
        let success = transport.write(command: code.rawValue, value: value, to: displayID)
        log.log("DDC WRITE \(success ? "OK" : "FAILED") vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID)")
        return success
    }
}

// MARK: - IOKit transport

/// The real hardware transport: IOAVService (Apple Silicon) with IOFramebuffer I2C fallback.
final class IOKitDDCTransport: DDCTransport {
    // IOAVService — resolved at runtime via dlsym for resilience.
    // If Apple removes these symbols in a future macOS, the app still launches
    // and falls back to IOFramebuffer or reports DDC unavailable.
    private typealias AVCreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVWriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias AVReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let avCreateFn: AVCreateFn?
    private let avWriteI2CFn: AVWriteI2CFn?
    private let avReadI2CFn: AVReadI2CFn?

    /// True when all IOAVService symbols are available (Apple Silicon with compatible macOS).
    private var hasAVService: Bool { avCreateFn != nil && avWriteI2CFn != nil && avReadI2CFn != nil }

    // Gap after a successful probe read before the write that follows it.
    private let busCooldownMicros: useconds_t = 100_000 // 100ms

    private let log = DebugLogger.shared

    private var portMemory = DDCPortMemory()

    init() {
        if let create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService"),
           let write = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C"),
           let read = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C") {
            avCreateFn = unsafeBitCast(create, to: AVCreateFn.self)
            avWriteI2CFn = unsafeBitCast(write, to: AVWriteI2CFn.self)
            avReadI2CFn = unsafeBitCast(read, to: AVReadI2CFn.self)
            log.log("DDC: IOAVService symbols resolved — Apple Silicon DDC available")
        } else {
            avCreateFn = nil
            avWriteI2CFn = nil
            avReadI2CFn = nil
            log.log("DDC: IOAVService symbols not found — falling back to IOFramebuffer I2C")
        }
    }

    func read(command: UInt8, from displayID: CGDirectDisplayID) -> DDCReadAttempt {
        if hasAVService {
            return avServiceRead(command: command, displayID: displayID).map(DDCReadAttempt.value) ?? .noReply
        }
        guard let framebuffer = framebuffer(for: displayID) else {
            log.log("DDC READ FAILED: no framebuffer for display \(displayID)")
            return .unavailable
        }
        defer { IOObjectRelease(framebuffer) }
        return i2cRead(service: framebuffer, command: command).map(DDCReadAttempt.value) ?? .noReply
    }

    func write(command: UInt8, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        if hasAVService {
            return avServiceWrite(command: command, value: value, displayID: displayID)
        }
        guard let framebuffer = framebuffer(for: displayID) else {
            log.log("DDC WRITE FAILED: no framebuffer for display \(displayID)")
            return false
        }
        defer { IOObjectRelease(framebuffer) }
        return i2cWrite(service: framebuffer, command: command, value: value)
    }

    func invalidatePortCache() {
        portMemory.removeAll()
    }

    // MARK: - Apple Silicon: IOAVService

    /// One external DCPAVServiceProxy (a physical HDMI / Thunderbolt display port) wrapped
    /// in an IOAVService, plus what the registry says about the display behind it.
    private struct AVServiceCandidate {
        let registryID: UInt64
        let service: AnyObject
        let index: Int
    }

    /// Enumerates the external DCPAVServiceProxy services, ordered by how likely each is to
    /// be the port `displayID` is attached to (see `DDCPortSelection.candidateOrder`).
    private func avServiceCandidates(for displayID: CGDirectDisplayID) -> [AVServiceCandidate] {
        guard let createFn = avCreateFn else { return [] }

        // Built-in displays don't support DDC
        if CGDisplayIsBuiltin(displayID) != 0 {
            log.log("DDC: Skipping built-in display \(displayID)")
            return []
        }

        var iter: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        // Collect all external (non-Embedded) proxies with their registry IDs and nearby EDID UUIDs.
        var externals: [(service: io_service_t, registryID: UInt64, edidUUIDs: Set<String>)] = []
        var service = IOIteratorNext(iter)
        while service != 0 {
            let location = registryString(for: "Location", in: service)
            if location?.lowercased() == "embedded" {
                IOObjectRelease(service)
            } else {
                var registryID: UInt64 = 0
                _ = IORegistryEntryGetRegistryEntryID(service, &registryID)
                externals.append((service, registryID, edidUUIDs(near: service)))
            }
            service = IOIteratorNext(iter)
        }
        defer { for external in externals { IOObjectRelease(external.service) } }

        guard !externals.isEmpty else {
            log.log("DDC: No external DCPAVServiceProxy services found")
            return []
        }

        let externalDisplayIDs = Self.externalDisplayIDs()
        let targetUUID = Self.edidUUID(for: displayID)
        let edidMatches = targetUUID.map { uuid in
            externals.indices.filter { externals[$0].edidUUIDs.contains(uuid) }
        } ?? []

        let order = DDCPortSelection.candidateOrder(
            proxyCount: externals.count,
            displayPosition: externalDisplayIDs.firstIndex(of: displayID),
            externalDisplayCount: externalDisplayIDs.count,
            cachedIndex: portMemory.index(for: displayID, in: externals.map(\.registryID)),
            edidMatchIndices: edidMatches
        )

        log.log("DDC: display=\(displayID) uuid=\(targetUUID ?? "n/a") externalProxies=\(externals.count) externalDisplays=\(externalDisplayIDs.count) candidateOrder=\(order) proxyEDIDs=\(externals.map { Array($0.edidUUIDs).sorted() })")

        return order.compactMap { index -> AVServiceCandidate? in
            let external = externals[index]
            guard let avService = createFn(kCFAllocatorDefault, external.service)?.takeRetainedValue() else {
                log.log("DDC: IOAVServiceCreateWithService failed for proxy #\(index)")
                return nil
            }
            return AVServiceCandidate(registryID: external.registryID, service: avService, index: index)
        }
    }

    /// EDID UUIDs published in the registry subtree `proxy` belongs to (walking up to three
    /// ancestors). Each physical display port lives in its own dcp subtree, so a shared
    /// ancestor identifies the port; once an ancestor's subtree holds more than one proxy the
    /// walk has left the port and stops.
    private func edidUUIDs(near proxy: io_service_t) -> Set<String> {
        var current: io_registry_entry_t = proxy
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<3 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { break }
            IOObjectRelease(current)
            current = parent

            var iter: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(current, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { break }
            var proxyCount = 0
            var found = Set<String>()
            var child = IOIteratorNext(iter)
            while child != 0 {
                if IOObjectConformsTo(child, "DCPAVServiceProxy") != 0 {
                    proxyCount += 1
                } else if let uuid = registryString(for: "EDID UUID", in: child) {
                    found.insert(uuid.uppercased())
                }
                IOObjectRelease(child)
                child = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)

            if proxyCount > 1 { break } // ancestor spans several ports — no longer port-specific
            if !found.isEmpty { return found }
        }
        return []
    }

    /// CoreGraphics' UUID for a display. It is derived from the EDID, so it matches the
    /// "EDID UUID" the DCP driver publishes in the IORegistry.
    private static func edidUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return (string as String).uppercased()
    }

    /// Returns ordered list of external display IDs (non-built-in).
    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &displayIDs, &count)
        return (0..<Int(count))
            .map { displayIDs[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func remember(_ candidate: AVServiceCandidate, for displayID: CGDirectDisplayID) {
        guard portMemory.remember(candidate.registryID, for: displayID) else { return }
        log.log("DDC: display=\(displayID) answers on DCPAVServiceProxy #\(candidate.index) (registryID=0x\(String(candidate.registryID, radix: 16)))")
    }

    /// Picks the port a write should go to (see `DDCPortSelection.writeTarget`).
    private func resolveWriteTarget(
        from candidates: [AVServiceCandidate],
        for displayID: CGDirectDisplayID,
        command: UInt8
    ) -> AVServiceCandidate? {
        guard let target = DDCPortSelection.writeTarget(
            candidateCount: candidates.count,
            cachedIndex: portMemory.index(for: displayID, in: candidates.map(\.registryID)),
            command: command,
            probe: { index, vcp in avServiceRead(command: vcp, on: candidates[index].service) != nil }
        ) else { return nil }

        let candidate = candidates[target.index]
        switch target.reason {
        case .cached, .onlyCandidate:
            break
        case .probed:
            remember(candidate, for: displayID)
            usleep(busCooldownMicros)
        case .fallback:
            log.log("DDC: no port answered a probe read for display \(displayID) — writing to candidate #\(candidate.index)")
        }
        return candidate
    }

    private func avServiceWrite(command: UInt8, value: UInt16, displayID: CGDirectDisplayID) -> Bool {
        guard let writeFn = avWriteI2CFn else { return false }
        let candidates = avServiceCandidates(for: displayID)
        guard let target = resolveWriteTarget(from: candidates, for: displayID, command: command) else {
            log.log("DDC: No IOAVService found for display \(displayID)")
            return false
        }

        // DDC/CI SET VCP Feature
        var data = DDCPacket.avSetVCP(command: command, value: value)

        let result = data.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            writeFn(target.service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        if result == KERN_SUCCESS {
            usleep(50_000)
            return true
        }
        log.log("DDC write failed on proxy #\(target.index): \(result)")
        return false
    }

    /// Reads a VCP from whichever external port answers for `displayID`, trying the
    /// candidates in likelihood order and remembering the one that replied.
    private func avServiceRead(command: UInt8, displayID: CGDirectDisplayID) -> DDCReadResult? {
        let candidates = avServiceCandidates(for: displayID)
        guard !candidates.isEmpty else {
            log.log("DDC: No IOAVService found for display \(displayID)")
            return nil
        }
        for candidate in candidates {
            if let result = avServiceRead(command: command, on: candidate.service) {
                remember(candidate, for: displayID)
                return result
            }
        }
        return nil
    }

    /// One DDC GET VCP round-trip on a specific IOAVService. Returns nil when the port has no
    /// display, the display doesn't answer, or the reply doesn't echo the requested VCP.
    private func avServiceRead(command: UInt8, on service: AnyObject) -> DDCReadResult? {
        guard let writeFn = avWriteI2CFn, let readFn = avReadI2CFn else { return nil }

        // Step 1: Send GET VCP Feature request
        var sendData = DDCPacket.avGetVCP(command: command)

        let writeResult = sendData.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            writeFn(service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        guard writeResult == KERN_SUCCESS else {
            log.log("DDC read (write phase) failed: \(writeResult)")
            return nil
        }

        // Wait for display to prepare response
        usleep(40_000)

        // Step 2: Read response
        var replyData = [UInt8](repeating: 0, count: 12)
        let readResult = replyData.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            readFn(service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        guard readResult == KERN_SUCCESS else {
            log.log("DDC read (read phase) failed: \(readResult)")
            return nil
        }

        guard let result = DDCPacket.parseAVReply(replyData, command: command) else {
            log.log("DDC read: invalid reply for VCP 0x\(String(command, radix: 16)): \(replyData.map { String($0, radix: 16) })")
            return nil
        }
        return result
    }

    // MARK: - Intel: IOFramebuffer I2C (Legacy)

    private func framebuffer(for displayID: CGDirectDisplayID) -> io_service_t? {
        let vendorNumber = CGDisplayVendorNumber(displayID)
        let modelNumber = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as Dictionary

            let vid = (info[kDisplayVendorID as NSString] as? Int) ?? 0
            let pid = (info[kDisplayProductID as NSString] as? Int) ?? 0
            let sn = (info[kDisplaySerialNumber as NSString] as? Int) ?? 0

            if vid == Int(vendorNumber) && pid == Int(modelNumber) && sn == Int(serialNumber) {
                var fb: io_service_t = 0
                if IORegistryEntryGetParentEntry(service, kIOServicePlane, &fb) == KERN_SUCCESS {
                    IOObjectRelease(service)
                    return fb
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return nil
    }

    private func i2cWrite(service: io_service_t, command: UInt8, value: UInt16) -> Bool {
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E

        var data = DDCPacket.i2cSetVCP(command: command, value: value)

        request.sendBytes = UInt32(data.count)

        let result = data.withUnsafeMutableBufferPointer { buffer -> Bool in
            request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            return performI2CRequest(service: service, request: &request)
        }

        if result { usleep(50_000) }
        return result
    }

    private func i2cRead(service: io_service_t, command: UInt8) -> DDCReadResult? {
        var writeRequest = IOI2CRequest()
        writeRequest.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        writeRequest.sendAddress = 0x6E

        var writeData = DDCPacket.i2cGetVCP(command: command)
        writeRequest.sendBytes = UInt32(writeData.count)

        let writeSent = writeData.withUnsafeMutableBufferPointer { buffer -> Bool in
            writeRequest.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            return performI2CRequest(service: service, request: &writeRequest)
        }

        guard writeSent else { return nil }
        usleep(40_000)

        var readRequest = IOI2CRequest()
        readRequest.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        readRequest.replyAddress = 0x6F

        var replyData = [UInt8](repeating: 0, count: 12)
        readRequest.replyBytes = UInt32(replyData.count)

        let readSuccess = replyData.withUnsafeMutableBufferPointer { buffer -> Bool in
            readRequest.replyBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            return performI2CRequest(service: service, request: &readRequest)
        }

        guard readSuccess else { return nil }
        return DDCPacket.parseI2CReply(replyData, command: command)
    }

    private func performI2CRequest(service: io_service_t, request: inout IOI2CRequest) -> Bool {
        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(service, 0, &i2cInterface) == KERN_SUCCESS,
              i2cInterface != 0 else {
            return performI2COnChildren(service: service, request: &request)
        }
        defer { IOObjectRelease(i2cInterface) }

        var connect: IOI2CConnectRef? = nil
        guard IOI2CInterfaceOpen(i2cInterface, 0, &connect) == KERN_SUCCESS,
              let connect = connect else {
            return false
        }
        defer { IOI2CInterfaceClose(connect, 0) }

        let result = IOI2CSendRequest(connect, 0, &request)
        return result == KERN_SUCCESS && request.result == KERN_SUCCESS
    }

    private func performI2COnChildren(service: io_service_t, request: inout IOI2CRequest) -> Bool {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(childIter) }

        var child = IOIteratorNext(childIter)
        while child != 0 {
            var i2cInterface: io_service_t = 0
            if IOFBCopyI2CInterfaceForBus(child, 0, &i2cInterface) == KERN_SUCCESS,
               i2cInterface != 0 {
                defer { IOObjectRelease(i2cInterface) }
                var connect: IOI2CConnectRef? = nil
                if IOI2CInterfaceOpen(i2cInterface, 0, &connect) == KERN_SUCCESS,
                   let connect = connect {
                    let ok = IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS && request.result == KERN_SUCCESS
                    IOI2CInterfaceClose(connect, 0)
                    if ok {
                        IOObjectRelease(child)
                        return true
                    }
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIter)
        }
        return false
    }

    // MARK: - Helpers

    private func registryString(for key: String, in service: io_service_t) -> String? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return ref.takeRetainedValue() as? String
    }
}
