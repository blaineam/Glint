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
        setupMenuBar()

        // Start intercepting media keys
        MediaKeyInterceptor.shared.start()

        // If event tap failed, prompt for accessibility
        if !MediaKeyInterceptor.shared.isActive {
            promptAccessibility()
        }
    }

    private func setupMenuBar() {
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
        alert.informativeText = "Glint needs Accessibility access to intercept media keys and control your display brightness and volume via DDC.\n\nPlease add Glint in System Settings > Privacy & Security > Accessibility."
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
