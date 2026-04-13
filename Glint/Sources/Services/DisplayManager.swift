import AppKit
import Combine
import CoreAudio

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

    /// Tracks whether we've synced on first keystroke
    private var brightnessSynced = false
    private var volumeSynced = false

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
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let name = displayName(for: id)
            var display = ExternalDisplay(
                id: id,
                name: name,
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id)
            )

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

    // MARK: - Brightness

    func adjustBrightness(by step: Int) {
        let syncMode = Preferences.shared.syncWithBuiltIn

        // On first keystroke, sync externals to built-in brightness
        if !brightnessSynced && syncMode && hasBuiltInDisplay() {
            syncBrightnessToBuiltIn()
            brightnessSynced = true
        }

        // Adjust external displays via DDC
        for display in displays {
            let delta = stepToAbsolute(step, max: display.maxBrightness ?? 100)
            if let newVal = ddc.adjust(vcp: .brightness, by: delta, on: display.id) {
                if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                    displays[idx].brightness = newVal
                }
            }
        }

        // Also adjust built-in display programmatically (since we consume the event)
        if syncMode {
            adjustBuiltInBrightness(by: step)
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

    // MARK: - Volume

    func adjustVolume(by step: Int) {
        let syncMode = Preferences.shared.syncWithBuiltIn

        // On first keystroke, sync externals to system volume
        if !volumeSynced && syncMode && hasBuiltInDisplay() {
            syncVolumeToSystem()
            volumeSynced = true
        }

        // Adjust external displays via DDC
        for display in displays {
            let delta = stepToAbsolute(step, max: display.maxVolume ?? 100)
            if let newVal = ddc.adjust(vcp: .volume, by: delta, on: display.id) {
                if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                    displays[idx].volume = newVal
                }
            }
        }

        // Also adjust system volume programmatically (since we consume the event)
        if syncMode {
            adjustSystemVolume(by: step)
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

    func toggleMute() {
        // Toggle DDC mute on external displays
        for display in displays {
            if (display.volume ?? 0) > 0 {
                setVolume(0, for: display.id)
            } else {
                setVolume(50, for: display.id)
            }
        }

        // Also toggle system mute
        if Preferences.shared.syncWithBuiltIn {
            toggleSystemMute()
        }
    }

    // MARK: - System Volume Control (CoreAudio)

    private func adjustSystemVolume(by step: Int) {
        guard let device = defaultOutputDevice() else { return }
        let currentVolume = systemVolume(device: device) ?? 0.5
        let delta: Float = Float(step) * 0.0625 // ~6% per step, matches macOS
        let newVolume = max(0, min(1, currentVolume + delta))
        setSystemVolume(device: device, volume: newVolume)

        // Unmute if adjusting volume up
        if step > 0 {
            setSystemMute(device: device, muted: false)
        }
    }

    private func toggleSystemMute() {
        guard let device = defaultOutputDevice() else { return }
        let muted = systemMute(device: device) ?? false
        setSystemMute(device: device, muted: !muted)
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func systemVolume(device: AudioDeviceID) -> Float? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    private func setSystemVolume(device: AudioDeviceID, volume: Float) {
        var vol = volume
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue {
                AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            }
        }
    }

    private func systemMute(device: AudioDeviceID) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return nil
    }

    private func setSystemMute(device: AudioDeviceID, muted: Bool) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = muted ? 1 : 0
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue {
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
        }
    }

    // MARK: - Built-in Brightness Control (IOKit)

    private func adjustBuiltInBrightness(by step: Int) {
        guard let current = getBuiltInBrightness() else { return }
        let delta: Float = Float(step) * 0.0625 // ~6% per step
        let newBrightness = max(0, min(1, current + delta))
        setBuiltInBrightness(newBrightness)
    }

    private func setBuiltInBrightness(_ brightness: Float) {
        guard let service = builtInDisplayService() else { return }
        defer { IOObjectRelease(service) }
        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, brightness)
    }

    // MARK: - Sync

    func hasBuiltInDisplay() -> Bool {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 { return true }
        }
        return false
    }

    private func syncBrightnessToBuiltIn() {
        guard let builtInBrightness = getBuiltInBrightness() else { return }
        let percent = Int(builtInBrightness * 100)
        for display in displays {
            setBrightness(percent, for: display.id)
        }
    }

    private func syncVolumeToSystem() {
        guard let device = defaultOutputDevice() else { return }
        let vol = systemVolume(device: device) ?? 0.5
        let percent = Int(vol * 100)
        for display in displays {
            setVolume(percent, for: display.id)
        }
    }

    private func getBuiltInBrightness() -> Float? {
        guard let service = builtInDisplayService() else { return nil }
        defer { IOObjectRelease(service) }
        var brightness: Float = 0
        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        return result == kIOReturnSuccess ? brightness : nil
    }

    /// Gets the system output volume (0.0–1.0) using CoreAudio.
    private func getSystemVolume() -> Float {
        guard let device = defaultOutputDevice() else { return 0.5 }
        return systemVolume(device: device) ?? 0.5
    }

    // MARK: - Private Helpers

    private func builtInDisplayService() -> io_service_t? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)

        for i in 0..<Int(count) {
            let id = displayIDs[i]
            guard CGDisplayIsBuiltin(id) != 0 else { continue }

            let vendorNumber = CGDisplayVendorNumber(id)
            let modelNumber = CGDisplayModelNumber(id)

            var iter: io_iterator_t = 0
            let matching = IOServiceMatching("IODisplayConnect")
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
                continue
            }

            var service = IOIteratorNext(iter)
            while service != 0 {
                let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                    .takeRetainedValue() as NSDictionary
                let vid = info[kDisplayVendorID] as? UInt32 ?? 0
                let pid = info[kDisplayProductID] as? UInt32 ?? 0

                if vid == vendorNumber && pid == modelNumber {
                    IOObjectRelease(iter)
                    return service
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        return nil
    }

    private func startMonitoring() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.brightnessSynced = false
            self?.volumeSynced = false
            self?.refresh()
        }
    }

    /// Convert a ±step (e.g., ±1) to an absolute DDC value delta.
    private func stepToAbsolute(_ step: Int, max: UInt16) -> Int {
        let perStep = Swift.max(1, Int(Double(max) * 0.0625))
        return step > 0 ? perStep : -perStep
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
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
