//! Glint for Windows: DDC display control from the keyboard, as a standard user.
//!
//! The UI thread owns a hidden window (message loop, tray icon, hotkeys, low-level keyboard
//! hook, OSD). DDC runs on a worker thread (see `worker`).
#![cfg_attr(windows, windows_subsystem = "windows")]
#![cfg_attr(not(windows), allow(dead_code))]

mod i18n;
mod logic;
mod strings;

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod audio;
#[cfg(windows)]
mod ddc;
#[cfg(windows)]
mod flyout;
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
    app::run();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Glint for Windows only runs on Windows. The Mac app lives in ../Glint.");
}
