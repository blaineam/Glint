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

    /// Where the pill sits: horizontally centred on the screen, 8 pt below the menu bar
    /// (or notch), whose height is the gap between the screen top and the visible frame.
    nonisolated static func pillOrigin(screenFrame: NSRect, visibleFrame: NSRect, pillSize: NSSize) -> NSPoint {
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        let topInset = menuBarHeight + 8
        let x = screenFrame.midX - pillSize.width / 2
        let y = screenFrame.maxY - topInset - pillSize.height
        return NSPoint(x: x, y: y)
    }

    func show(icon: String, value: Int, on screen: NSScreen? = nil) {
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

        // Position below notch/menu bar on the target screen
        let targetScreen = screen ?? NSScreen.main
        if let screen = targetScreen {
            window?.setFrameOrigin(Self.pillOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                pillSize: NSSize(width: pillWidth, height: pillHeight)
            ))
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
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.window?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.window?.orderOut(nil)
                    self?.isVisible = false
                }
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
