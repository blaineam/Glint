import AppKit
import IOKit

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

    private let isAppleSilicon: Bool

    private init() {
        #if arch(arm64)
        isAppleSilicon = true
        #else
        isAppleSilicon = false
        #endif
    }

    // MARK: - Public API

    func read(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> DDCReadResult? {
        if isAppleSilicon {
            return avServiceRead(command: code.rawValue, displayID: displayID)
        } else {
            guard let framebuffer = framebuffer(for: displayID) else { return nil }
            defer { IOObjectRelease(framebuffer) }
            return i2cRead(service: framebuffer, command: code.rawValue)
        }
    }

    func write(vcp code: VCPCode, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        if isAppleSilicon {
            return avServiceWrite(command: code.rawValue, value: value, displayID: displayID)
        } else {
            guard let framebuffer = framebuffer(for: displayID) else { return false }
            defer { IOObjectRelease(framebuffer) }
            return i2cWrite(service: framebuffer, command: code.rawValue, value: value)
        }
    }

    /// Adjusts a VCP value by a relative amount, clamped to [0, max].
    func adjust(vcp code: VCPCode, by delta: Int, on displayID: CGDirectDisplayID) -> UInt16? {
        guard let current = read(vcp: code, from: displayID) else { return nil }
        let newValue = UInt16(clamping: Int(current.currentValue) + delta)
        let clamped = min(newValue, current.maxValue)
        if write(vcp: code, value: clamped, to: displayID) {
            return clamped
        }
        return nil
    }

    // MARK: - Apple Silicon: IOAVService

    /// Finds the IOAVService for a given display.
    /// Strategy: enumerate DCPAVServiceProxy services, skip those with Location=Embedded
    /// (built-in display), and return external services. For multi-monitor setups,
    /// caches a mapping of display ID to service index.
    private func avService(for displayID: CGDirectDisplayID) -> IOAVService? {
        // Built-in displays don't support DDC
        if CGDisplayIsBuiltin(displayID) != 0 { return nil }

        var iter: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return nil }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        // Collect all external (non-Embedded) services
        var externalServices: [io_service_t] = []
        var service = IOIteratorNext(iter)
        while service != 0 {
            let location = registryString(for: "Location", in: service)
            let isEmbedded = location?.lowercased() == "embedded"

            if !isEmbedded {
                externalServices.append(service)
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iter)
        }

        // If no external services found, return nil
        guard !externalServices.isEmpty else { return nil }

        // For single external display, just use it
        // For multiple externals, try to match by probing DDC — each display
        // reports its own EDID vendor/model via VCP, so we pick the first that works
        // (multi-monitor matching by index: external display order matches CGDisplay order)
        let externalDisplayIDs = Self.externalDisplayIDs()
        let targetIndex = externalDisplayIDs.firstIndex(of: displayID) ?? 0
        let serviceIndex = min(targetIndex, externalServices.count - 1)

        let chosen = externalServices[serviceIndex]
        let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, chosen)?.takeRetainedValue()

        for s in externalServices { IOObjectRelease(s) }
        return avService
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

    private func avServiceWrite(command: UInt8, value: UInt16, displayID: CGDirectDisplayID) -> Bool {
        guard let service = avService(for: displayID) else {
            print("[Glint] DDC: No IOAVService found for display \(displayID)")
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
            IOAVServiceWriteI2C(service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        if result == KERN_SUCCESS {
            usleep(50_000)
            return true
        }
        print("[Glint] DDC write failed: \(result)")
        return false
    }

    private func avServiceRead(command: UInt8, displayID: CGDirectDisplayID) -> DDCReadResult? {
        guard let service = avService(for: displayID) else {
            print("[Glint] DDC: No IOAVService found for display \(displayID)")
            return nil
        }

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
            IOAVServiceWriteI2C(service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        guard writeResult == KERN_SUCCESS else {
            print("[Glint] DDC read (write phase) failed: \(writeResult)")
            return nil
        }

        // Wait for display to prepare response
        usleep(40_000)

        // Step 2: Read response
        var replyData = [UInt8](repeating: 0, count: 12)
        let readResult = replyData.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            IOAVServiceReadI2C(service, 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }

        guard readResult == KERN_SUCCESS else {
            print("[Glint] DDC read (read phase) failed: \(readResult)")
            return nil
        }

        // Parse VCP reply
        // Expected: [source, length, 0x02, result_code, vcp_opcode, type_code, max_hi, max_lo, cur_hi, cur_lo, checksum]
        // Find the 0x02 (feature reply opcode) in the response
        guard let replyStart = replyData.firstIndex(of: 0x02),
              replyStart + 8 <= replyData.count,
              replyData[replyStart + 2] == command else {
            print("[Glint] DDC read: invalid reply for VCP 0x\(String(command, radix: 16))")
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
