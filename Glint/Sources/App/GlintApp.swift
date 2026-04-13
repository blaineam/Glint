import SwiftUI

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window — menu bar only (LSUIElement = true in Info.plist)
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show menu bar icon unless user chose invisible mode
        if !Preferences.shared.hideMenuBarIcon {
            setupMenuBar()
        }

        // Start intercepting media keys
        MediaKeyInterceptor.shared.start()

        // If event tap failed, prompt for accessibility
        if !MediaKeyInterceptor.shared.isActive {
            promptAccessibility()
        }

        // Listen for preference changes to show/hide menu bar icon
        NotificationCenter.default.addObserver(
            forName: .glintMenuBarVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if Preferences.shared.hideMenuBarIcon {
                self?.removeMenuBar()
            } else {
                self?.setupMenuBar()
            }
        }
    }

    /// Called when the user opens the app a second time (e.g., from Applications).
    /// In invisible mode this is the only way to access settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Preferences.shared.hideMenuBarIcon {
            // In invisible mode: open settings directly
            SettingsWindowController.shared.show()
        } else if let button = statusItem?.button {
            // In menu bar mode: show the popover
            togglePopover()
        }
        return false
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Glint")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        popover.behavior = .transient
        self.popover = popover
    }

    private func removeMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "Glint needs Accessibility access to intercept media keys and control your display brightness and volume via DDC.\n\nPlease add Glint in System Settings > Privacy & Security > Accessibility.\n\nAfter enabling access, you will need to quit and relaunch Glint for it to take effect."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}

extension Notification.Name {
    static let glintMenuBarVisibilityChanged = Notification.Name("glintMenuBarVisibilityChanged")
}
