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

    /// Creates the session event tap for `mask`, passing `userInfo` to the C callback.
    typealias TapFactory = (_ mask: CGEventMask, _ userInfo: UnsafeMutableRawPointer) -> CFMachPort?
    /// Switches a tap on or off.
    typealias TapSwitch = (_ tap: CFMachPort, _ enable: Bool) -> Void
    /// Shows the on-screen pill: icon, value, screen.
    typealias OSDPresenter = @MainActor (_ icon: String, _ value: Int, _ screen: NSScreen?) -> Void

    private let preferences: () -> Preferences
    private let displayManager: () -> DisplayManager
    private let tapFactory: TapFactory
    private let tapSwitch: TapSwitch
    private let presentOSD: OSDPresenter

    /// The app uses `shared`; tests inject a fake tap, preferences, display manager and OSD
    /// so no real event tap, DDC traffic or on-screen pill is involved.
    init(
        preferences: @escaping () -> Preferences = { Preferences.shared },
        displayManager: @escaping () -> DisplayManager = { DisplayManager.shared },
        tapFactory: @escaping TapFactory = MediaKeyInterceptor.systemTap,
        tapSwitch: @escaping TapSwitch = { CGEvent.tapEnable(tap: $0, enable: $1) },
        presentOSD: @escaping OSDPresenter = { OSDOverlay.shared.show(icon: $0, value: $1, on: $2) }
    ) {
        self.preferences = preferences
        self.displayManager = displayManager
        self.tapFactory = tapFactory
        self.tapSwitch = tapSwitch
        self.presentOSD = presentOSD
    }

    private static func systemTap(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyCallback,
            userInfo: userInfo
        )
    }

    /// Runs after every DDC job already queued has finished (tests only need it to wait).
    func waitForPendingWork() {
        ddcQueue.sync {}
    }

    func start() {
        guard eventTap == nil else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << 14) // NX_SYSDEFINED

        guard let tap = tapFactory(mask, selfPtr) else {
            print("[Glint] Failed to create event tap. Grant Accessibility permission.")
            isActive = false
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        tapSwitch(tap, true)
        isActive = true
    }

    /// macOS switches a tap off when its callback is too slow (or on user input); turn it
    /// back on so the keys keep working.
    fileprivate func reenableTap() {
        if let tap = eventTap { tapSwitch(tap, true) }
    }

    func stop() {
        if let tap = eventTap {
            tapSwitch(tap, false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    /// Called from the C callback. Returns immediately — DDC work is dispatched async.
    func handleMediaKey(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        guard type == CGEventType(rawValue: 14)! else { return event }

        let nsEvent = NSEvent(cgEvent: event)
        guard let nsEvent = nsEvent,
              nsEvent.subtype.rawValue == 8 else {
            return event
        }

        let key = MediaKey(data1: nsEvent.data1)
        let action = Self.action(
            for: key,
            prefs: preferences(),
            ddcBrightnessAvailable: displayManager().ddcBrightnessAvailable,
            ddcVolumeAvailable: displayManager().ddcVolumeAvailable
        )

        guard action != .passThrough else { return event }
        perform(action)
        return nil // Consume — Glint handles everything
    }

    /// Carries out a consuming action off the event-tap thread.
    private func perform(_ action: Action) {
        switch action {
        case .passThrough:
            return
        case .brightness(let step):
            ddcQueue.async {
                self.displayManager().adjustBrightness(by: step)
                self.showOSD(.brightness)
            }
        case .volume(let step):
            ddcQueue.async {
                self.displayManager().adjustVolume(by: step)
                self.showOSD(.volume)
            }
        case .toggleMute:
            ddcQueue.async {
                let muted = self.displayManager().toggleMute()
                self.showMuteOSD(muted: muted)
            }
        }
    }

    #if DEBUG
    /// UI-test mode: routes a decoded key exactly as the event tap would (XCUITest
    /// cannot synthesize NX_SYSDEFINED events).
    func simulate(_ key: MediaKey) {
        let action = Self.action(
            for: key,
            prefs: preferences(),
            ddcBrightnessAvailable: displayManager().ddcBrightnessAvailable,
            ddcVolumeAvailable: displayManager().ddcVolumeAvailable
        )
        perform(action)
    }
    #endif

    /// What Glint does with a decoded media key. Anything but `.passThrough` consumes the
    /// event, so macOS never sees it — getting this wrong kills the user's keys.
    enum Action: Equatable {
        case passThrough
        case brightness(Int)
        case volume(Int)
        case toggleMute
    }

    /// Decides whether to consume a media key and what to do with it. The DDC availability
    /// flags are autoclosures so they are only evaluated when the "always intercept"
    /// preference doesn't already decide.
    static func action(
        for key: MediaKey,
        prefs: Preferences,
        ddcBrightnessAvailable: @autoclosure () -> Bool,
        ddcVolumeAvailable: @autoclosure () -> Bool
    ) -> Action {
        guard key.isDown else { return .passThrough }

        switch key.keyCode {
        case Int(NX_KEYTYPE_BRIGHTNESS_UP), Int(NX_KEYTYPE_BRIGHTNESS_DOWN):
            guard prefs.interceptBrightness,
                  prefs.alwaysInterceptBrightness || ddcBrightnessAvailable() else { return .passThrough }
            return .brightness(key.keyCode == Int(NX_KEYTYPE_BRIGHTNESS_UP) ? 1 : -1)

        case Int(NX_KEYTYPE_SOUND_UP), Int(NX_KEYTYPE_SOUND_DOWN), Int(NX_KEYTYPE_MUTE):
            guard prefs.interceptVolume,
                  prefs.alwaysInterceptVolume || ddcVolumeAvailable() else { return .passThrough }
            switch key.keyCode {
            case Int(NX_KEYTYPE_SOUND_UP): return .volume(1)
            case Int(NX_KEYTYPE_SOUND_DOWN): return .volume(-1)
            default: return .toggleMute
            }

        default:
            return .passThrough
        }
    }

    // MARK: - OSD

    private enum OSDType { case brightness, volume }

    private func showOSD(_ type: OSDType) {
        let dm = displayManager()
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
            percent = dm.currentVolumePercent()
        }
        let present = presentOSD
        Task { @MainActor in
            present(icon, percent, cursorScreen)
        }
    }

    private func showMuteOSD(muted: Bool) {
        let dm = displayManager()
        let cursorScreen = dm.screenUnderCursor()
        let icon = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let percent = muted ? 0 : dm.currentVolumePercent()
        let present = presentOSD
        Task { @MainActor in
            present(icon, percent, cursorScreen)
        }
    }
}

// MARK: - C Callback

func mediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { interceptor.reenableTap() }
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

// MARK: - Media key decoding

/// An NX_SYSDEFINED (subtype 8, "aux control button") event's payload, decoded from
/// NSEvent.data1: the NX_KEYTYPE in the high 16 bits, key state in bits 8–15
/// (0x0A = down, 0x0B = up).
struct MediaKey: Equatable {
    let keyCode: Int
    let isDown: Bool

    init(keyCode: Int, isDown: Bool) {
        self.keyCode = keyCode
        self.isDown = isDown
    }

    init(data1: Int) {
        keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        isDown = keyState == 0x0A
    }
}
