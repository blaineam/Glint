import SwiftUI

struct MenuBarView: View {
    @ObservedObject var displayManager = DisplayManager.shared
    @ObservedObject var interceptor = MediaKeyInterceptor.shared
    @ObservedObject var prefs = Preferences.shared

    @State private var showingSettings = false

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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Displays

    private var displaysView: some View {
        ForEach(displayManager.displays) { display in
            DisplayControlView(display: display)
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
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bottom

    private var bottomButtons: some View {
        HStack {
            Button("Settings...") {
                SettingsWindowController.shared.show()
                // Close the popover by sending escape key
                NSApp.deactivate()
            }
            .buttonStyle(.plain)
            .font(.caption)

            Spacer()

            Button("Refresh") {
                displayManager.refresh()
            }
            .buttonStyle(.plain)
            .font(.caption)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Per-Display Controls

struct DisplayControlView: View {
    let display: ExternalDisplay
    @ObservedObject var displayManager = DisplayManager.shared
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(display.name)
                .font(.headline)
                .lineLimit(1)

            // Brightness
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                if let brightness = display.brightness, let maxBrightness = display.maxBrightness {
                    Slider(
                        value: Binding(
                            get: { Double(brightness) },
                            set: { val in
                                let percent = Int(val / Double(maxBrightness) * 100)
                                if prefs.syncWithBuiltIn {
                                    displayManager.setBrightnessForAll(percent)
                                } else {
                                    displayManager.setBrightness(percent, for: display.id)
                                }
                            }
                        ),
                        in: 0...Double(maxBrightness)
                    )
                    Text("\(display.brightnessPercent)%")
                        .font(.caption)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            set: { val in
                                let percent = Int(val / Double(maxVolume) * 100)
                                displayManager.setVolume(percent, for: display.id)
                            }
                        ),
                        in: 0...Double(maxVolume)
                    )
                    Text("\(display.volumePercent)%")
                        .font(.caption)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}
