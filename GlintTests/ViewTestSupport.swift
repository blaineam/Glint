import AppKit
import SwiftUI
import XCTest
@testable import Glint

// MARK: - Off-screen hosting

/// A SwiftUI view hosted in a borderless window that is parked far outside every screen and
/// never ordered front, so a test renders real views without anything appearing for the
/// owner (and without activating the app).
@MainActor
final class OffscreenHost<V: View> {
    let hostingView: NSHostingView<V>
    let window: NSWindow

    init(_ view: V, size: NSSize = NSSize(width: 360, height: 640)) {
        hostingView = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
        render()
    }

    /// Runs layout and a draw pass so SwiftUI evaluates `body` and every modifier closure.
    func render() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }
    }

    /// Re-renders with a new root view (state changed upstream).
    func update(_ view: V) {
        hostingView.rootView = view
        render()
    }

    /// Every AppKit view under the hosting view, depth first.
    var allSubviews: [NSView] {
        var result: [NSView] = []
        func walk(_ view: NSView) {
            for sub in view.subviews { result.append(sub); walk(sub) }
        }
        walk(hostingView)
        return result
    }

    /// SwiftUI `Toggle`s in a grouped Form are hosted as AppKit switches, so counting them
    /// shows which rows a Form currently contains.
    var switchCount: Int {
        allSubviews.filter { String(describing: type(of: $0)).hasPrefix("PlatformSwitch") }.count
    }
}

// MARK: - Fake event tap

/// A plain Mach port standing in for a CGEventTap, so MediaKeyInterceptor.start() can be
/// exercised without ever installing a real keyboard tap.
func makeFakeTapPort() -> CFMachPort {
    CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
}

/// A `MediaKeyInterceptor` with no real tap and no real OSD.
@MainActor
func makeFakeInterceptor(
    preferences: Preferences,
    displayManager: DisplayManager,
    presentOSD: @escaping MediaKeyInterceptor.OSDPresenter = { _, _, _ in }
) -> MediaKeyInterceptor {
    MediaKeyInterceptor(
        preferences: { preferences },
        displayManager: { displayManager },
        tapFactory: { _, _ in makeFakeTapPort() },
        tapSwitch: { _, _ in },
        presentOSD: presentOSD
    )
}

/// A DisplayManager over the fakes, refreshed once.
func makeFakeDisplayManager(
    preferences: Preferences,
    transport: FakeDDCTransport,
    audio: FakeSystemAudio,
    environment: FakeDisplayEnvironment
) -> DisplayManager {
    let manager = DisplayManager(preferences: preferences, ddc: makeDDC(transport), audio: audio, environment: environment)
    manager.refresh()
    return manager
}
