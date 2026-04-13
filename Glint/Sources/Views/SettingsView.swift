import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var interceptor = MediaKeyInterceptor.shared

    var body: some View {
        Form {
            Section("Keyboard Controls") {
                Toggle("Intercept brightness keys", isOn: $prefs.interceptBrightness)
                Toggle("Intercept volume keys", isOn: $prefs.interceptVolume)
                Toggle("Sync with built-in display", isOn: $prefs.syncWithBuiltIn)
                    .help("When on, brightness/volume keys also adjust the built-in display and Mac speakers alongside external displays.")
            }

            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Toggle("Hide menu bar icon", isOn: $prefs.hideMenuBarIcon)
                    .help("Glint disappears completely. To access settings again, open Glint from Applications.")
            }

            Section("Accessibility") {
                HStack {
                    Circle()
                        .fill(interceptor.isActive ? .green : .orange)
                        .frame(width: 8, height: 8)
                    if interceptor.isActive {
                        Text("Accessibility access granted")
                    } else {
                        VStack(alignment: .leading) {
                            Text("Accessibility access required")
                                .foregroundStyle(.orange)
                            Text("Open System Settings > Privacy & Security > Accessibility and add Glint. You will need to quit and relaunch Glint after enabling access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !interceptor.isActive {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Glint")
                        .font(.headline)
                    Spacer()
                    Text("v1.0.0")
                        .foregroundStyle(.secondary)
                }
                Text("DDC display control from your keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Open source — MIT License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Section {
                Button("Quit Glint") {
                    NSApplication.shared.terminate(nil)
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 420)
    }
}

// MARK: - Settings Window Controller

final class SettingsWindowController: @unchecked Sendable {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    @MainActor func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Glint Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
