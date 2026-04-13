# Changelog

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
