//! Glint for Windows: DDC display control from the keyboard, as a standard user.
//!
//! The UI thread owns a hidden window (message loop, tray icon, hotkeys, low-level keyboard
//! hook, OSD). DDC runs on a worker thread (see `worker`).
#![cfg_attr(windows, windows_subsystem = "windows")]
#![cfg_attr(not(windows), allow(dead_code))]

// Shared with the Linux app; re-exported so `crate::logic` / `crate::i18n` read naturally.
#[allow(unused_imports)]
use glint_core::{i18n, logic};

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod audio;
#[cfg(windows)]
mod ddc;
#[cfg(windows)]
mod flyout;
#[cfg(windows)]
mod hdr;
#[cfg(windows)]
mod hidkeys;
#[cfg(windows)]
mod log;
#[cfg(windows)]
mod osd;
#[cfg(windows)]
mod settings;
#[cfg(windows)]
mod tray;
#[cfg(windows)]
mod wmi;
#[cfg(windows)]
mod worker;

#[cfg(windows)]
fn main() {
    // SAFETY: no arguments.
    let langid = unsafe { windows::Win32::Globalization::GetUserDefaultUILanguage() };
    i18n::init(i18n::lang_index(langid));
    app::run();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Glint for Windows only runs on Windows. The Mac app lives in ../Glint.");
}

#[cfg(test)]
mod tests {
    /// Every `t("...")` in the Windows UI must have translations.
    #[test]
    fn every_ui_string_is_translated() {
        let sources =
            [include_str!("app.rs"), include_str!("flyout.rs"), include_str!("osd.rs"), include_str!("ddc.rs")];
        let keys: Vec<&str> = sources.iter().flat_map(|s| glint_core::i18n::keys_in_source(s)).collect();
        assert!(keys.len() > 20, "expected the UI to use t(), found {}", keys.len());
        let missing: Vec<_> = keys.into_iter().filter(|k| !glint_core::i18n::has_key(k)).collect();
        assert!(missing.is_empty(), "untranslated: {missing:?}");
    }
}
