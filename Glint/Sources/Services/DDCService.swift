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

// MARK: - DDC Service

/// Sends DDC/CI commands to external displays over I2C.
/// Uses IOAVService on Apple Silicon, IOFramebuffer I2C on Intel.
final class DDCService: @unchecked Sendable {
    static let shared = DDCService()

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

    // Serial queue — all I2C operations go through here to prevent bus collisions.
    private let ddcQueue = DispatchQueue(label: "com.glint.ddc", qos: .userInteractive)
    // Minimum gap between any two I2C operations (read or write).
    private let busCooldownMicros: useconds_t = 100_000 // 100ms

    // TTL read cache — avoids hammering DDC reads on rate-limited monitors (e.g. LG).
    private struct CacheEntry {
        let result: DDCReadResult
        let timestamp: UInt64 // mach_absolute_time of the real DDC read or write update
    }
    private struct CacheKey: Hashable {
        let displayID: CGDirectDisplayID
        let vcp: UInt8
    }
    private var readCache: [CacheKey: CacheEntry] = [:]
    private let cacheTTLNanos: UInt64 = 2_000_000_000 // 2 seconds

    private init() {
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

    // MARK: - Cached Read/Write

    /// Returns a cached DDC read if within TTL, otherwise performs a real read and caches it.
    func cachedRead(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> (result: DDCReadResult, wasCacheHit: Bool)? {
        ddcQueue.sync {
            let key = CacheKey(displayID: displayID, vcp: code.rawValue)
            if let entry = readCache[key], nanosElapsed(from: entry.timestamp, to: mach_absolute_time()) < cacheTTLNanos {
                log.log("DDC CACHE HIT vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) current=\(entry.result.currentValue)")
                return (entry.result, true)
            }

            // Cache miss — do a real DDC read
            guard let result = readImpl(vcp: code, from: displayID) else { return nil }
            readCache[key] = CacheEntry(result: result, timestamp: mach_absolute_time())
            return (result, false)
        }
    }

    /// Updates the cached value after a successful write (avoids needing another read).
    func updateCache(vcp code: VCPCode, displayID: CGDirectDisplayID, newValue: UInt16, maxValue: UInt16) {
        ddcQueue.sync {
            let key = CacheKey(displayID: displayID, vcp: code.rawValue)
            readCache[key] = CacheEntry(
                result: DDCReadResult(currentValue: newValue, maxValue: maxValue),
                timestamp: mach_absolute_time()
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

            if let entry = readCache[key], nanosElapsed(from: entry.timestamp, to: mach_absolute_time()) < cacheTTLNanos {
                log.log("DDC CACHE HIT vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) current=\(entry.result.currentValue)")
                current = entry.result
            } else {
                guard let result = readImpl(vcp: code, from: displayID) else { return nil }
                readCache[key] = CacheEntry(result: result, timestamp: mach_absolute_time())
                current = result
                didRealRead = true
            }

            let newValue = UInt16(clamping: Int(current.currentValue) + delta)
            let clamped = min(newValue, current.maxValue)
            log.log("DDC ADJUST vcp=0x\(String(code.rawValue, radix: 16)) current=\(current.currentValue) delta=\(delta) new=\(clamped) max=\(current.maxValue) cacheHit=\(!didRealRead)")

            if writeImpl(vcp: code, value: clamped, to: displayID) {
                readCache[key] = CacheEntry(
                    result: DDCReadResult(currentValue: clamped, maxValue: current.maxValue),
                    timestamp: mach_absolute_time()
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
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            let delay = busCooldownMicros * useconds_t(1 << attempt) // 100ms, 200ms, 400ms
            usleep(delay)
            log.log("DDC READ vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID) attempt=\(attempt + 1)/\(maxRetries) delay=\(delay / 1000)ms")
            let result: DDCReadResult?
            if hasAVService {
                result = avServiceRead(command: code.rawValue, displayID: displayID)
            } else {
                guard let framebuffer = framebuffer(for: displayID) else {
                    log.log("DDC READ FAILED: no framebuffer for display \(displayID)")
                    return nil
                }
                defer { IOObjectRelease(framebuffer) }
                result = i2cRead(service: framebuffer, command: code.rawValue)
            }
            if let r = result {
                log.log("DDC READ OK: current=\(r.currentValue) max=\(r.maxValue)")
                return r
            }
            log.log("DDC READ FAILED: nil result for vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID), \(attempt < maxRetries - 1 ? "retrying..." : "giving up")")
        }
        return nil
    }

    /// Raw DDC write — enforces bus cooldown.
    private func writeImpl(vcp code: VCPCode, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        usleep(busCooldownMicros)
        log.log("DDC WRITE vcp=0x\(String(code.rawValue, radix: 16)) value=\(value) display=\(displayID)")
        let success: Bool
        if hasAVService {
            success = avServiceWrite(command: code.rawValue, value: value, displayID: displayID)
        } else {
            guard let framebuffer = framebuffer(for: displayID) else {
                log.log("DDC WRITE FAILED: no framebuffer for display \(displayID)")
                return false
            }
            defer { IOObjectRelease(framebuffer) }
            success = i2cWrite(service: framebuffer, command: code.rawValue, value: value)
        }
        log.log("DDC WRITE \(success ? "OK" : "FAILED") vcp=0x\(String(code.rawValue, radix: 16)) display=\(displayID)")
        return success
    }

    private func nanosElapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        return (end - start) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    // MARK: - Apple Silicon: IOAVService

    /// One external DCPAVServiceProxy (a physical HDMI / Thunderbolt display port) wrapped
    /// in an IOAVService, plus what the registry says about the display behind it.
    private struct AVServiceCandidate {
        let registryID: UInt64
        let service: AnyObject
        let index: Int
    }

    /// Registry entry ID of the DCPAVServiceProxy that last answered DDC for each display.
    /// Machines such as the Mac mini publish one proxy per physical port even when the
    /// port is empty, so the display→port mapping has to be discovered, not assumed by index.
    private var resolvedProxyIDs: [CGDirectDisplayID: UInt64] = [:]

    /// Forgets which port each display answered on. Call when displays are (re)connected —
    /// a display ID can come back on a different physical port.
    func invalidateServiceCache() {
        ddcQueue.sync { resolvedProxyIDs.removeAll() }
    }

    /// Enumerates the external DCPAVServiceProxy services, ordered by how likely each is to
    /// be the port `displayID` is attached to:
    ///   1. the proxy that already answered DDC for this display (cached),
    ///   2. proxies whose dcp subtree publishes this display's EDID UUID,
    ///   3. the proxy at the display's position in CoreGraphics' external-display order
    ///      (the historical guess),
    ///   4. proxies no other connected display would claim by that positional rule.
    /// Ports another display would claim positionally are left out unless the EDID says
    /// otherwise, so a display without DDC support can't fall through to its neighbour.
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
        let guessIndex = min(externalDisplayIDs.firstIndex(of: displayID) ?? 0, externals.count - 1)
        // Indices the other connected displays would pick by the same positional rule.
        let claimedByOthers = Set((0..<min(externalDisplayIDs.count, externals.count)).filter { $0 != guessIndex })
        let targetUUID = Self.edidUUID(for: displayID)

        var order: [Int] = []
        func append(_ index: Int) {
            if !order.contains(index) { order.append(index) }
        }
        if let cached = resolvedProxyIDs[displayID],
           let cachedIndex = externals.firstIndex(where: { $0.registryID == cached }) {
            append(cachedIndex)
        }
        if let uuid = targetUUID {
            for (index, external) in externals.enumerated() where external.edidUUIDs.contains(uuid) {
                append(index)
            }
        }
        append(guessIndex)
        for index in externals.indices where !claimedByOthers.contains(index) {
            append(index)
        }

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
        guard resolvedProxyIDs[displayID] != candidate.registryID else { return }
        resolvedProxyIDs[displayID] = candidate.registryID
        log.log("DDC: display=\(displayID) answers on DCPAVServiceProxy #\(candidate.index) (registryID=0x\(String(candidate.registryID, radix: 16)))")
    }

    /// Picks the port a write should go to. Prefers the port that already answered a read for
    /// this display; otherwise probes the candidates with a read (the VCP being written, then
    /// brightness) so the write can't land on an empty or neighbouring port. Falls back to the
    /// first candidate when nothing answers (write-only monitors).
    private func resolveWriteTarget(
        from candidates: [AVServiceCandidate],
        for displayID: CGDirectDisplayID,
        command: UInt8
    ) -> AVServiceCandidate? {
        guard let first = candidates.first else { return nil }
        if let cached = resolvedProxyIDs[displayID],
           let candidate = candidates.first(where: { $0.registryID == cached }) {
            return candidate
        }
        if candidates.count == 1 { return first }

        var probes = [command]
        if command != VCPCode.brightness.rawValue { probes.append(VCPCode.brightness.rawValue) }
        for vcp in probes {
            for candidate in candidates {
                if avServiceRead(command: vcp, on: candidate.service) != nil {
                    remember(candidate, for: displayID)
                    usleep(busCooldownMicros)
                    return candidate
                }
            }
        }
        log.log("DDC: no port answered a probe read for display \(displayID) — writing to candidate #\(first.index)")
        return first
    }

    private func avServiceWrite(command: UInt8, value: UInt16, displayID: CGDirectDisplayID) -> Bool {
        guard let writeFn = avWriteI2CFn else { return false }
        let candidates = avServiceCandidates(for: displayID)
        guard let target = resolveWriteTarget(from: candidates, for: displayID, command: command) else {
            log.log("DDC: No IOAVService found for display \(displayID)")
            return false
        }

        // DDC/CI SET VCP Feature
        // Protocol: [length|0x80, opcode=0x03, vcp_code, value_hi, value_lo, checksum]
        // Checksum = XOR of (0x6E, 0x51, all payload bytes)
        var data: [UInt8] = [
            0x84,                   // length = 4 | 0x80
            0x03,                   // SET VCP opcode
            command,                // VCP code
            UInt8(value >> 8),      // value high byte
            UInt8(value & 0xFF)     // value low byte
        ]
        var checksum: UInt8 = 0x6E ^ 0x51
        for byte in data { checksum ^= byte }
        data.append(checksum)

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
        var sendData: [UInt8] = [
            0x82,       // length = 2 | 0x80
            0x01,       // GET VCP opcode
            command     // VCP code
        ]
        var checksum: UInt8 = 0x6E ^ 0x51
        for byte in sendData { checksum ^= byte }
        sendData.append(checksum)

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

        // Parse VCP reply
        // Expected: [source, length, 0x02, result_code, vcp_opcode, type_code, max_hi, max_lo, cur_hi, cur_lo, checksum]
        // Find the 0x02 (feature reply opcode) in the response
        guard let replyStart = replyData.firstIndex(of: 0x02),
              replyStart + 8 <= replyData.count,
              replyData[replyStart + 2] == command else {
            log.log("DDC read: invalid reply for VCP 0x\(String(command, radix: 16)): \(replyData.map { String($0, radix: 16) })")
            return nil
        }

        let maxValue = (UInt16(replyData[replyStart + 4]) << 8) | UInt16(replyData[replyStart + 5])
        let currentValue = (UInt16(replyData[replyStart + 6]) << 8) | UInt16(replyData[replyStart + 7])

        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
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

        var data: [UInt8] = [0x51, 0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)]
        let checksum = data.reduce(0x6E, { $0 ^ $1 })
        data.append(checksum)

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

        var writeData: [UInt8] = [0x51, 0x82, 0x01, command]
        let writeChecksum = writeData.reduce(0x6E, { $0 ^ $1 })
        writeData.append(writeChecksum)
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
        guard replyData.count >= 11,
              replyData[2] == 0x02,
              replyData[4] == command else {
            return nil
        }

        let maxValue = (UInt16(replyData[6]) << 8) | UInt16(replyData[7])
        let currentValue = (UInt16(replyData[8]) << 8) | UInt16(replyData[9])

        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
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
