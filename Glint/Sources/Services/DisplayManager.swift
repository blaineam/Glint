import AppKit
import Combine
import CoreAudio

// Private DisplayServices API — reliable brightness control on Apple Silicon
@_silgen_name("DisplayServicesSetBrightness")
private func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
private func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

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
        DebugLogger.shared.log("DISPLAYS: found \(externals.count) external(s): \(externals.map { "\($0.name) (id=\($0.id), brightness=\($0.brightness ?? 0)/\($0.maxBrightness ?? 0), volume=\($0.volume ?? 0)/\($0.maxVolume ?? 0))" })")
    }

    // MARK: - Cursor Display Detection

    /// Returns the CGDirectDisplayID of the display the mouse cursor is currently on.
    func displayUnderCursor() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        }
        return nil
    }

    /// Returns the NSScreen the mouse cursor is currently on.
    func screenUnderCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    /// Returns brightness percent for any display (built-in or external).
    func brightnessPercent(for displayID: CGDirectDisplayID) -> Int? {
        if CGDisplayIsBuiltin(displayID) != 0 {
            guard let b = getBuiltInBrightness() else { return nil }
            return Int(round(b * 100))
        }
        return displays.first(where: { $0.id == displayID })?.brightnessPercent
    }

    /// Returns the current volume percent based on the audio output.
    /// Uses DDC volume if audio is routed to HDMI/DP, system volume otherwise.
    func currentVolumePercent() -> Int {
        if isAudioOutputDisplayBased() {
            // Audio going to a monitor — use DDC volume from first external display
            return displays.first?.volumePercent ?? 0
        } else {
            return Int(round(getSystemVolume() * 100))
        }
    }

    /// Returns true if the default audio output is a monitor (HDMI/DisplayPort/USB).
    /// Checks transport type for HDMI, DisplayPort, and USB connections, then also
    /// matches the audio device name against connected display names to catch any
    /// edge cases where the transport type doesn't clearly indicate a monitor.
    func isAudioOutputDisplayBased() -> Bool {
        let log = DebugLogger.shared
        guard let device = defaultOutputDevice() else {
            log.log("AUDIO: No default output device")
            return false
        }

        let deviceName = audioDeviceName(for: device) ?? "unknown"

        // Check transport type — covers direct HDMI, DisplayPort, and USB-C hub connections
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transportType) == noErr {
            let transportName = transportTypeName(transportType)
            log.log("AUDIO: device=\"\(deviceName)\" transport=\(transportName) (0x\(String(transportType, radix: 16)))")

            if transportType == kAudioDeviceTransportTypeHDMI
                || transportType == kAudioDeviceTransportTypeDisplayPort {
                log.log("AUDIO: -> display-based (HDMI/DP transport)")
                return true
            }

            // USB transport — could be a monitor via USB-C hub or a USB headset/DAC.
            // Match audio device name against connected display names to distinguish.
            if transportType == kAudioDeviceTransportTypeUSB {
                let match = audioDeviceMatchesDisplay(device)
                log.log("AUDIO: USB transport, display name match = \(match)")
                return match
            }
        } else {
            log.log("AUDIO: device=\"\(deviceName)\" transport=unknown (query failed)")
        }

        // Final fallback: name match regardless of transport type
        let match = audioDeviceMatchesDisplay(device)
        log.log("AUDIO: fallback name match = \(match)")
        return match
    }

    /// Returns true if the audio device name matches any connected external display name.
    /// Uses word-level partial matching to handle cases where names partially overlap
    /// (e.g., audio "LG HDR 4K" matching display "LG HDR 4K (2)").
    private func audioDeviceMatchesDisplay(_ deviceID: AudioDeviceID) -> Bool {
        guard let audioName = audioDeviceName(for: deviceID)?.lowercased() else { return false }
        let log = DebugLogger.shared
        let displayNames = displays.map { $0.name }
        log.log("AUDIO: matching audio=\"\(audioName)\" against displays=\(displayNames)")

        return displays.contains { display in
            let displayName = display.name.lowercased()
            // Full containment match
            if audioName.contains(displayName) || displayName.contains(audioName) {
                return true
            }
            // Partial word match — check if significant words overlap
            let audioWords = Set(audioName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let displayWords = Set(displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let common = audioWords.intersection(displayWords)
            return common.count >= 2 || (!audioWords.isEmpty && common == audioWords) || (!displayWords.isEmpty && common == displayWords)
        }
    }

    private func transportTypeName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        default: return "Other"
        }
    }

    private func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    // MARK: - Brightness

    func adjustBrightness(by step: Int) {
        let syncMode = Preferences.shared.syncWithBuiltIn
        let cursorDisplayID = displayUnderCursor()

        if syncMode {
            // On first keystroke, sync ALL displays to the cursor display's brightness
            if !brightnessSynced {
                if let cursorID = cursorDisplayID {
                    syncAllBrightnesses(to: cursorID)
                }
                brightnessSynced = true
            }

            // Adjust ALL external displays via DDC
            for display in displays {
                let delta = stepToAbsolute(step, max: display.maxBrightness ?? 100)
                if let newVal = ddc.adjust(vcp: .brightness, by: delta, on: display.id) {
                    if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                        displays[idx].brightness = newVal
                    }
                }
            }

            // Also adjust built-in display
            if hasBuiltInDisplay() {
                adjustBuiltInBrightness(by: step)
            }
        } else {
            // Only adjust the display the cursor is on
            guard let cursorID = cursorDisplayID else { return }

            if CGDisplayIsBuiltin(cursorID) != 0 {
                adjustBuiltInBrightness(by: step)
            } else if let display = displays.first(where: { $0.id == cursorID }) {
                let delta = stepToAbsolute(step, max: display.maxBrightness ?? 100)
                if let newVal = ddc.adjust(vcp: .brightness, by: delta, on: cursorID) {
                    if let idx = displays.firstIndex(where: { $0.id == cursorID }) {
                        displays[idx].brightness = newVal
                    }
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

    /// Sets brightness on ALL displays (externals + built-in) to the same percentage.
    func setBrightnessForAll(_ percent: Int) {
        for display in displays {
            setBrightness(percent, for: display.id)
        }
        if hasBuiltInDisplay() {
            setBuiltInBrightness(Float(percent) / 100.0)
        }
    }

    // MARK: - Volume

    func adjustVolume(by step: Int) {
        let syncMode = Preferences.shared.syncWithBuiltIn
        let displayAudio = isAudioOutputDisplayBased()

        if syncMode {
            // On first keystroke, sync externals to system volume
            if !volumeSynced && hasBuiltInDisplay() {
                syncVolumeToSystem()
                volumeSynced = true
            }

            // Adjust both DDC and system volume
            for display in displays {
                let delta = stepToAbsolute(step, max: display.maxVolume ?? 100)
                if let newVal = ddc.adjust(vcp: .volume, by: delta, on: display.id) {
                    if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                        displays[idx].volume = newVal
                    }
                }
            }
            adjustSystemVolume(by: step)
        } else if displayAudio {
            // Audio going to HDMI/DP — adjust DDC volume only
            for display in displays {
                let delta = stepToAbsolute(step, max: display.maxVolume ?? 100)
                if let newVal = ddc.adjust(vcp: .volume, by: delta, on: display.id) {
                    if let idx = displays.firstIndex(where: { $0.id == display.id }) {
                        displays[idx].volume = newVal
                    }
                }
            }
        } else {
            // Audio going to built-in/headphones/USB/BT — adjust system volume only
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

    /// Toggles mute and returns whether the output is now muted.
    func toggleMute() -> Bool {
        let syncMode = Preferences.shared.syncWithBuiltIn
        let displayAudio = isAudioOutputDisplayBased()
        var muted = false

        if syncMode || displayAudio {
            // Toggle DDC mute on external displays
            for display in displays {
                if (display.volume ?? 0) > 0 {
                    setVolume(0, for: display.id)
                    muted = true
                } else {
                    setVolume(50, for: display.id)
                    muted = false
                }
            }
        }

        if syncMode || !displayAudio {
            toggleSystemMute()
            if let device = defaultOutputDevice() {
                muted = systemMute(device: device) ?? muted
            }
        }

        return muted
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

    // MARK: - Built-in Brightness Control

    private func adjustBuiltInBrightness(by step: Int) {
        guard let current = getBuiltInBrightness() else { return }
        let delta: Float = Float(step) * 0.0625 // ~6% per step
        let newBrightness = max(0, min(1, current + delta))
        setBuiltInBrightness(newBrightness)
    }

    private func setBuiltInBrightness(_ brightness: Float) {
        guard let builtInID = builtInDisplayID() else { return }
        // Use private DisplayServices API — works reliably on Apple Silicon
        let result = DisplayServicesSetBrightness(builtInID, brightness)
        if result != 0 {
            // Fallback to IOKit
            if let service = builtInDisplayService() {
                IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, brightness)
                IOObjectRelease(service)
            }
        }
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

    /// Syncs ALL displays to match the brightness of the given target display.
    private func syncAllBrightnesses(to targetDisplayID: CGDirectDisplayID) {
        let targetPercent: Int

        if CGDisplayIsBuiltin(targetDisplayID) != 0 {
            guard let brightness = getBuiltInBrightness() else { return }
            targetPercent = Int(round(brightness * 100))
        } else {
            guard let display = displays.first(where: { $0.id == targetDisplayID }) else { return }
            targetPercent = display.brightnessPercent
        }

        // Set all external displays to target
        for display in displays {
            if display.id != targetDisplayID {
                setBrightness(targetPercent, for: display.id)
            }
        }

        // Set built-in to target if target is not the built-in
        if CGDisplayIsBuiltin(targetDisplayID) == 0, hasBuiltInDisplay() {
            setBuiltInBrightness(Float(targetPercent) / 100.0)
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
        guard let builtInID = builtInDisplayID() else { return nil }
        // Use private DisplayServices API first
        var brightness: Float = 0
        if DisplayServicesGetBrightness(builtInID, &brightness) == 0 {
            return brightness
        }
        // Fallback to IOKit
        guard let service = builtInDisplayService() else { return nil }
        defer { IOObjectRelease(service) }
        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        return result == kIOReturnSuccess ? brightness : nil
    }

    private func builtInDisplayID() -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                return displayIDs[i]
            }
        }
        return nil
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
