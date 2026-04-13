import AppKit
import Carbon.HIToolbox

/// Intercepts system media keys (brightness, volume) and routes them to DDC control.
/// Always consumes events and handles everything programmatically — no macOS OSD.
final class MediaKeyInterceptor: ObservableObject, @unchecked Sendable {
    static let shared = MediaKeyInterceptor()

    @Published var isActive = false

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Background queue for DDC operations so we don't block the event tap.
    private let ddcQueue = DispatchQueue(label: "com.blainemiller.Glint.ddc", qos: .userInteractive)

    private init() {}

    func start() {
        guard eventTap == nil else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << 14) // NX_SYSDEFINED

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[Glint] Failed to create event tap. Grant Accessibility permission.")
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

    /// Called from the C callback. Returns immediately — DDC work is dispatched async.
    fileprivate func handleMediaKey(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        guard type == CGEventType(rawValue: 14)! else { return event }

        let nsEvent = NSEvent(cgEvent: event)
        guard let nsEvent = nsEvent,
              nsEvent.subtype.rawValue == 8 else {
            return event
        }

        let keyCode = Int((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isDown = keyState == 0x0A

        guard isDown else { return event }

        let prefs = Preferences.shared

        switch keyCode {
        case Int(NX_KEYTYPE_BRIGHTNESS_UP):
            guard prefs.interceptBrightness else { return event }
            ddcQueue.async {
                DisplayManager.shared.adjustBrightness(by: 1)
                self.showOSD(.brightness)
            }
            return nil // Consume — Glint handles everything

        case Int(NX_KEYTYPE_BRIGHTNESS_DOWN):
            guard prefs.interceptBrightness else { return event }
            ddcQueue.async {
                DisplayManager.shared.adjustBrightness(by: -1)
                self.showOSD(.brightness)
            }
            return nil

        case Int(NX_KEYTYPE_SOUND_UP):
            guard prefs.interceptVolume else { return event }
            ddcQueue.async {
                DisplayManager.shared.adjustVolume(by: 1)
                self.showOSD(.volume)
            }
            return nil

        case Int(NX_KEYTYPE_SOUND_DOWN):
            guard prefs.interceptVolume else { return event }
            ddcQueue.async {
                DisplayManager.shared.adjustVolume(by: -1)
                self.showOSD(.volume)
            }
            return nil

        case Int(NX_KEYTYPE_MUTE):
            guard prefs.interceptVolume else { return event }
            ddcQueue.async {
                DisplayManager.shared.toggleMute()
                self.showOSD(.volume)
            }
            return nil

        default:
            return event
        }
    }

    // MARK: - OSD

    private enum OSDType { case brightness, volume }

    private func showOSD(_ type: OSDType) {
        let dm = DisplayManager.shared
        let cursorDisplayID = dm.displayUnderCursor()
        let cursorScreen = dm.screenUnderCursor()

        let percent: Int
        let icon: String
        switch type {
        case .brightness:
            icon = "sun.max.fill"
            if let cursorID = cursorDisplayID,
               let p = dm.brightnessPercent(for: cursorID) {
                percent = p
            } else {
                percent = dm.displays.first?.brightnessPercent ?? 0
            }
        case .volume:
            icon = "speaker.wave.2.fill"
            percent = dm.displays.first?.volumePercent ?? 0
        }
        Task { @MainActor in
            OSDOverlay.shared.show(icon: icon, value: percent, on: cursorScreen)
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
    let result = interceptor.handleMediaKey(proxy: proxy, type: type, event: event)

    if let result = result {
        return Unmanaged.passRetained(result)
    }
    return nil
}
