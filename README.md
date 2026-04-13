# ✨ Glint

**DDC display control from your keyboard. Tiny, invisible, always ready.**

<p align="center">
  <img src="docs/assets/hero.png" alt="Glint — control your external display with keyboard shortcuts" width="600">
</p>

Glint intercepts your Mac's brightness and volume media keys and sends [DDC/CI](https://en.wikipedia.org/wiki/Display_Data_Channel) commands to your external monitor — so the keys that normally only control your MacBook screen now also control your monitor's **actual hardware brightness** and **built-in speakers**.

> 🪶 **Under 2 MB.** No Electron. No frameworks. Pure Swift + IOKit.
> Zero CPU when idle. Disappears completely if you want it to.

---

## 🎯 Why Glint Exists

If you've ever plugged an external monitor into your Mac, you know the pain:

- **Brightness keys?** Only control the MacBook screen.
- **Volume keys?** Only control the Mac speakers — not the monitor's.
- **The fix?** Reach for clunky OSD buttons on the back of your monitor. Every. Single. Time.

Glint makes your keyboard Just Work™ with external displays.

---

## ⚡ Features

| Feature | Details |
|---------|---------|
| 🔆 **Brightness keys** | Controls your external display's backlight via DDC — not software gamma |
| 🔊 **Volume keys** | Adjusts your monitor's built-in speakers via DDC |
| 🔇 **Mute key** | Toggles monitor speaker mute |
| 🔄 **Sync mode** | First keypress syncs external display to match your Mac's current brightness/volume, then adjusts both in lockstep |
| 🖥️ **Native OSD** | Shows a brightness/volume overlay just like macOS |
| 👻 **Invisible mode** | Hide from menu bar AND dock — completely invisible, always listening |
| 🚀 **Launch at login** | Starts silently, ready before you are |
| 🪶 **Tiny footprint** | < 2 MB, zero dependencies, negligible CPU/memory |
| 🆓 **Free & open source** | MIT License. No telemetry. No accounts. No nonsense. |

---

## 📦 Install

### Download (recommended)

Grab the latest **notarized DMG** from [Releases](../../releases) — drag to Applications, done.

### Build from source

```bash
# Install xcodegen if you don't have it
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -scheme Glint -configuration Release build
```

---

## 🛠️ Setup

1. **Open Glint** — it appears in your menu bar as a ☀️ icon
2. **Grant Accessibility access** when prompted (System Settings → Privacy & Security → Accessibility)
3. **Press your brightness/volume keys** — they now control your external display!

### Going invisible

Toggle **"Hide menu bar icon"** in Settings. Glint vanishes from the menu bar and dock entirely. To access settings again, just open Glint from your Applications folder — it'll show the settings window.

---

## 🔧 How It Works

```
┌──────────────┐    CGEventTap     ┌──────────────┐    IOKit I2C     ┌──────────────┐
│   Keyboard   │ ───────────────▶  │    Glint     │ ──────────────▶ │   Monitor    │
│  Media Keys  │   intercept key   │  (< 2 MB)    │   DDC/CI cmd    │  Hardware    │
└──────────────┘                   └──────────────┘                 └──────────────┘
                                         │
                                         │ (sync mode)
                                         ▼
                                   Pass event through
                                   to macOS for built-in
                                   display/speakers too
```

1. **`CGEventTap`** intercepts system media key events before macOS processes them
2. **DDC/CI commands** are sent over the I2C bus (via IOKit's `IOI2CInterface`) to adjust hardware brightness/volume
3. **Sync mode** (on by default): the key event passes through to macOS so your MacBook screen and speakers also adjust — both displays stay in lockstep
4. **First-keystroke sync**: when sync is enabled, the first key press reads your Mac's current brightness/volume and sets the external display to match before adjusting

### Why not the Mac App Store?

DDC requires direct I2C communication through IOKit, which is blocked by the App Store sandbox. This is why **every** DDC app (BetterDisplay, MonitorControl, Lunar) distributes outside the App Store. Glint is notarized by Apple for security — it's just not sandboxed.

---

## 🏗️ Project Structure

```
Glint/
├── Sources/
│   ├── App/
│   │   ├── GlintApp.swift              # SwiftUI entry point, menu bar setup
│   │   └── Glint-Bridging-Header.h     # IOKit I2C headers
│   ├── Services/
│   │   ├── DDCService.swift            # IOKit I2C DDC/CI communication
│   │   ├── DisplayManager.swift        # Display enumeration, brightness/volume control
│   │   ├── MediaKeyInterceptor.swift   # CGEventTap media key interception
│   │   ├── OSDOverlay.swift            # Native overlay HUD
│   │   └── Preferences.swift           # UserDefaults + launch-at-login
│   └── Views/
│       ├── MenuBarView.swift           # Popover with per-display sliders
│       └── SettingsView.swift          # Settings window
├── Resources/
│   ├── Assets.xcassets/                # App icon, accent color
│   ├── Info.plist
│   └── Glint.entitlements
├── Scripts/
│   ├── generate-assets.swift           # Programmatic icon + DMG background generator
│   ├── build-dmg.sh                    # Full build → sign → notarize → DMG pipeline
│   └── notarize.sh                     # Standalone notarization script
├── docs/                               # GitHub Pages site
├── project.yml                         # XcodeGen project spec
├── LICENSE                             # MIT
└── README.md
```

---

## 🤝 Contributing

Contributions welcome! Here's how to get started:

1. **Fork & clone** the repo
2. **Install xcodegen**: `brew install xcodegen`
3. **Generate the project**: `xcodegen generate`
4. **Open** `Glint.xcodeproj` in Xcode
5. **Build & run** — you'll need an external monitor with DDC support to test

### Guidelines

- Keep it **tiny** — Glint's value is in its simplicity and small footprint
- No third-party dependencies — pure Swift + system frameworks
- Match the existing code style (no SwiftLint, just be consistent)
- Test with real hardware — DDC behavior varies across monitor brands
- Open an issue first for large changes so we can discuss the approach

### Reporting issues

If DDC doesn't work with your monitor, please include:
- Monitor make & model
- Connection type (HDMI, DisplayPort, USB-C)
- macOS version
- Whether other DDC apps (MonitorControl, BetterDisplay) work with your monitor

---

## 📋 FAQ

<details>
<summary><strong>Does Glint work with my monitor?</strong></summary>

Most external monitors support DDC/CI. If your monitor has an OSD (on-screen display) with brightness/volume controls, it almost certainly supports DDC. Known exceptions: some older Apple displays and a few budget monitors with DDC disabled by default (check your monitor's OSD settings).
</details>

<details>
<summary><strong>Does it work over HDMI? DisplayPort? USB-C?</strong></summary>

Yes to all three. DDC/CI works over HDMI, DisplayPort, and USB-C/Thunderbolt. Some USB-C hubs/docks may block DDC signals — if you have issues, try connecting directly.
</details>

<details>
<summary><strong>Why does Glint need Accessibility access?</strong></summary>

To intercept media key events (brightness, volume) before macOS processes them, Glint uses a `CGEventTap`, which requires Accessibility permission. Without it, Glint can't detect key presses.
</details>

<details>
<summary><strong>Is this safe? Why isn't it on the Mac App Store?</strong></summary>

Glint is open source (read every line!) and notarized by Apple (malware-scanned). It's not on the App Store because DDC requires IOKit I2C access, which the App Store sandbox blocks. This is the same reason BetterDisplay, MonitorControl, and Lunar are all distributed outside the store.
</details>

<details>
<summary><strong>How do I access settings after hiding the menu bar icon?</strong></summary>

Open Glint from your Applications folder (or Spotlight). When the app detects it's being re-opened, it shows the settings window automatically.
</details>

<details>
<summary><strong>Can I control multiple monitors?</strong></summary>

Yes! Glint detects all connected external displays and adjusts them simultaneously.
</details>

<details>
<summary><strong>Does it conflict with BetterDisplay / MonitorControl / Lunar?</strong></summary>

Possibly — if two apps both intercept the same media keys, they may interfere. We recommend using one DDC controller at a time.
</details>

<details>
<summary><strong>What's the CPU/memory usage?</strong></summary>

Effectively zero when idle. Glint uses a `CGEventTap` which is interrupt-driven — no polling, no timers, no background threads. Memory footprint is under 15 MB.
</details>

---

## 📄 License

MIT License — see [LICENSE](LICENSE).

Free as in beer. Free as in speech. 🍺

---

<p align="center">
  <sub>Built with ☀️ by <a href="https://github.com/blaineam">Blaine Miller</a></sub>
</p>
