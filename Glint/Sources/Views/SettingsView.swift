import SwiftUI

import MillerKit
struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var interceptor = MediaKeyInterceptor.shared

    var body: some View {
        Form {
            Section("Keyboard Controls") {
                Toggle("Intercept brightness keys", isOn: $prefs.interceptBrightness)
                    .accessibilityIdentifier("glint.settings.interceptBrightness")
                if prefs.interceptBrightness {
                    Toggle("Always intercept brightness", isOn: $prefs.alwaysInterceptBrightness)
                        .accessibilityIdentifier("glint.settings.alwaysInterceptBrightness")
                        .help("Intercept brightness keys even when DDC brightness control wasn't detected. Useful if your monitor responds to DDC writes but not reads.")
                        .padding(.leading, 16)
                }
                Toggle("Intercept volume keys", isOn: $prefs.interceptVolume)
                    .accessibilityIdentifier("glint.settings.interceptVolume")
                if prefs.interceptVolume {
                    Toggle("Always intercept volume", isOn: $prefs.alwaysInterceptVolume)
                        .accessibilityIdentifier("glint.settings.alwaysInterceptVolume")
                        .help("Intercept volume keys even when DDC volume control wasn't detected. Useful if your monitor responds to DDC writes but not reads.")
                        .padding(.leading, 16)
                    Toggle("Write-only volume", isOn: $prefs.writeOnlyVolume)
                        .accessibilityIdentifier("glint.settings.writeOnlyVolume")
                        .help("Skip DDC volume reads and start at 50%. Volume is tracked in memory and sent via DDC writes only. Enable this if your monitor ignores DDC volume reads but responds to writes.")
                        .padding(.leading, 16)
                }
                Picker("Brightness step", selection: $prefs.brightnessStep) {
                    ForEach(Preferences.stepOptions, id: \.self) { step in
                        Text(step / 100, format: .percent).tag(step)
                    }
                }
                .help("How much each brightness key press changes brightness.")
                .accessibilityIdentifier("glint.settings.brightnessStep")
                Picker("Volume step", selection: $prefs.volumeStep) {
                    ForEach(Preferences.stepOptions, id: \.self) { step in
                        Text(step / 100, format: .percent).tag(step)
                    }
                }
                .help("How much each volume key press changes volume.")
                .accessibilityIdentifier("glint.settings.volumeStep")
                Toggle("Sync with built-in display", isOn: $prefs.syncWithBuiltIn)
                    .accessibilityIdentifier("glint.settings.syncWithBuiltIn")
                    .help("When on, brightness/volume keys also adjust the built-in display and Mac speakers alongside external displays.")
            }

            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .accessibilityIdentifier("glint.settings.launchAtLogin")
                Toggle("Hide menu bar icon", isOn: $prefs.hideMenuBarIcon)
                    .accessibilityIdentifier("glint.settings.hideMenuBarIcon")
                    .help("Glint disappears completely. To access settings again, open Glint from Applications.")
            }

            Section("Accessibility") {
                HStack {
                    Circle()
                        .fill(interceptor.isActive ? .green : .orange)
                        .frame(width: 8, height: 8)
                    if interceptor.isActive {
                        Text("Accessibility access granted")
                            .accessibilityIdentifier("glint.settings.accessibilityStatus")
                    } else {
                        VStack(alignment: .leading) {
                            Text("Accessibility access required")
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("glint.settings.accessibilityStatus")
                            Text("Open System Settings > Privacy & Security > Accessibility and add Glint. You will need to quit and relaunch Glint after enabling access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !interceptor.isActive {
                        Button("Open Settings") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            #if DEBUG
                            UITestMode.open(url)
                            #else
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                        .accessibilityIdentifier("glint.settings.openAccessibilitySettings")
                    }
                }
            }

            Section("Diagnostics") {
                Toggle("Debug logging", isOn: $prefs.debugLogging)
                    .accessibilityIdentifier("glint.settings.debugLogging")
                    .help("Writes detailed DDC and audio routing info to a log file for troubleshooting.")
                if prefs.debugLogging {
                    HStack {
                        Text("Logs DDC commands, audio detection, and display info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Log File") {
                            DebugLogger.shared.revealInFinder()
                        }
                        .accessibilityIdentifier("glint.settings.showLogFile")
                    }
                }
            }

            Section("About") {
                Text("Glint")
                    .font(.headline)
                    .accessibilityIdentifier("glint.settings.aboutTitle")
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
                .accessibilityIdentifier("glint.settings.quit")
            }

            // Support is already fully usable inline via SupportSection above —
            // no second "open in its own window" control (menu bar still has
            // Support… → SupportWindowController for a detachable window).
            SupportSection(app: .glint)
            LoveThisAppSection(app: .glint)
            // The version had been a raw `Bundle.main` Info.plist read that fell
            // back to "?", and there was no privacy row. AboutSection owns both.
            AboutSection(app: .glint)
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
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
        #if DEBUG
        let hostingController = NSHostingController(rootView: UITestMode.host(settingsView))
        #else
        let hostingController = NSHostingController(rootView: settingsView)
        #endif

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Glint Settings", comment: "Title of the settings window")
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
