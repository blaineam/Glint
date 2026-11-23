//! Which key events Glint acts on. Linux reports brightness and volume keys as evdev key
//! codes on every desktop (X11, Wayland, SteamOS Game Mode, console), so Glint reads input
//! devices directly. This module is the pure decision: given a key event and the modifier
//! state, what to do and whether to keep it from reaching the desktop.

use glint_core::logic::{Direction, HotkeyScheme};

// linux/input-event-codes.h
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_LEFTALT: u16 = 56;
pub const KEY_F1: u16 = 59;
pub const KEY_F2: u16 = 60;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_RIGHTALT: u16 = 100;
pub const KEY_PAGEUP: u16 = 104;
pub const KEY_PAGEDOWN: u16 = 109;
pub const KEY_MUTE: u16 = 113;
pub const KEY_VOLUMEDOWN: u16 = 114;
pub const KEY_VOLUMEUP: u16 = 115;
pub const KEY_F14: u16 = 184;
pub const KEY_F15: u16 = 185;
pub const KEY_BRIGHTNESSDOWN: u16 = 224;
pub const KEY_BRIGHTNESSUP: u16 = 225;

/// Keys whose presence makes a device worth listening to.
pub const INTERESTING: [u16; 5] = [KEY_BRIGHTNESSDOWN, KEY_BRIGHTNESSUP, KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_MUTE];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Brightness(Direction),
    Volume(Direction),
    Mute,
}

/// Held modifiers, tracked from the same device's events.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
}

impl Mods {
    /// Updates the state for a modifier key event (value 0 = up, 1 = down, 2 = repeat).
    pub fn update(&mut self, code: u16, value: i32) {
        let down = value != 0;
        match code {
            KEY_LEFTCTRL | KEY_RIGHTCTRL => self.ctrl = down,
            KEY_LEFTALT | KEY_RIGHTALT => self.alt = down,
            _ => {}
        }
    }
}

/// What the user's settings let Glint take right now.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub intercept_brightness: bool,
    pub hotkeys: HotkeyScheme,
    /// Volume keys go to Glint (see `logic::route_volume_keys`); otherwise to the desktop.
    pub route_volume: bool,
}

/// What to do with one key event: an action to run (on press and auto-repeat), and whether
/// the event (press, repeat and release alike) is kept from the desktop.
pub fn classify(code: u16, value: i32, mods: Mods, p: Policy) -> (Option<Action>, bool) {
    let pressed = value == 1 || value == 2;
    let action = match code {
        KEY_BRIGHTNESSUP if p.intercept_brightness => Some(Action::Brightness(Direction::Up)),
        KEY_BRIGHTNESSDOWN if p.intercept_brightness => Some(Action::Brightness(Direction::Down)),
        KEY_VOLUMEUP if p.route_volume => Some(Action::Volume(Direction::Up)),
        KEY_VOLUMEDOWN if p.route_volume => Some(Action::Volume(Direction::Down)),
        KEY_MUTE if p.route_volume => Some(Action::Mute),
        _ if p.intercept_brightness => hotkey(code, mods, p.hotkeys).map(Action::Brightness),
        _ => None,
    };
    match action {
        // Mute doesn't repeat: one toggle per press.
        Some(Action::Mute) => (if value == 1 { Some(Action::Mute) } else { None }, true),
        Some(a) => (if pressed { Some(a) } else { None }, true),
        None => (None, false),
    }
}

fn hotkey(code: u16, mods: Mods, scheme: HotkeyScheme) -> Option<Direction> {
    let ctrl_alt = mods.ctrl && mods.alt;
    let (down, up, needs_ctrl_alt) = match scheme {
        HotkeyScheme::CtrlAltPage => (KEY_PAGEDOWN, KEY_PAGEUP, true),
        HotkeyScheme::CtrlAltF1F2 => (KEY_F1, KEY_F2, true),
        HotkeyScheme::F1F2 => (KEY_F1, KEY_F2, false),
        HotkeyScheme::F14F15 => (KEY_F14, KEY_F15, false),
        HotkeyScheme::Off => return None,
    };
    if needs_ctrl_alt != ctrl_alt {
        return None;
    }
    if code == down {
        Some(Direction::Down)
    } else if code == up {
        Some(Direction::Up)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: Policy = Policy { intercept_brightness: true, hotkeys: HotkeyScheme::CtrlAltPage, route_volume: true };

    #[test]
    fn brightness_keys_repeat_and_swallow() {
        let m = Mods::default();
        assert_eq!(classify(KEY_BRIGHTNESSUP, 1, m, ALL), (Some(Action::Brightness(Direction::Up)), true));
        assert_eq!(classify(KEY_BRIGHTNESSUP, 2, m, ALL), (Some(Action::Brightness(Direction::Up)), true));
        assert_eq!(classify(KEY_BRIGHTNESSUP, 0, m, ALL), (None, true));
        let off = Policy { intercept_brightness: false, ..ALL };
        assert_eq!(classify(KEY_BRIGHTNESSDOWN, 1, m, off), (None, false));
    }

    #[test]
    fn volume_keys_follow_routing() {
        let m = Mods::default();
        assert_eq!(classify(KEY_VOLUMEUP, 1, m, ALL), (Some(Action::Volume(Direction::Up)), true));
        let desktop = Policy { route_volume: false, ..ALL };
        assert_eq!(classify(KEY_VOLUMEUP, 1, m, desktop), (None, false));
        assert_eq!(classify(KEY_MUTE, 1, m, desktop), (None, false));
    }

    #[test]
    fn mute_toggles_once_per_press() {
        let m = Mods::default();
        assert_eq!(classify(KEY_MUTE, 1, m, ALL), (Some(Action::Mute), true));
        assert_eq!(classify(KEY_MUTE, 2, m, ALL), (None, true));
        assert_eq!(classify(KEY_MUTE, 0, m, ALL), (None, true));
    }

    #[test]
    fn hotkeys_need_their_modifiers() {
        let mut m = Mods::default();
        assert_eq!(classify(KEY_PAGEUP, 1, m, ALL), (None, false));
        m.update(KEY_LEFTCTRL, 1);
        m.update(KEY_RIGHTALT, 1);
        assert_eq!(classify(KEY_PAGEUP, 1, m, ALL), (Some(Action::Brightness(Direction::Up)), true));
        assert_eq!(classify(KEY_PAGEDOWN, 1, m, ALL), (Some(Action::Brightness(Direction::Down)), true));
        m.update(KEY_LEFTCTRL, 0);
        assert_eq!(classify(KEY_PAGEUP, 1, m, ALL), (None, false));
        // Plain F1/F2 must not fire while Ctrl+Alt is held (that's a VT switch).
        let f = Policy { hotkeys: HotkeyScheme::F1F2, ..ALL };
        assert_eq!(classify(KEY_F2, 1, Mods::default(), f), (Some(Action::Brightness(Direction::Up)), true));
        assert_eq!(classify(KEY_F2, 1, Mods { ctrl: true, alt: true }, f), (None, false));
        let off = Policy { hotkeys: HotkeyScheme::Off, ..ALL };
        assert_eq!(classify(KEY_F1, 1, Mods::default(), off), (None, false));
    }
}
