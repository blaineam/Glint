//! Settings in `$XDG_CONFIG_HOME/glint/glint.conf` (`~/.config/glint/glint.conf`) as plain
//! `key = value` lines, and remembered per-monitor values (pre-mute volume) in
//! `$XDG_STATE_HOME/glint/state`. Same settings model as the Windows app.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use glint_core::logic::{step_from_stored, step_to_stored, HotkeyScheme, Settings};

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var).map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home().join(fallback))
}

pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("glint")
}

pub fn state_dir() -> PathBuf {
    xdg("XDG_STATE_HOME", ".local/state").join("glint")
}

/// `key = value` lines; `#` comments and blank lines ignored.
pub fn parse_pairs(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect()
}

fn format_pairs(header: &str, pairs: &BTreeMap<String, String>) -> String {
    let mut s = format!("{header}\n");
    for (k, v) in pairs {
        s.push_str(&format!("{k} = {v}\n"));
    }
    s
}

pub fn settings_from(pairs: &BTreeMap<String, String>) -> Settings {
    let d = Settings::default();
    let flag = |k: &str, def: bool| pairs.get(k).map(|v| matches!(v.as_str(), "true" | "1" | "yes")).unwrap_or(def);
    let num = |k: &str| pairs.get(k).and_then(|v| v.parse::<f64>().ok());
    Settings {
        brightness_step: num("brightness_step")
            .map(|v| step_from_stored(step_to_stored(v)))
            .unwrap_or(d.brightness_step),
        volume_step: num("volume_step").map(|v| step_from_stored(step_to_stored(v))).unwrap_or(d.volume_step),
        sync: flag("sync", d.sync),
        intercept_brightness: flag("intercept_brightness", d.intercept_brightness),
        always_brightness: flag("always_intercept_brightness", d.always_brightness),
        route_volume: flag("intercept_volume", d.route_volume),
        always_volume: flag("always_intercept_volume", d.always_volume),
        write_only_volume: flag("write_only_volume", d.write_only_volume),
        hotkeys: pairs
            .get("hotkeys")
            .and_then(|v| v.parse::<u32>().ok())
            .map(HotkeyScheme::from_u32)
            .unwrap_or(d.hotkeys),
        show_osd: flag("show_osd", d.show_osd),
        tray_hidden: flag("tray_hidden", d.tray_hidden),
        debug_logging: flag("debug_logging", d.debug_logging),
    }
}

pub fn settings_to(s: &Settings) -> BTreeMap<String, String> {
    let b = |v: bool| v.to_string();
    [
        ("brightness_step", s.brightness_step.to_string()),
        ("volume_step", s.volume_step.to_string()),
        ("sync", b(s.sync)),
        ("intercept_brightness", b(s.intercept_brightness)),
        ("always_intercept_brightness", b(s.always_brightness)),
        ("intercept_volume", b(s.route_volume)),
        ("always_intercept_volume", b(s.always_volume)),
        ("write_only_volume", b(s.write_only_volume)),
        ("hotkeys", s.hotkeys.to_u32().to_string()),
        ("show_osd", b(s.show_osd)),
        ("tray_hidden", b(s.tray_hidden)),
        ("debug_logging", b(s.debug_logging)),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

pub fn load() -> Settings {
    let text = fs::read_to_string(config_dir().join("glint.conf")).unwrap_or_default();
    settings_from(&parse_pairs(&text))
}

pub fn save(s: &Settings) {
    let dir = config_dir();
    let _ = fs::create_dir_all(&dir);
    let header = "# Glint settings. Edited from the tray menu; hotkeys: 0 Ctrl+Alt+PgDn/PgUp, 1 Ctrl+Alt+F1/F2, 2 F14/F15, 3 off, 4 F1/F2.";
    let _ = fs::write(dir.join("glint.conf"), format_pairs(header, &settings_to(s)));
}

fn state() -> BTreeMap<String, String> {
    parse_pairs(&fs::read_to_string(state_dir().join("state")).unwrap_or_default())
}

pub fn pre_mute_volume(monitor_key: &str) -> Option<u32> {
    state().get(&format!("premute.{monitor_key}"))?.parse().ok()
}

pub fn set_pre_mute_volume(monitor_key: &str, raw: u32) {
    let mut st = state();
    st.insert(format!("premute.{monitor_key}"), raw.to_string());
    let _ = fs::create_dir_all(state_dir());
    let _ = fs::write(state_dir().join("state"), format_pairs("# Glint state (remembered per monitor).", &st));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_settings() {
        let s = Settings {
            brightness_step: 2.0,
            sync: false,
            hotkeys: HotkeyScheme::F1F2,
            write_only_volume: true,
            ..Default::default()
        };
        let text = format_pairs("# x", &settings_to(&s));
        assert_eq!(settings_from(&parse_pairs(&text)), s);
    }

    #[test]
    fn defaults_and_bad_values() {
        assert_eq!(settings_from(&BTreeMap::new()), Settings::default());
        let p = parse_pairs("brightness_step = 7\n# comment\nsync=yes\nhotkeys = banana\n\nnot a pair\n");
        let s = settings_from(&p);
        assert_eq!(s.brightness_step, 6.25); // snapped to the nearest offered step
        assert!(s.sync);
        assert_eq!(s.hotkeys, HotkeyScheme::CtrlAltPage);
    }
}
