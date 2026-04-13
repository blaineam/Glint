import AppKit
import Combine

struct ExternalDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let vendorNumber: UInt32
    let modelNumber: UInt32
    var brightness: UInt16?
    var maxBrightness: UInt16?
    var volume: UInt16?
    var maxVolume: UInt16?

    var brightnessPercent: Int {
        guard let b = brightness, let m = maxBrightness, m > 0 else { return 0 }
        return Int(round(Double(b) / Double(m) * 100))
    }

    var volumePercent: Int {
        guard let v = volume, let m = maxVolume, m > 0 else { return 0 }
        return Int(round(Double(v) / Double(m) * 100))
    }
}

final class DisplayManager: ObservableObject, @unchecked Sendable {
    static let shared = DisplayManager()

    @Published var displays: [ExternalDisplay] = []

    private let ddc = DDCService.shared
    private var refreshTimer: Timer?

    private init() {
        refresh()
        startMonitoring()
    }

    func refresh() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)

        var externals: [ExternalDisplay] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]

            // Skip built-in displays
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let name = displayName(for: id)
            var display = ExternalDisplay(
                id: id,
                name: name,
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id)
            )

            // Read current DDC values on a background thread
            let brightness = ddc.read(vcp: .brightness, from: id)
            display.brightness = brightness?.currentValue
            display.maxBrightness = brightness?.maxValue

            let volume = ddc.read(vcp: .volume, from: id)
            display.volume = volume?.currentValue
            display.maxVolume = volume?.maxValue

            externals.append(display)
        }

        displays = externals
    }

    func adjustBrightness(by step: Int) {
        for display in displays {
            let delta = stepToAbsolute(step, max: display.maxBrightness ?? 100)
            if let newVal = ddc.adjust(vcp: .brightness, by: delta, on: display.id) {
                if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                    displays[idx].brightness = newVal
                }
            }
        }
    }

    func adjustVolume(by step: Int) {
        for display in displays {
            let delta = stepToAbsolute(step, max: display.maxVolume ?? 100)
            if let newVal = ddc.adjust(vcp: .volume, by: delta, on: display.id) {
                if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                    displays[idx].volume = newVal
                }
            }
        }
    }

    func setBrightness(_ percent: Int, for displayID: CGDirectDisplayID) {
        guard let idx = displays.firstIndex(where: { $0.id == displayID }),
              let maxVal = displays[idx].maxBrightness else { return }
        let value = UInt16(Double(maxVal) * Double(percent) / 100.0)
        if ddc.write(vcp: .brightness, value: value, to: displayID) {
            displays[idx].brightness = value
        }
    }

    func setVolume(_ percent: Int, for displayID: CGDirectDisplayID) {
        guard let idx = displays.firstIndex(where: { $0.id == displayID }),
              let maxVal = displays[idx].maxVolume else { return }
        let value = UInt16(Double(maxVal) * Double(percent) / 100.0)
        if ddc.write(vcp: .volume, value: value, to: displayID) {
            displays[idx].volume = value
        }
    }

    // MARK: - Private

    private func startMonitoring() {
        // Refresh when displays change
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Convert a ±step (e.g., ±6 for ~6%) to an absolute DDC value delta.
    private func stepToAbsolute(_ step: Int, max: UInt16) -> Int {
        let perStep = Swift.max(1, Int(Double(max) * 0.06))
        return step > 0 ? perStep : -perStep
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        // Use IODisplayConnect to find the display's localized name
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return "External Display"
        }
        defer { IOObjectRelease(iter) }

        let vendorNumber = CGDisplayVendorNumber(displayID)
        let modelNumber = CGDisplayModelNumber(displayID)

        var service = IOIteratorNext(iter)
        while service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as NSDictionary

            let vid = info[kDisplayVendorID] as? UInt32 ?? 0
            let pid = info[kDisplayProductID] as? UInt32 ?? 0

            if vid == vendorNumber && pid == modelNumber {
                if let names = info[kDisplayProductName] as? [String: String],
                   let name = names.values.first {
                    IOObjectRelease(service)
                    return name
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return "External Display"
    }
}
