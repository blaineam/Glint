# Changelog

## v1.3.0

- **Debug logging**: Optional debug log that records DDC commands, audio routing decisions, display detection, and I2C results to `~/Library/Application Support/Glint/debug.log` — toggle in Settings with a button to reveal the log in Finder
- **Better audio/display name matching**: Partial word-level matching for audio device names against display names (e.g., "LG HDR" matches "LG HDR 4K (2)")

## v1.2.3

- **USB-C hub audio detection**: Volume keys now correctly use DDC for monitors connected through USB-C hubs/docks by matching the audio device name against connected display names

## v1.2.2

- **Fix About version**: Settings now reads version from the app bundle instead of a hardcoded string

## v1.2.1

- **Mute OSD**: Mute key now shows a muted speaker icon when muting and the volume level when unmuting
- **Accessibility restart notice**: Alert and settings view now inform users that Glint must be relaunched after enabling Accessibility access

## v1.2.0

- **Smart volume routing**: Volume keys now automatically use DDC when audio output is HDMI/DisplayPort, and system volume when using built-in speakers, headphones, USB, or Bluetooth — switches gracefully when you change output devices
- **Audio-aware mute**: Mute key targets the correct output based on the active audio device

## v1.1.0

- **Cursor-aware brightness**: When sync is off, brightness keys now only adjust the display the cursor is on
- **Proper display sync**: When sync is on, the first brightness key press forces all displays (built-in + externals) to match the cursor display's brightness before adjusting them together
- **Menu bar slider sync**: Dragging a brightness slider in the menu bar popover now propagates to all displays when sync is enabled
- **OSD on correct screen**: The brightness overlay now appears on the screen the cursor is on

## v1.0.0

- Initial release
- DDC/CI brightness and volume control for external displays via keyboard media keys
- Sync mode to keep built-in and external displays in lockstep
- Subtle pill-style OSD overlay
- Invisible mode (hide from menu bar and dock)
- Launch at login
- Menu bar popover with per-display brightness and volume sliders
