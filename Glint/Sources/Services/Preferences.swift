import Foundation
import ServiceManagement

final class Preferences: ObservableObject, @unchecked Sendable {
    static let shared = Preferences()

    private let defaults: UserDefaults
    /// Registers/unregisters the login item. Injectable so tests never touch SMAppService.
    private let loginItem: (Bool) -> Void

    /// 1/16 per key press, matching macOS.
    static let defaultStep: Double = 6.25
    /// Step sizes (percent) offered in Settings.
    static let stepOptions: [Double] = [1, 2, 3, 4, 5, defaultStep, 8, 10]

    /// Converts a stored step percent to a 0–1 fraction, clamped to 1–10%.
    static func stepFraction(_ percent: Double) -> Double {
        guard percent.isFinite, percent > 0 else { return defaultStep / 100 }
        return min(max(percent, 1), 10) / 100
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            loginItem(launchAtLogin)
        }
    }

    @Published var interceptBrightness: Bool {
        didSet { defaults.set(interceptBrightness, forKey: "interceptBrightness") }
    }

    @Published var interceptVolume: Bool {
        didSet { defaults.set(interceptVolume, forKey: "interceptVolume") }
    }

    /// Percent changed per brightness key press.
    @Published var brightnessStep: Double {
        didSet { defaults.set(brightnessStep, forKey: "brightnessStep") }
    }

    /// Percent changed per volume key press.
    @Published var volumeStep: Double {
        didSet { defaults.set(volumeStep, forKey: "volumeStep") }
    }

    @Published var syncWithBuiltIn: Bool {
        didSet { defaults.set(syncWithBuiltIn, forKey: "syncWithBuiltIn") }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet {
            defaults.set(hideMenuBarIcon, forKey: "hideMenuBarIcon")
            NotificationCenter.default.post(name: .glintMenuBarVisibilityChanged, object: nil)
        }
    }

    @Published var alwaysInterceptBrightness: Bool {
        didSet { defaults.set(alwaysInterceptBrightness, forKey: "alwaysInterceptBrightness") }
    }

    @Published var alwaysInterceptVolume: Bool {
        didSet { defaults.set(alwaysInterceptVolume, forKey: "alwaysInterceptVolume") }
    }

    @Published var writeOnlyVolume: Bool {
        didSet { defaults.set(writeOnlyVolume, forKey: "writeOnlyVolume") }
    }

    @Published var debugLogging: Bool {
        didSet { defaults.set(debugLogging, forKey: "debugLogging") }
    }

    /// `defaults` is the store every preference reads and writes (`.standard` in the app;
    /// a throwaway suite in tests).
    init(defaults: UserDefaults = .standard, loginItem: @escaping (Bool) -> Void = Preferences.updateLoginItem) {
        self.defaults = defaults
        self.loginItem = loginItem
        // Register defaults
        defaults.register(defaults: [
            "launchAtLogin": false,
            "interceptBrightness": true,
            "interceptVolume": true,
            "alwaysInterceptBrightness": false,
            "alwaysInterceptVolume": false,
            "writeOnlyVolume": false,
            "brightnessStep": Preferences.defaultStep,
            "volumeStep": Preferences.defaultStep,
            "syncWithBuiltIn": true,
            "hideMenuBarIcon": false,
            "debugLogging": false,
        ])

        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        interceptBrightness = defaults.bool(forKey: "interceptBrightness")
        interceptVolume = defaults.bool(forKey: "interceptVolume")
        brightnessStep = defaults.double(forKey: "brightnessStep")
        volumeStep = defaults.double(forKey: "volumeStep")
        syncWithBuiltIn = defaults.bool(forKey: "syncWithBuiltIn")
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        alwaysInterceptBrightness = defaults.bool(forKey: "alwaysInterceptBrightness")
        alwaysInterceptVolume = defaults.bool(forKey: "alwaysInterceptVolume")
        writeOnlyVolume = defaults.bool(forKey: "writeOnlyVolume")
        debugLogging = defaults.bool(forKey: "debugLogging")
    }

    static func updateLoginItem(_ launchAtLogin: Bool) {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Glint] Login item error: \(error)")
        }
    }
}
