import AppKit
import SwiftUI

/// A macOS-native OSD overlay (like Apple's brightness/volume HUD).
@MainActor
final class OSDOverlay {
    static let shared = OSDOverlay()

    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(icon: String, value: Int) {
        hideTask?.cancel()

        let hostingView = NSHostingView(rootView: OSDView(icon: icon, value: value))
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 200)

        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window = panel
        }

        window?.contentView = hostingView

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.midX - 100
            let y = screenFrame.minY + screenFrame.height * 0.18
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.orderFrontRegardless()

        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.window?.orderOut(nil)
        }
    }
}

// MARK: - OSD SwiftUI View

private struct OSDView: View {
    let icon: String
    let value: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)

            // Bar indicator
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.2))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: geo.size.width * CGFloat(value) / 100)
                }
            }
            .frame(width: 140, height: 6)
        }
        .padding(30)
        .frame(width: 200, height: 200)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}
