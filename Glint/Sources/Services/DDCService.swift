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

final class DDCService: @unchecked Sendable {
    static let shared = DDCService()

    private init() {}

    // MARK: - Public API

    func read(vcp code: VCPCode, from displayID: CGDirectDisplayID) -> DDCReadResult? {
        guard let framebuffer = framebuffer(for: displayID) else { return nil }
        defer { IOObjectRelease(framebuffer) }
        return ddcRead(service: framebuffer, command: code.rawValue)
    }

    func write(vcp code: VCPCode, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        guard let framebuffer = framebuffer(for: displayID) else { return false }
        defer { IOObjectRelease(framebuffer) }
        return ddcWrite(service: framebuffer, command: code.rawValue, value: value)
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

    // MARK: - Framebuffer Lookup

    private func framebuffer(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOFramebufferI2CInterface")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        // Walk all I2C interfaces and find the one matching our display
        var service: io_service_t = IOIteratorNext(iter)
        while service != 0 {
            // Walk up to the framebuffer parent
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                var parentParent: io_service_t = 0
                if IORegistryEntryGetParentEntry(parent, kIOServicePlane, &parentParent) == KERN_SUCCESS {
                    let vendorID = registryInt(for: "vendor-id", in: parentParent)
                    let displayAttributes = registryInt(for: "IODisplayAttributes", in: parentParent)
                    _ = vendorID
                    _ = displayAttributes
                    IOObjectRelease(parentParent)
                }
                IOObjectRelease(parent)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }

        // Fallback: use CGDisplay vendor/serial matching against IODisplayConnect
        return framebufferByDisplayConnect(displayID: displayID)
    }

    private func framebufferByDisplayConnect(displayID: CGDirectDisplayID) -> io_service_t? {
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
                // Found the display — now get its framebuffer parent that has I2C
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

    // MARK: - I2C Communication

    private func ddcWrite(service: io_service_t, command: UInt8, value: UInt16) -> Bool {
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E // DDC/CI slave address (write)

        // DDC/CI write message: [0x51, 0x84, 0x03, command, valueHigh, valueLow, checksum]
        var data: [UInt8] = [0x51, 0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)]
        let checksum = data.reduce(0x6E, { $0 ^ $1 })
        data.append(checksum)

        request.sendBytes = UInt32(data.count)

        let result = data.withUnsafeMutableBufferPointer { buffer -> Bool in
            request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            return performI2CRequest(service: service, request: &request)
        }

        if result {
            // Small delay for the display to process
            usleep(50_000)
        }
        return result
    }

    private func ddcRead(service: io_service_t, command: UInt8) -> DDCReadResult? {
        // Step 1: Send the "get VCP feature" request
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

        // Wait for display to prepare response
        usleep(40_000)

        // Step 2: Read the response
        var readRequest = IOI2CRequest()
        readRequest.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        readRequest.replyAddress = 0x6F // DDC/CI slave address (read)

        var replyData = [UInt8](repeating: 0, count: 12)
        readRequest.replyBytes = UInt32(replyData.count)

        let readSuccess = replyData.withUnsafeMutableBufferPointer { buffer -> Bool in
            readRequest.replyBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            return performI2CRequest(service: service, request: &readRequest)
        }

        guard readSuccess else { return nil }

        // Parse DDC/CI VCP reply:
        // [source, length, 0x02, result, vcp_opcode, type, max_hi, max_lo, cur_hi, cur_lo, checksum]
        guard replyData.count >= 11,
              replyData[2] == 0x02, // Feature reply opcode
              replyData[4] == command else {
            return nil
        }

        let maxValue = (UInt16(replyData[6]) << 8) | UInt16(replyData[7])
        let currentValue = (UInt16(replyData[8]) << 8) | UInt16(replyData[9])

        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
    }

    private func performI2CRequest(service: io_service_t, request: inout IOI2CRequest) -> Bool {
        // IOFBCopyI2CInterfaceForBus returns an io_service_t interface
        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(service, 0, &i2cInterface) == KERN_SUCCESS,
              i2cInterface != 0 else {
            // Try to find I2C interface from children
            return performI2COnChildren(service: service, request: &request)
        }
        defer { IOObjectRelease(i2cInterface) }

        // Open gets an IOI2CConnectRef for sending requests
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

    private func registryInt(for key: String, in service: io_service_t) -> Int? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (ref.takeRetainedValue() as? NSNumber)?.intValue
    }
}
