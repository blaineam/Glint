import AppKit
import SwiftUI

/// A subtle, non-disruptive OSD pill that appears below the notch area.
@MainActor
final class OSDOverlay {
    static let shared = OSDOverlay()

    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hostingView: NSHostingView<OSDPillView>?
    private var isVisible = false

    private let pillWidth: CGFloat = 200
    private let pillHeight: CGFloat = 28

    private init() {}

    func show(icon: String, value: Int) {
        hideTask?.cancel()

        // Update content without recreating the view
        if let hostingView = hostingView {
            hostingView.rootView = OSDPillView(icon: icon, value: value)
        } else {
            let view = NSHostingView(rootView: OSDPillView(icon: icon, value: value))
            view.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
            hostingView = view
        }

        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
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
            panel.contentView = hostingView
            window = panel
        }

        // Position below notch/menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
            let topInset = menuBarHeight + 8
            let x = screenFrame.midX - pillWidth / 2
            let y = screenFrame.maxY - topInset - pillHeight
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Only fade in if not already visible
        if !isVisible {
            window?.alphaValue = 0
            window?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window?.animator().alphaValue = 1
            }
            isVisible = true
        }

        // Reset hide timer
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.window?.animator().alphaValue = 0
            }, completionHandler: {
                self.window?.orderOut(nil)
                self.isVisible = false
            })
        }
    }
}

// MARK: - Pill View

struct OSDPillView: View {
    let icon: String
    let value: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))

                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(value) / 100))
                }
            }
            .frame(height: 4)

            Text("\(value)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 200, height: 28)
        .background(
            Capsule()
                .fill(.black.opacity(0.55))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .clipShape(Capsule())
        )
    }
}
