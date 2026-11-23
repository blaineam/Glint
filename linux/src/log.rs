//! Diagnostics log at `$XDG_STATE_HOME/glint/glint.log` (rotated at 256 KB), also echoed
//! to stderr so `journalctl --user -u glint` shows it. No telemetry: nothing leaves the
//! machine.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static LOCK: Mutex<()> = Mutex::new(());
static DEBUG: AtomicBool = AtomicBool::new(false);
const MAX_BYTES: u64 = 256 * 1024;

pub fn set_debug(on: bool) {
    DEBUG.store(on, Ordering::Relaxed);
}

pub fn debug_enabled() -> bool {
    DEBUG.load(Ordering::Relaxed)
}

pub fn path() -> PathBuf {
    crate::config::state_dir().join("glint.log")
}

pub fn log(msg: &str) {
    let _guard = LOCK.lock();
    let path = path();
    if let Some(d) = path.parent() {
        let _ = fs::create_dir_all(d);
    }
    if fs::metadata(&path).map(|m| m.len() > MAX_BYTES).unwrap_or(false) {
        let _ = fs::rename(&path, path.with_extension("log.old"));
    }
    let t = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let line = format!("{t:.3} {msg}");
    eprintln!("{line}");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{line}");
    }
}

#[macro_export]
macro_rules! glog {
    ($($arg:tt)*) => { $crate::log::log(&format!($($arg)*)) };
}

#[macro_export]
macro_rules! gdebug {
    ($($arg:tt)*) => {
        if $crate::log::debug_enabled() {
            $crate::log::log(&format!($($arg)*))
        }
    };
}
