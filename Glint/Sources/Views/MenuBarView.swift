import SwiftUI

/// What the popover's buttons do. The app uses `.live`; tests inject recorders so a click
/// never opens a real window or quits the test host.
struct MenuBarActions {
    var showSettings: @MainActor () -> Void
    var showSupport: @MainActor () -> Void
    var refresh: () -> Void
    var quit: @MainActor () -> Void

    static func live(displayManager: DisplayManager) -> MenuBarActions {
        MenuBarActions(
            showSettings: {
                SettingsWindowController.shared.show()
                // Close the popover by sending escape key
                NSApp.deactivate()
            },
            // Opens the dedicated support window — a real window, never a
            // sheet: a sheet would attach to this transient popover and be
            // torn down with it.
            showSupport: {
                SupportWindowController.shared.show()
                NSApp.deactivate()
            },
            refresh: { displayManager.refresh() },
            quit: { NSApp.terminate(nil) }
        )
    }
}

struct MenuBarView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var interceptor: MediaKeyInterceptor
    @ObservedObject var prefs: Preferences
    let actions: MenuBarActions

    /// The app uses the shared instances; tests inject fakes.
    init(
        displayManager: DisplayManager = .shared,
        interceptor: MediaKeyInterceptor = .shared,
        prefs: Preferences = .shared,
        actions: MenuBarActions? = nil
    ) {
        self.displayManager = displayManager
        self.interceptor = interceptor
        self.prefs = prefs
        self.actions = actions ?? MenuBarActions.live(displayManager: displayManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displayManager.displays.isEmpty {
                noDisplaysView
            } else {
                displaysView
            }

            Divider()
                .padding(.vertical, 4)

            statusRow

            Divider()
                .padding(.vertical, 4)

            bottomButtons
        }
        .padding(8)
        .frame(width: 280)
    }

    // MARK: - No Displays

    private var noDisplaysView: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No external displays detected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("glint.menu.empty")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Displays

    private var displaysView: some View {
        ForEach(displayManager.displays) { display in
            DisplayControlView(display: display, displayManager: displayManager, prefs: prefs)
            if display.id != displayManager.displays.last?.id {
                Divider().padding(.vertical, 4)
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(interceptor.isActive ? .green : .red)
                .frame(width: 7, height: 7)
            Text(interceptor.isActive ? "Intercepting keys" : "Not active")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("glint.menu.status")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bottom

    private var bottomButtons: some View {
        HStack {
            Button("Settings...") {
                actions.showSettings()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityIdentifier("glint.menu.settings")

            Spacer()

            Button("Support...") {
                actions.showSupport()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityIdentifier("glint.menu.support")

            Spacer()

            Button("Refresh") {
                actions.refresh()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityIdentifier("glint.menu.refresh")

            Spacer()

            Button("Quit") {
                actions.quit()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityIdentifier("glint.menu.quit")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Per-Display Controls

struct DisplayControlView: View {
    let display: ExternalDisplay
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var prefs: Preferences

    init(display: ExternalDisplay, displayManager: DisplayManager = .shared, prefs: Preferences = .shared) {
        self.display = display
        self.displayManager = displayManager
        self.prefs = prefs
    }

    /// The brightness slider moved to `value` (raw DDC units): in sync mode every display
    /// follows, otherwise only this one.
    func brightnessSliderChanged(to value: Double) {
        guard let maxBrightness = display.maxBrightness, maxBrightness > 0 else { return }
        let percent = Int(value / Double(maxBrightness) * 100)
        if prefs.syncWithBuiltIn {
            displayManager.setBrightnessForAll(percent)
        } else {
            displayManager.setBrightness(percent, for: display.id)
        }
    }

    /// The volume slider moved to `value` (raw DDC units).
    func volumeSliderChanged(to value: Double) {
        guard let maxVolume = display.maxVolume, maxVolume > 0 else { return }
        displayManager.setVolume(Int(value / Double(maxVolume) * 100), for: display.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(display.name)
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("glint.display.\(display.id).name")

            // Brightness
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                if let brightness = display.brightness, let maxBrightness = display.maxBrightness {
                    Slider(
                        value: Binding(
                            get: { Double(brightness) },
                            set: { brightnessSliderChanged(to: $0) }
                        ),
                        in: 0...Double(maxBrightness)
                    )
                    .accessibilityIdentifier("glint.display.\(display.id).brightnessSlider")
                    Text("\(display.brightnessPercent)%")
                        .font(.caption)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("glint.display.\(display.id).brightnessValue")
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("glint.display.\(display.id).brightnessNA")
                    Spacer()
                }
            }

            // Volume
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                if let volume = display.volume, let maxVolume = display.maxVolume {
                    Slider(
                        value: Binding(
                            get: { Double(volume) },
                            set: { volumeSliderChanged(to: $0) }
                        ),
                        in: 0...Double(maxVolume)
                    )
                    .accessibilityIdentifier("glint.display.\(display.id).volumeSlider")
                    Text("\(display.volumePercent)%")
                        .font(.caption)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("glint.display.\(display.id).volumeValue")
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("glint.display.\(display.id).volumeNA")
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}
