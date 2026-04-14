# Changelog

## v1.3.6

- **Exponential backoff DDC reads**: Failed reads now retry up to 3 times with exponential backoff (100ms, 200ms, 400ms), fixing volume reads that fail after brightness reads on rate-limited LG monitors
- **Default max volume/brightness to 100**: If a monitor reports a current value but a zero or missing max, Glint defaults max to 100 instead of showing broken sliders
- **Smart key interception**: Brightness and volume keys are only intercepted when DDC successfully detected that capability on startup. If DDC volume reads fail, volume keys pass through to macOS as normal
- **Always intercept override**: New per-control "Always intercept" toggles in Settings for monitors that respond to DDC writes but not reads

## v1.3.5

- **Serial DDC queue**: All I2C operations (reads and writes) now go through a serial `DispatchQueue`, preventing concurrent bus access that caused LG monitors to drop commands. Every operation enforces a 100ms cooldown before hitting the bus
- **Startup reliability**: DDC retry loop no longer re-reads values that already succeeded — if brightness reads OK on the first attempt, only volume is retried. Retry delay increased from 100ms to 500ms to give LG monitors more recovery time
- **TTL read cache**: 2-second read cache avoids hammering DDC reads on rapid key presses. Cache is updated after every successful write so subsequent adjustments stay accurate without extra reads

## v1.3.4

- **TTL read cache for DDC**: Adds a 2-second read cache to avoid hammering DDC reads on rate-limited monitors (e.g., LG). Rapid key presses reuse the cached value and write immediately; on cache miss a real DDC read is performed with an I2C settling delay before writing. Cache is updated after every successful write so subsequent adjustments stay accurate without extra reads
- **Volume adjust uses ddc.write**: Volume adjustment now uses direct `ddc.write` calls with cached reads instead of raw `ddc.read` per keystroke, fixing volume control failures on monitors that rate-limit DDC commands

## v1.3.3

- **Fix volume adjustment**: Use `ddc.read` then `ddc.write` for volume changes instead of `ddc.adjust` which added an unnecessary 50ms delay between read and write

## v1.3.2

- **DDC read retries on startup**: Initial display refresh now retries DDC reads up to 3 times with 100ms delays — fixes "N/A" sliders on monitors that need time to respond after connection
- **I2C bus settling delay**: Added 50ms delay between DDC read and write in adjust commands — fixes monitors (e.g., some LG displays) that drop writes arriving too quickly after a read
- **Adjust returns max value**: DDC adjust now updates both current and max values in the display state, ensuring sliders and OSD always have correct ranges

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
