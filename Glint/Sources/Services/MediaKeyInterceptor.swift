import AppKit
import Carbon.HIToolbox

/// Intercepts system media keys (brightness, volume) and routes them to DDC control.
/// All methods must be called from the main thread.
final class MediaKeyInterceptor: ObservableObject, @unchecked Sendable {
    static let shared = MediaKeyInterceptor()

    @Published var isActive = false

    /// Which keys to intercept
    @Published var interceptBrightness = true
    @Published var interceptVolume = true

    /// When true, media key events pass through to macOS (so built-in display/speakers
    /// also adjust) while Glint simultaneously sends DDC commands to external displays.
    @Published var syncWithBuiltIn = true

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        guard eventTap == nil else { return }

        // We need to capture self in a C callback, so we use an unmanaged pointer
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << 14) // NSEvent.EventType.systemDefined (NX_SYSDEFINED)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[Glint] Failed to create event tap. Grant Accessibility permission in System Settings > Privacy & Security > Accessibility.")
            isActive = false
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    /// Called from the C callback on the main thread.
    fileprivate func handleMediaKey(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        // System-defined events carry media key info
        guard type == CGEventType(rawValue: 14)! else { return event } // NX_SYSDEFINED

        let nsEvent = NSEvent(cgEvent: event)
        guard let nsEvent = nsEvent,
              nsEvent.subtype.rawValue == 8 else { // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            return event
        }

        let keyCode = Int((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isDown = keyState == 0x0A // key down

        guard isDown else { return event }

        // When syncWithBuiltIn is on, pass the event through so macOS also
        // adjusts the built-in display/speakers. When off, consume it.
        let passthrough = syncWithBuiltIn ? event : nil

        switch keyCode {
        case Int(NX_KEYTYPE_BRIGHTNESS_UP):
            guard interceptBrightness else { return event }
            DisplayManager.shared.adjustBrightness(by: 1)
            if !syncWithBuiltIn {
                showOSD(.brightness, displays: DisplayManager.shared.displays)
            }
            return passthrough

        case Int(NX_KEYTYPE_BRIGHTNESS_DOWN):
            guard interceptBrightness else { return event }
            DisplayManager.shared.adjustBrightness(by: -1)
            if !syncWithBuiltIn {
                showOSD(.brightness, displays: DisplayManager.shared.displays)
            }
            return passthrough

        case Int(NX_KEYTYPE_SOUND_UP):
            guard interceptVolume else { return event }
            DisplayManager.shared.adjustVolume(by: 1)
            if !syncWithBuiltIn {
                showOSD(.volume, displays: DisplayManager.shared.displays)
            }
            return passthrough

        case Int(NX_KEYTYPE_SOUND_DOWN):
            guard interceptVolume else { return event }
            DisplayManager.shared.adjustVolume(by: -1)
            if !syncWithBuiltIn {
                showOSD(.volume, displays: DisplayManager.shared.displays)
            }
            return passthrough

        case Int(NX_KEYTYPE_MUTE):
            guard interceptVolume else { return event }
            for display in DisplayManager.shared.displays {
                if (display.volume ?? 0) > 0 {
                    DisplayManager.shared.setVolume(0, for: display.id)
                } else {
                    DisplayManager.shared.setVolume(50, for: display.id)
                }
            }
            if !syncWithBuiltIn {
                showOSD(.volume, displays: DisplayManager.shared.displays)
            }
            return passthrough

        default:
            return event
        }
    }

    // MARK: - OSD

    private enum OSDType { case brightness, volume }

    private func showOSD(_ type: OSDType, displays: [ExternalDisplay]) {
        guard let display = displays.first else { return }
        let percent: Int
        switch type {
        case .brightness: percent = display.brightnessPercent
        case .volume: percent = display.volumePercent
        }

        let icon = type == .brightness ? "sun.max.fill" : "speaker.wave.2.fill"
        let value = percent
        Task { @MainActor in
            OSDOverlay.shared.show(icon: icon, value: value)
        }
    }
}

// MARK: - C Callback

private func mediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // If the tap is disabled/timed out, re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                if let tap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

    // Event taps fire on the run loop thread (main thread for us).
    let result: CGEvent? = interceptor.handleMediaKey(proxy: proxy, type: type, event: event)

    if let result = result {
        return Unmanaged.passRetained(result)
    }
    return nil
}
