//! Settings and remembered values in HKCU (no admin), plus launch-at-login via the per-user
//! Run key.

use windows::core::{HSTRING, PCWSTR};
use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteKeyValueW, RegGetValueW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE,
    REG_DWORD, REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};

use crate::logic::{step_from_stored, step_to_stored, HotkeyScheme, Settings};

const KEY: &str = r"Software\wemiller\Glint";
const PREMUTE_KEY: &str = r"Software\wemiller\Glint\PreMuteVolume";
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Glint";

pub fn get_dword(subkey: &str, name: &str) -> Option<u32> {
    let mut data = 0u32;
    let mut size = std::mem::size_of::<u32>() as u32;
    // SAFETY: data/size describe a valid u32 buffer.
    let rc = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            &HSTRING::from(subkey),
            &HSTRING::from(name),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut _),
            Some(&mut size),
        )
    };
    (rc == ERROR_SUCCESS).then_some(data)
}

fn open_for_write(subkey: &str) -> Option<HKEY> {
    let mut key = HKEY::default();
    // SAFETY: out-parameter key is closed by the caller.
    let rc = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            &HSTRING::from(subkey),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut key,
            None,
        )
    };
    (rc == ERROR_SUCCESS).then_some(key)
}

pub fn set_dword(subkey: &str, name: &str, value: u32) {
    if let Some(key) = open_for_write(subkey) {
        // SAFETY: valid key and a 4-byte buffer.
        unsafe {
            let _ = RegSetValueExW(key, &HSTRING::from(name), None, REG_DWORD, Some(&value.to_le_bytes()));
            let _ = RegCloseKey(key);
        }
    }
}

fn get_string(subkey: &str, name: &str) -> Option<String> {
    let mut buf = vec![0u16; 1024];
    let mut size = (buf.len() * 2) as u32;
    // SAFETY: buf/size describe a valid buffer.
    let rc = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            &HSTRING::from(subkey),
            &HSTRING::from(name),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut _),
            Some(&mut size),
        )
    };
    if rc != ERROR_SUCCESS {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

fn set_string(subkey: &str, name: &str, value: &str) {
    if let Some(key) = open_for_write(subkey) {
        let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
        let bytes: Vec<u8> = wide.iter().flat_map(|c| c.to_le_bytes()).collect();
        // SAFETY: valid key and buffer.
        unsafe {
            let _ = RegSetValueExW(key, &HSTRING::from(name), None, REG_SZ, Some(&bytes));
            let _ = RegCloseKey(key);
        }
    }
}

fn delete_value(subkey: &str, name: &str) {
    // SAFETY: plain strings.
    let _ = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, &HSTRING::from(subkey), &HSTRING::from(name)) };
}

pub fn load() -> Settings {
    let d = Settings::default();
    let flag = |name: &str, default: bool| get_dword(KEY, name).map(|v| v != 0).unwrap_or(default);
    Settings {
        brightness_step: get_dword(KEY, "BrightnessStep")
            .map(step_from_stored)
            .unwrap_or(d.brightness_step),
        volume_step: get_dword(KEY, "VolumeStep")
            .map(step_from_stored)
            .unwrap_or(d.volume_step),
        sync: flag("Sync", d.sync),
        route_volume: flag("RouteVolume", d.route_volume),
        hotkeys: get_dword(KEY, "Hotkeys")
            .map(HotkeyScheme::from_u32)
            .unwrap_or(d.hotkeys),
        show_osd: flag("ShowOSD", d.show_osd),
        tray_hidden: flag("TrayHidden", d.tray_hidden),
    }
}

pub fn save(s: &Settings) {
    set_dword(KEY, "BrightnessStep", step_to_stored(s.brightness_step));
    set_dword(KEY, "VolumeStep", step_to_stored(s.volume_step));
    set_dword(KEY, "Sync", s.sync as u32);
    set_dword(KEY, "RouteVolume", s.route_volume as u32);
    set_dword(KEY, "Hotkeys", s.hotkeys.to_u32());
    set_dword(KEY, "ShowOSD", s.show_osd as u32);
    set_dword(KEY, "TrayHidden", s.tray_hidden as u32);
}

pub fn pre_mute_volume(monitor_key: &str) -> Option<u32> {
    get_dword(PREMUTE_KEY, monitor_key)
}

pub fn set_pre_mute_volume(monitor_key: &str, raw: u32) {
    set_dword(PREMUTE_KEY, monitor_key, raw);
}

pub fn has_seen_welcome() -> bool {
    get_dword(KEY, "WelcomeShown").is_some()
}

pub fn mark_welcome_seen() {
    set_dword(KEY, "WelcomeShown", 1);
}

fn run_command() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    Some(format!("\"{}\" --background", exe.display()))
}

/// Launch at login is on when the Run value points at this exe.
pub fn launch_at_login() -> bool {
    match (get_string(RUN_KEY, RUN_VALUE), run_command()) {
        (Some(v), Some(cmd)) => v.eq_ignore_ascii_case(&cmd),
        _ => false,
    }
}

pub fn set_launch_at_login(on: bool) {
    if on {
        if let Some(cmd) = run_command() {
            set_string(RUN_KEY, RUN_VALUE, &cmd);
        }
    } else {
        delete_value(RUN_KEY, RUN_VALUE);
    }
}

/// If the exe moved since launch-at-login was turned on, point the Run value at the new
/// location so login keeps working.
pub fn repair_launch_at_login() {
    if let (Some(v), Some(cmd)) = (get_string(RUN_KEY, RUN_VALUE), run_command()) {
        if !v.eq_ignore_ascii_case(&cmd) && v.to_ascii_lowercase().contains("glint") {
            set_string(RUN_KEY, RUN_VALUE, &cmd);
        }
    }
}
