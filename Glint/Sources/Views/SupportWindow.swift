import SwiftUI
import MillerKit

// MARK: - Support Window Controller

/// The dedicated, real window for the support surface (MillerKit's
/// `SupportWindowContent`: feedback rows + the rate/other-apps block).
///
/// Glint is a menu-bar app (LSUIElement), so this must be a real window and
/// never a sheet: a sheet attaches to the transient popover and is torn down
/// with it. It mirrors `SettingsWindowController` rather than using a SwiftUI
/// `Window` scene because the app's floor is macOS 13, where the
/// `openWindow` environment action is not reliable from AppKit-hosted views —
/// and both call sites (the popover and the manual settings window) are
/// exactly that.
final class SupportWindowController: @unchecked Sendable {
    static let shared = SupportWindowController()

    private var window: NSWindow?

    private init() {}

    @MainActor func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SupportWindowContent(app: .glint))

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Support Glint", comment: "Title of the support window")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
