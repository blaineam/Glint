//! Platform-independent logic: step math, settings model, name matching and mute
//! decisions. Kept free of Win32 so `cargo test` runs it on any host.

use crate::i18n::t;

/// Step sizes offered in the tray menu, in percent per key press. Same list as the Mac app.
pub const STEP_OPTIONS: [f64; 8] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.25, 8.0, 10.0];
/// 1/16, matching macOS and the Mac app's default.
pub const DEFAULT_STEP: f64 = 6.25;
/// Volume restored on unmute when the pre-mute volume is unknown (or was 0).
pub const FALLBACK_UNMUTE_PERCENT: f64 = 50.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
}

/// Converts a raw DDC value to a percentage of the monitor's maximum.
pub fn raw_to_percent(raw: u32, max: u32) -> f64 {
    if max == 0 {
        return 0.0;
    }
    (raw.min(max) as f64) * 100.0 / max as f64
}

/// Converts a percentage to the nearest raw DDC value.
pub fn percent_to_raw(percent: f64, max: u32) -> u32 {
    let p = percent.clamp(0.0, 100.0);
    ((p * max as f64) / 100.0).round() as u32
}

/// Applies `presses` steps of `step` percent to a raw value. The result always moves by at
/// least one raw unit unless it is already at the bound, so a 1% step on a monitor whose
/// range is 0–10 still does something.
pub fn step_raw(current: u32, max: u32, step: f64, dir: Direction, presses: u32) -> u32 {
    if max == 0 {
        return 0;
    }
    let current = current.min(max);
    let delta = step * presses.max(1) as f64;
    let pct = raw_to_percent(current, max);
    let target_pct = match dir {
        Direction::Up => pct + delta,
        Direction::Down => pct - delta,
    };
    let mut target = percent_to_raw(target_pct, max);
    if target == current {
        target = match dir {
            Direction::Up => (current + 1).min(max),
            Direction::Down => current.saturating_sub(1),
        };
    }
    target
}

/// Steps a percentage (used for sync mode, where displays have different raw ranges).
pub fn step_percent(current: f64, step: f64, dir: Direction, presses: u32) -> f64 {
    let delta = step * presses.max(1) as f64;
    match dir {
        Direction::Up => (current + delta).min(100.0),
        Direction::Down => (current - delta).max(0.0),
    }
}

/// Picks the nearest offered step for a stored value, so a corrupted or old setting still
/// lands on a menu item.
pub fn nearest_step(value: f64) -> f64 {
    STEP_OPTIONS
        .iter()
        .copied()
        .min_by(|a, b| (a - value).abs().total_cmp(&(b - value).abs()))
        .unwrap_or(DEFAULT_STEP)
}

/// Mute is one decision across every output Glint controls: if anything is audible,
/// everything is muted; otherwise everything is unmuted. (Mac v1.5.1 behaviour.)
pub fn should_mute(volumes: &[u32]) -> bool {
    volumes.iter().any(|&v| v > 0)
}

/// Raw volume to restore on unmute: the remembered pre-mute value, or 50% when unknown.
pub fn unmute_raw(remembered: Option<u32>, max: u32) -> u32 {
    match remembered {
        Some(v) if v > 0 => v.min(max),
        _ => percent_to_raw(FALLBACK_UNMUTE_PERCENT, max),
    }
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Whether an audio endpoint belongs to a monitor. HDMI/DisplayPort endpoints are named
/// after the monitor's EDID name, e.g. endpoint description "DELL U2720Q" or friendly name
/// "DELL U2720Q (NVIDIA High Definition Audio)" for monitor "DELL U2720Q".
pub fn endpoint_matches_monitor(endpoint_name: &str, monitor_name: &str) -> bool {
    let e = normalize(endpoint_name);
    let m = normalize(monitor_name);
    if e.len() < 3 || m.len() < 3 {
        return false;
    }
    e.contains(&m) || m.contains(&e)
}

/// Global hotkeys for brightness. Windows has no brightness virtual-key code: laptop Fn
/// keys are handled by firmware and desktop keyboards have none, so Glint uses hotkeys.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotkeyScheme {
    CtrlAltPage,
    CtrlAltF1F2,
    F1F2,
    F14F15,
    Off,
}

impl HotkeyScheme {
    pub const ALL: [HotkeyScheme; 5] = [
        HotkeyScheme::CtrlAltPage,
        HotkeyScheme::CtrlAltF1F2,
        HotkeyScheme::F1F2,
        HotkeyScheme::F14F15,
        HotkeyScheme::Off,
    ];

    pub fn label(self) -> String {
        match self {
            HotkeyScheme::CtrlAltPage => "Ctrl+Alt+Page Down / Page Up".into(),
            HotkeyScheme::CtrlAltF1F2 => "Ctrl+Alt+F1 / F2".into(),
            HotkeyScheme::F1F2 => format!("F1 / F2 {}", t("(Apple keyboard top row)")),
            HotkeyScheme::F14F15 => format!("F14 / F15 {}", t("(Apple keyboards)")),
            HotkeyScheme::Off => t("Off").into(),
        }
    }

    pub fn to_u32(self) -> u32 {
        match self {
            HotkeyScheme::CtrlAltPage => 0,
            HotkeyScheme::CtrlAltF1F2 => 1,
            HotkeyScheme::F14F15 => 2,
            HotkeyScheme::Off => 3,
            HotkeyScheme::F1F2 => 4,
        }
    }

    pub fn from_u32(v: u32) -> HotkeyScheme {
        match v {
            1 => HotkeyScheme::CtrlAltF1F2,
            2 => HotkeyScheme::F14F15,
            3 => HotkeyScheme::Off,
            4 => HotkeyScheme::F1F2,
            _ => HotkeyScheme::CtrlAltPage,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub brightness_step: f64,
    pub volume_step: f64,
    /// Mac "Sync with built-in display": brightness keys move every display (built-in
    /// included) to the cursor display's level, and volume keys move Windows' volume and
    /// every monitor's speakers together. On by default, as on the Mac.
    pub sync: bool,
    /// Brightness keys and hotkeys are handled at all (Mac "Intercept brightness keys").
    pub intercept_brightness: bool,
    /// Monitors that accept DDC brightness writes but don't answer reads are still
    /// controlled, from an assumed 50% (Mac "Always intercept brightness").
    pub always_brightness: bool,
    /// Volume keys drive the monitor's speakers over DDC when Windows plays through it
    /// (Mac "Intercept volume keys").
    pub route_volume: bool,
    /// Take volume keys whenever Windows plays through a monitor, even if no monitor
    /// answered DDC volume reads (Mac "Always intercept volume").
    pub always_volume: bool,
    /// Skip failed volume reads: start at 50% and track volume in memory (Mac "Write-only
    /// volume").
    pub write_only_volume: bool,
    pub debug_logging: bool,
    pub hotkeys: HotkeyScheme,
    pub show_osd: bool,
    pub tray_hidden: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            brightness_step: DEFAULT_STEP,
            volume_step: DEFAULT_STEP,
            sync: true,
            intercept_brightness: true,
            always_brightness: false,
            route_volume: true,
            always_volume: false,
            write_only_volume: false,
            debug_logging: false,
            hotkeys: HotkeyScheme::CtrlAltPage,
            show_osd: true,
            tray_hidden: false,
        }
    }
}

/// What the volume keys need to decide where they go.
#[derive(Clone, Copy, Debug, Default)]
pub struct RouteInput {
    pub intercept: bool,
    pub always: bool,
    pub sync: bool,
    /// Windows is playing through a monitor (HDMI/DisplayPort/USB-C).
    pub endpoint_is_display: bool,
    /// A monitor that answers DDC volume matches the playing device's name.
    pub matched_capable: bool,
    /// Any monitor matches the playing device's name.
    pub matched_any: bool,
    pub any_capable: bool,
}

/// Whether Glint takes the volume keys (true) or leaves them to Windows (false). Mirrors
/// the Mac: sync mode always takes them (Windows' volume and the monitors move together);
/// otherwise only when Windows plays through a monitor Glint can drive.
pub fn route_volume_keys(i: RouteInput) -> bool {
    if !i.intercept {
        return false;
    }
    if i.sync {
        return true;
    }
    if !i.endpoint_is_display {
        return false;
    }
    i.always || i.matched_capable || (!i.matched_any && i.any_capable)
}

/// Steps are stored as hundredths of a percent so 6.25 fits a registry DWORD exactly.
pub fn step_to_stored(step: f64) -> u32 {
    (step * 100.0).round() as u32
}

pub fn step_from_stored(v: u32) -> f64 {
    nearest_step(v as f64 / 100.0)
}

/// Stable per-monitor key for remembered values (pre-mute volume): the EDID name with
/// anything a registry value name dislikes removed.
pub fn monitor_key(name: &str, index_among_same_name: usize) -> String {
    let base: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    if index_among_same_name == 0 {
        base
    } else {
        format!("{base}#{index_among_same_name}")
    }
}

/// HID Consumer page (0x0C) usages for "Display Brightness Increment/Decrement". Keyboards
/// with brightness keys (Mac-layout keyboards from Logitech, Keychron and others, and Apple
/// keyboards with a driver) send these; Windows turns them into no key code at all.
pub const USAGE_BRIGHTNESS_UP: u16 = 0x6F;
pub const USAGE_BRIGHTNESS_DOWN: u16 = 0x70;

/// Which brightness key a consumer-control report holds down, if any.
pub fn brightness_key(usages: &[u16]) -> Option<Direction> {
    if usages.contains(&USAGE_BRIGHTNESS_UP) {
        Some(Direction::Up)
    } else if usages.contains(&USAGE_BRIGHTNESS_DOWN) {
        Some(Direction::Down)
    } else {
        None
    }
}

/// Consumer keys report press and release but never auto-repeat, so Glint repeats a held
/// key itself. Returns the new held state and whether this report is a fresh press.
pub fn brightness_transition(held: Option<Direction>, usages: &[u16]) -> (Option<Direction>, bool) {
    let now = brightness_key(usages);
    (now, now.is_some() && now != held)
}

/// Whether a monitor applied a DDC write, judged by reading the value back. Off by one is
/// fine (some monitors round). No read-back at all proves nothing either way.
pub fn write_took(wanted: u32, read_back: Option<u32>) -> Option<bool> {
    read_back.map(|r| r.abs_diff(wanted) <= 1)
}

/// Text shown in the OSD for a percentage.
pub fn percent_label(p: f64) -> String {
    format!("{}%", p.round() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_round_trip() {
        assert_eq!(raw_to_percent(50, 100), 50.0);
        assert_eq!(percent_to_raw(50.0, 100), 50);
        assert_eq!(percent_to_raw(6.25, 100), 6);
        assert_eq!(percent_to_raw(150.0, 100), 100);
        assert_eq!(percent_to_raw(-3.0, 100), 0);
        assert_eq!(raw_to_percent(10, 0), 0.0);
        assert_eq!(raw_to_percent(200, 100), 100.0);
    }

    #[test]
    fn step_moves_and_clamps() {
        assert_eq!(step_raw(50, 100, 6.25, Direction::Up, 1), 56);
        assert_eq!(step_raw(50, 100, 6.25, Direction::Down, 1), 44);
        assert_eq!(step_raw(98, 100, 6.25, Direction::Up, 1), 100);
        assert_eq!(step_raw(3, 100, 6.25, Direction::Down, 1), 0);
        assert_eq!(step_raw(100, 100, 5.0, Direction::Up, 1), 100);
        assert_eq!(step_raw(0, 100, 5.0, Direction::Down, 1), 0);
    }

    #[test]
    fn step_coalesces_presses() {
        assert_eq!(step_raw(20, 100, 5.0, Direction::Up, 3), 35);
        assert_eq!(step_raw(20, 100, 5.0, Direction::Up, 0), 25);
    }

    #[test]
    fn step_always_moves_on_coarse_ranges() {
        // 1% of a 0–10 range rounds to no change; Glint still moves one unit.
        assert_eq!(step_raw(5, 10, 1.0, Direction::Up, 1), 6);
        assert_eq!(step_raw(5, 10, 1.0, Direction::Down, 1), 4);
        assert_eq!(step_raw(10, 10, 1.0, Direction::Up, 1), 10);
    }

    #[test]
    fn step_handles_zero_max() {
        assert_eq!(step_raw(0, 0, 5.0, Direction::Up, 1), 0);
    }

    #[test]
    fn step_percent_clamps() {
        assert_eq!(step_percent(97.0, 6.25, Direction::Up, 1), 100.0);
        assert_eq!(step_percent(3.0, 6.25, Direction::Down, 1), 0.0);
        assert_eq!(step_percent(50.0, 5.0, Direction::Down, 2), 40.0);
    }

    #[test]
    fn nearest_step_snaps() {
        assert_eq!(nearest_step(6.0), 6.25);
        assert_eq!(nearest_step(9.4), 10.0);
        assert_eq!(nearest_step(0.0), 1.0);
        assert_eq!(nearest_step(1000.0), 10.0);
        assert_eq!(step_from_stored(step_to_stored(6.25)), 6.25);
        assert_eq!(step_to_stored(6.25), 625);
    }

    #[test]
    fn mute_is_one_decision() {
        assert!(should_mute(&[0, 20]));
        assert!(!should_mute(&[0, 0]));
        assert!(!should_mute(&[]));
    }

    #[test]
    fn unmute_restores_remembered_or_half() {
        assert_eq!(unmute_raw(Some(20), 100), 20);
        assert_eq!(unmute_raw(Some(0), 100), 50);
        assert_eq!(unmute_raw(None, 100), 50);
        assert_eq!(unmute_raw(Some(200), 100), 100);
    }

    #[test]
    fn endpoint_matching() {
        assert!(endpoint_matches_monitor("DELL U2720Q", "DELL U2720Q"));
        assert!(endpoint_matches_monitor(
            "DELL U2720Q (NVIDIA High Definition Audio)",
            "DELL U2720Q"
        ));
        assert!(endpoint_matches_monitor("LG HDR 4K", "lg hdr-4k"));
        assert!(!endpoint_matches_monitor("Speakers (Realtek Audio)", "DELL U2720Q"));
        assert!(!endpoint_matches_monitor("", "DELL U2720Q"));
        assert!(!endpoint_matches_monitor("LG", "LG ULTRAFINE"));
    }

    #[test]
    fn brightness_keys_from_consumer_reports() {
        assert_eq!(brightness_key(&[0x6F]), Some(Direction::Up));
        assert_eq!(brightness_key(&[0x70]), Some(Direction::Down));
        assert_eq!(brightness_key(&[0xE9]), None); // volume up
        assert_eq!(brightness_key(&[]), None);
    }

    #[test]
    fn brightness_press_hold_release() {
        // Press fires once; the same report again (hold) does not; release clears.
        assert_eq!(brightness_transition(None, &[0x6F]), (Some(Direction::Up), true));
        assert_eq!(
            brightness_transition(Some(Direction::Up), &[0x6F]),
            (Some(Direction::Up), false)
        );
        assert_eq!(brightness_transition(Some(Direction::Up), &[]), (None, false));
        // Rolling from up to down is a new press.
        assert_eq!(
            brightness_transition(Some(Direction::Up), &[0x70]),
            (Some(Direction::Down), true)
        );
    }

    #[test]
    fn write_verification() {
        assert_eq!(write_took(50, Some(50)), Some(true));
        assert_eq!(write_took(50, Some(49)), Some(true));
        assert_eq!(write_took(50, Some(80)), Some(false));
        assert_eq!(write_took(50, None), None);
    }

    #[test]
    fn hotkey_scheme_round_trip() {
        for s in HotkeyScheme::ALL {
            assert_eq!(HotkeyScheme::from_u32(s.to_u32()), s);
        }
        assert_eq!(HotkeyScheme::from_u32(99), HotkeyScheme::CtrlAltPage);
    }

    #[test]
    fn monitor_keys_are_registry_safe() {
        assert_eq!(monitor_key("DELL U2720Q", 0), "DELL_U2720Q");
        assert_eq!(monitor_key("DELL U2720Q", 1), "DELL_U2720Q#1");
        assert_eq!(monitor_key("a\\b", 0), "a_b");
    }

    #[test]
    fn labels() {
        assert_eq!(percent_label(56.25), "56%");
        assert_eq!(percent_label(0.0), "0%");
    }

    #[test]
    fn volume_routing_matches_mac() {
        let base = RouteInput {
            intercept: true,
            endpoint_is_display: true,
            any_capable: true,
            ..Default::default()
        };
        // Playing through a monitor Glint can drive.
        assert!(route_volume_keys(RouteInput {
            matched_capable: true,
            matched_any: true,
            ..base
        }));
        // Names don't match any monitor: fall back to any capable monitor.
        assert!(route_volume_keys(base));
        // Playing through a monitor that doesn't answer DDC volume: Windows keeps it...
        let uncapable = RouteInput {
            matched_any: true,
            ..base
        };
        assert!(!route_volume_keys(uncapable));
        // ...unless "always intercept volume" is on.
        assert!(route_volume_keys(RouteInput {
            always: true,
            ..uncapable
        }));
        // Headphones/speakers: Windows keeps it, unless sync mode drives everything.
        let speakers = RouteInput {
            endpoint_is_display: false,
            ..base
        };
        assert!(!route_volume_keys(speakers));
        assert!(route_volume_keys(RouteInput { sync: true, ..speakers }));
        // Intercept off wins over everything.
        assert!(!route_volume_keys(RouteInput {
            intercept: false,
            sync: true,
            always: true,
            ..base
        }));
    }

    #[test]
    fn default_settings_match_mac() {
        let s = Settings::default();
        assert_eq!(s.brightness_step, 6.25);
        assert_eq!(s.volume_step, 6.25);
        assert!(s.route_volume);
        assert!(s.intercept_brightness);
        assert!(s.sync);
        assert!(!s.always_brightness && !s.always_volume && !s.write_only_volume && !s.debug_logging);
    }
}
