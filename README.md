# Glint

DDC display control from your keyboard.

Glint intercepts your Mac's brightness and volume media keys and sends DDC/CI commands to connected external displays — so you can adjust your monitor's actual brightness and speaker volume directly from the keyboard.

## Features

- **Brightness keys** — Controls your external display's backlight via DDC, not software gamma
- **Volume keys** — Adjusts your monitor's built-in speakers via DDC
- **Mute key** — Toggles monitor speaker mute
- **Native OSD** — Shows a volume/brightness overlay just like macOS
- **Menu bar app** — Lives in the menu bar with sliders for manual control
- **Launch at login** — Starts silently and stays out of the way
- **No dock icon** — Fully invisible, always ready

## Requirements

- macOS 13.0+
- External display with DDC/CI support (most monitors support this)
- Accessibility permission (for intercepting media keys)

## Installation

Download the latest notarized DMG from [Releases](../../releases), or build from source:

```bash
# Generate Xcode project
brew install xcodegen
xcodegen generate

# Build
xcodebuild -scheme Glint -configuration Release build
```

## Notarization (for distribution)

1. Set up credentials once:
   ```bash
   xcrun notarytool store-credentials "Glint"
   ```
2. Run the notarization script:
   ```bash
   ./Scripts/notarize.sh
   ```

## How it works

Glint uses a `CGEventTap` to intercept system media key events before macOS processes them. When a brightness or volume key is pressed, Glint sends DDC/CI commands over the I2C bus (via IOKit's `IOI2CInterface`) to the connected display, adjusting its hardware brightness or volume directly.

This requires running outside the Mac App Store sandbox, since IOKit I2C access is not available to sandboxed apps.

## License

MIT License — see [LICENSE](LICENSE).
