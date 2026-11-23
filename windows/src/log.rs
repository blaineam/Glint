//! Tiny diagnostics log at %LOCALAPPDATA%\Glint\glint.log (rotated at 256 KB). Glint has
//! no telemetry; this file never leaves the machine and exists so a user can see why a
//! monitor didn't answer DDC.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use windows::Win32::System::SystemInformation::GetLocalTime;

static LOCK: Mutex<()> = Mutex::new(());
/// Detailed DDC, audio-routing and key logging (Mac "Debug logging"). Startup, display
/// scans and failures are always logged so a problem report has something to go on.
static DEBUG: AtomicBool = AtomicBool::new(false);

pub fn set_debug(on: bool) {
    DEBUG.store(on, Ordering::Relaxed);
}

pub fn debug_enabled() -> bool {
    DEBUG.load(Ordering::Relaxed)
}
const MAX_BYTES: u64 = 256 * 1024;

pub fn dir() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Glint"))
}

pub fn path() -> Option<PathBuf> {
    dir().map(|d| d.join("glint.log"))
}

pub fn log(msg: &str) {
    let Some(path) = path() else { return };
    let _guard = LOCK.lock();
    if let Some(d) = path.parent() {
        let _ = fs::create_dir_all(d);
    }
    if fs::metadata(&path).map(|m| m.len() > MAX_BYTES).unwrap_or(false) {
        let _ = fs::rename(&path, path.with_extension("log.old"));
    }
    // SAFETY: no arguments.
    let t = unsafe { GetLocalTime() };
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(
            f,
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03} {msg}",
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds
        );
    }
}

#[macro_export]
macro_rules! glog {
    ($($arg:tt)*) => { $crate::log::log(&format!($($arg)*)) };
}

/// Logged only with debug logging on.
#[macro_export]
macro_rules! gdebug {
    ($($arg:tt)*) => {
        if $crate::log::debug_enabled() {
            $crate::log::log(&format!($($arg)*))
        }
    };
}
