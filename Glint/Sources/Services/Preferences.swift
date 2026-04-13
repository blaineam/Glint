import Foundation
import ServiceManagement

final class Preferences: ObservableObject, @unchecked Sendable {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    @Published var interceptBrightness: Bool {
        didSet { defaults.set(interceptBrightness, forKey: "interceptBrightness") }
    }

    @Published var interceptVolume: Bool {
        didSet { defaults.set(interceptVolume, forKey: "interceptVolume") }
    }

    @Published var brightnessStep: Int {
        didSet { defaults.set(brightnessStep, forKey: "brightnessStep") }
    }

    @Published var volumeStep: Int {
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

    @Published var debugLogging: Bool {
        didSet { defaults.set(debugLogging, forKey: "debugLogging") }
    }

    private init() {
        // Register defaults
        defaults.register(defaults: [
            "launchAtLogin": false,
            "interceptBrightness": true,
            "interceptVolume": true,
            "brightnessStep": 6,
            "volumeStep": 6,
            "syncWithBuiltIn": true,
            "hideMenuBarIcon": false,
            "debugLogging": false,
        ])

        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        interceptBrightness = defaults.bool(forKey: "interceptBrightness")
        interceptVolume = defaults.bool(forKey: "interceptVolume")
        brightnessStep = defaults.integer(forKey: "brightnessStep")
        volumeStep = defaults.integer(forKey: "volumeStep")
        syncWithBuiltIn = defaults.bool(forKey: "syncWithBuiltIn")
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        debugLogging = defaults.bool(forKey: "debugLogging")
    }

    private func updateLoginItem() {
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
