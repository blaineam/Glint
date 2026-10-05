#if DEBUG
import AppKit
import CoreAudio
import SwiftUI

/// DEBUG-only deterministic mode for GlintUITests, switched on by the `-UITestMode`
/// launch argument. None of this is compiled into Release builds.
///
/// In UI-test mode Glint:
/// - reads and writes preferences in a throwaway `com.blainemiller.Glint.uitest` suite
///   (cleared at launch unless `GLINT_UITEST_KEEP_DEFAULTS=1`) and never registers a
///   login item;
/// - talks to in-memory fixture monitors instead of IOKit / I2C, and to a fake CoreAudio
///   output, so no real display or speaker changes;
/// - never creates the media-key event tap; the Accessibility state is stubbed
///   (`GLINT_UITEST_ACCESSIBILITY=granted|denied`) and the permission alert only appears
///   when `GLINT_UITEST_SHOW_ACCESSIBILITY_ALERT=1`;
/// - records URLs it would open (System Settings, mailto:, web) instead of opening them;
/// - opens a "Glint Menu (UI Test)" window hosting the menu-bar popover content plus
///   buttons that simulate the media keys, because a status item can be hidden by the
///   notch or a menu-bar manager and XCUITest cannot synthesize NX_SYSDEFINED key events.
///
/// Launch environment:
/// - `GLINT_UITEST_DISPLAYS`: `two` (default; monitor A answers DDC, monitor B doesn't),
///   `one` (monitor A only), `none`.
/// - `GLINT_UITEST_HIDE_ICON=1`: seed "Hide menu bar icon" on.
/// - `GLINT_UITEST_OSD`: `brightness:<n>`, `volume:<n>` or `mute` shows the OSD at launch.
/// - `GLINT_UITEST_NO_HARNESS=1`: don't open the harness window (invisible-mode tests).
enum UITestMode {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-UITestMode")

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static let defaultsSuite = "com.blainemiller.Glint.uitest"
    /// The OSD normally fades after 1.2 s; long enough here for a test to read it.
    static let osdHideDelay: Duration = .seconds(30)

    enum DisplayFixture: String {
        case two, one, none
    }

    static var displayFixture: DisplayFixture {
        DisplayFixture(rawValue: env["GLINT_UITEST_DISPLAYS"] ?? "") ?? .two
    }

    static var accessibilityGranted: Bool { env["GLINT_UITEST_ACCESSIBILITY"] != "denied" }
    static var showsAccessibilityAlert: Bool { env["GLINT_UITEST_SHOW_ACCESSIBILITY_ALERT"] == "1" }

    // MARK: - Shared instances

    static func makePreferences() -> Preferences {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        if env["GLINT_UITEST_KEEP_DEFAULTS"] != "1" {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        if env["GLINT_UITEST_HIDE_ICON"] == "1" {
            defaults.set(true, forKey: "hideMenuBarIcon")
        }
        return Preferences(defaults: defaults, loginItem: { _ in })
    }

    static func makeDisplayManager() -> DisplayManager {
        let ddc = DDCService(transport: UITestDDCTransport(), busCooldownMicros: 0, sleep: { _ in })
        let manager = DisplayManager(
            preferences: .shared,
            ddc: ddc,
            audio: UITestSystemAudio(),
            environment: UITestDisplayEnvironment(fixture: displayFixture)
        )
        // No startMonitoring(): a real screen change must not matter in a test run.
        manager.refresh()
        return manager
    }

    static func makeDebugLogger() -> DebugLogger {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-uitest", isDirectory: true)
        return DebugLogger(logFileURL: dir.appendingPathComponent("debug.log"))
    }

    // MARK: - URL opening

    /// Records the URL instead of opening System Settings / Mail / a browser.
    @MainActor
    final class Recorder: ObservableObject {
        static let shared = Recorder()
        @Published var lastOpenedURL = ""
    }

    /// Opens `url`, or only records it in UI-test mode.
    @MainActor
    static func open(_ url: URL) {
        if isActive {
            Recorder.shared.lastOpenedURL = url.absoluteString
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Hosting root for a window's SwiftUI content: in UI-test mode, links are recorded
    /// rather than opened and animations are off.
    @MainActor
    static func host<V: View>(_ view: V) -> AnyView {
        guard isActive else { return AnyView(view) }
        return AnyView(
            view
                .environment(\.openURL, OpenURLAction { url in
                    MainActor.assumeIsolated { Recorder.shared.lastOpenedURL = url.absoluteString }
                    return .handled
                })
                .transaction { $0.disablesAnimations = true }
        )
    }

    // MARK: - Launch

    @MainActor private static var harnessWindow: NSWindow?

    /// Stands in for starting the event tap: stub the Accessibility state, optionally show
    /// the real permission alert, then open the harness window and any requested OSD.
    @MainActor
    static func applicationDidFinishLaunching(_ delegate: AppDelegate, promptAccessibility: @escaping @MainActor () -> Void) {
        MediaKeyInterceptor.shared.isActive = accessibilityGranted
        // After launch completes: XCUITest can't finish launching an app that is blocked
        // in a modal alert inside applicationDidFinishLaunching.
        DispatchQueue.main.async { [weak delegate] in
            MainActor.assumeIsolated {
                if showsAccessibilityAlert {
                    promptAccessibility()
                }
                if let delegate, env["GLINT_UITEST_NO_HARNESS"] != "1" {
                    showHarness(delegate)
                }
                if let osd = env["GLINT_UITEST_OSD"] {
                    showOSD(spec: osd)
                }
            }
        }
    }

    @MainActor
    private static func showHarness(_ delegate: AppDelegate) {
        let root = UITestHarnessView(reopen: { [weak delegate] in
            _ = delegate?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: host(root)))
        window.title = "Glint Menu (UI Test)"
        window.identifier = NSUserInterfaceItemIdentifier("glint.uitest.menuWindow")
        window.setAccessibilityIdentifier("glint.uitest.menuWindow")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 40))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        harnessWindow = window
    }

    /// Puts a Settings/Support window at a fixed spot below the harness, away from the
    /// screen centre where system alerts appear, so tests never find it covered.
    @MainActor
    static func place(_ window: NSWindow) {
        guard isActive, let screen = NSScreen.main else { return }
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.maxY - 360))
    }

    @MainActor
    private static func showOSD(spec: String) {
        let parts = spec.split(separator: ":")
        let value = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "brightness": OSDOverlay.shared.show(icon: "sun.max.fill", value: value)
        case "volume": OSDOverlay.shared.show(icon: "speaker.wave.2.fill", value: value)
        case "mute": OSDOverlay.shared.show(icon: "speaker.slash.fill", value: 0)
        default: break
        }
    }
}

// MARK: - Harness window

/// The popover's content plus test-only controls. Strings are deliberately verbatim:
/// none of this ships, so none of it belongs in Localizable.xcstrings.
private struct UITestHarnessView: View {
    let reopen: () -> Void
    @ObservedObject private var recorder = UITestMode.Recorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuBarView()
            Divider()
            HStack {
                key("Bright+", id: "brightnessUp", NX_KEYTYPE_BRIGHTNESS_UP)
                key("Bright-", id: "brightnessDown", NX_KEYTYPE_BRIGHTNESS_DOWN)
                key("Vol+", id: "volumeUp", NX_KEYTYPE_SOUND_UP)
                key("Vol-", id: "volumeDown", NX_KEYTYPE_SOUND_DOWN)
                key("Mute", id: "mute", NX_KEYTYPE_MUTE)
            }
            HStack {
                Button(action: reopen) { Text(verbatim: "Reopen") }
                    .accessibilityIdentifier("glint.uitest.reopen")
                Text(verbatim: recorder.lastOpenedURL.isEmpty ? "-" : recorder.lastOpenedURL)
                    .font(.caption2)
                    .lineLimit(1)
                    .accessibilityIdentifier("glint.uitest.lastOpenedURL")
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private func key(_ title: String, id: String, _ keyType: Int32) -> some View {
        Button {
            MediaKeyInterceptor.shared.simulate(MediaKey(keyCode: Int(keyType), isDown: true))
        } label: {
            Text(verbatim: title)
        }
        .accessibilityIdentifier("glint.uitest.key.\(id)")
    }
}

// MARK: - Fixtures

/// In-memory monitors. Display 101 answers DDC (brightness 60/100, volume 30/100);
/// display 102 never answers a read but accepts writes. Writes update the table, so a
/// Refresh reads back what the sliders wrote.
private final class UITestDDCTransport: DDCTransport {
    private struct Key: Hashable {
        let display: CGDirectDisplayID
        let vcp: UInt8
    }

    private var values: [Key: DDCReadResult] = [
        Key(display: UITestDisplayEnvironment.monitorA, vcp: VCPCode.brightness.rawValue): DDCReadResult(currentValue: 60, maxValue: 100),
        Key(display: UITestDisplayEnvironment.monitorA, vcp: VCPCode.volume.rawValue): DDCReadResult(currentValue: 30, maxValue: 100),
    ]

    func read(command: UInt8, from displayID: CGDirectDisplayID) -> DDCReadAttempt {
        guard displayID == UITestDisplayEnvironment.monitorA,
              let value = values[Key(display: displayID, vcp: command)] else { return .noReply }
        return .value(value)
    }

    func write(command: UInt8, value: UInt16, to displayID: CGDirectDisplayID) -> Bool {
        let key = Key(display: displayID, vcp: command)
        values[key] = DDCReadResult(currentValue: value, maxValue: values[key]?.maxValue ?? 100)
        return true
    }

    func invalidatePortCache() {}
}

private final class UITestDisplayEnvironment: DisplayEnvironment {
    static let builtIn: CGDirectDisplayID = 1
    static let monitorA: CGDirectDisplayID = 101
    static let monitorB: CGDirectDisplayID = 102

    private let externals: [ExternalDisplay]
    private var builtInLevel: Float = 0.5

    init(fixture: UITestMode.DisplayFixture) {
        let a = ExternalDisplay(id: Self.monitorA, name: "Glint Test Monitor A", vendorNumber: 0x1E6D, modelNumber: 101, serialNumber: 1)
        let b = ExternalDisplay(id: Self.monitorB, name: "Glint Test Monitor B", vendorNumber: 0x10AC, modelNumber: 102, serialNumber: 2)
        switch fixture {
        case .two: externals = [a, b]
        case .one: externals = [a]
        case .none: externals = []
        }
    }

    func externalDisplays() -> [ExternalDisplay] { externals }
    func isBuiltIn(_ displayID: CGDirectDisplayID) -> Bool { displayID == Self.builtIn }
    func builtInDisplayID() -> CGDirectDisplayID? { Self.builtIn }
    func builtInBrightness() -> Float? { builtInLevel }
    func setBuiltInBrightness(_ brightness: Float) { builtInLevel = brightness }
    func displayUnderCursor() -> CGDirectDisplayID? { externals.isEmpty ? Self.builtIn : Self.monitorA }
}

/// Built-in speakers at 50 %, unmuted.
private final class UITestSystemAudio: SystemAudio {
    private static let device: AudioDeviceID = 42
    private var level: Float = 0.5
    private var muted = false

    func defaultOutputDevice() -> AudioDeviceID? { Self.device }
    func deviceName(of device: AudioDeviceID) -> String? { "MacBook Pro Speakers" }
    func transportType(of device: AudioDeviceID) -> UInt32? { kAudioDeviceTransportTypeBuiltIn }
    func volume(of device: AudioDeviceID) -> Float? { level }
    func setVolume(_ volume: Float, on device: AudioDeviceID) { level = volume }
    func isMuted(_ device: AudioDeviceID) -> Bool? { muted }
    func setMuted(_ muted: Bool, on device: AudioDeviceID) { self.muted = muted }
}
#endif
