//! Glint for Linux: DDC display control from the keyboard.
//!
//! `glint` runs the background app (tray, keys, DDC). Other commands talk to it through a
//! socket, so desktop shortcuts can call `glint brightness up` and friends.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod config;
mod edid;
mod keys;
mod pactl;
mod proto;

#[cfg(target_os = "linux")]
mod app;
#[cfg(target_os = "linux")]
mod dbus;
mod drm;
#[cfg(target_os = "linux")]
mod i2c;
#[cfg(target_os = "linux")]
mod input;
#[cfg(target_os = "linux")]
mod log;
#[cfg(target_os = "linux")]
mod setup;
#[cfg(target_os = "linux")]
mod tray;
#[cfg(target_os = "linux")]
mod worker;

pub const VERSION: &str = match option_env!("GLINT_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

const HELP: &str = "Glint: DDC display control from your keyboard.

Usage:
  glint                         Start Glint (tray icon, keys, DDC). Run once per login;
                                launch at login from the tray menu.
  glint status                  Show monitors, what Glint can control and key routing.
  glint brightness up|down|N    Change brightness (N = 0-100) through the running Glint.
  glint volume up|down|mute|N   Change monitor speaker volume.
  glint rescan                  Look for monitors again.
  glint show                    Bring back a hidden tray icon.
  glint quit                    Stop the running Glint.
  sudo glint setup [--remove]   One-time: let your user reach monitors (I2C) and keys.
  glint --version | --help

Settings: ~/.config/glint/glint.conf   Log: ~/.local/state/glint/glint.log
https://glint.wemiller.com";

#[cfg(target_os = "linux")]
fn main() {
    let locale = glint_core::i18n::posix_locale(|k| std::env::var(k).ok());
    glint_core::i18n::init(locale.as_deref().and_then(glint_core::i18n::lang_index_from_locale));

    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let code = match args.as_slice() {
        [] => {
            app::run();
            0
        }
        ["--version" | "-V" | "version"] => {
            println!("glint {VERSION}");
            0
        }
        ["--help" | "-h" | "help"] => {
            println!("{HELP}");
            0
        }
        ["setup"] => setup::setup(false),
        ["setup", "--remove"] => setup::setup(true),
        ["status"] => match app::send_command("status") {
            Some(r) => {
                println!("{r}");
                0
            }
            None => standalone_status(),
        },
        [cmd @ ("brightness" | "volume" | "rescan" | "show" | "quit"), rest @ ..] => {
            let line = std::iter::once(*cmd).chain(rest.iter().copied()).collect::<Vec<_>>().join(" ");
            match app::send_command(&line) {
                Some(r) if r == "ok" => 0,
                Some(r) => {
                    eprintln!("{r}");
                    1
                }
                None => {
                    eprintln!("Glint isn't running. Start it with `glint` (or `systemctl --user start glint`).");
                    1
                }
            }
        }
        _ => {
            eprintln!("{HELP}");
            2
        }
    };
    std::process::exit(code);
}

/// `glint status` without a running Glint: scan monitors and try DDC directly, and say
/// what's missing (setup, modules) instead of failing silently.
#[cfg(target_os = "linux")]
fn standalone_status() -> i32 {
    use std::path::Path;
    println!("Glint {VERSION} (not running)");
    let conns = drm::scan(Path::new("/sys"));
    if conns.is_empty() {
        println!("No connected monitors found in /sys/class/drm.");
    }
    let mut denied = false;
    for c in &conns {
        let what = if c.internal {
            match drm::backlight(Path::new("/sys")) {
                Some(b) => format!("built-in panel, backlight {b}"),
                None => "built-in panel, no backlight device".into(),
            }
        } else {
            match c.i2c_bus {
                None => "no DDC bus linked by the driver (Glint matches by EDID when running)".into(),
                Some(n) => match i2c::Bus::open(n) {
                    Err(e) => {
                        denied |= e.kind() == std::io::ErrorKind::PermissionDenied;
                        format!("/dev/i2c-{n}: {e}")
                    }
                    Ok(mut bus) => {
                        let f = |r: Result<proto::VcpReply, proto::ReplyError>| match r {
                            Ok(v) => format!("{}/{}", v.current, v.max),
                            Err(e) => format!("{e:?}"),
                        };
                        let b = f(bus.get_vcp(0x10));
                        let v = f(bus.get_vcp(0x62));
                        format!("/dev/i2c-{n}: brightness {b}, volume {v}")
                    }
                },
            }
        };
        println!("  {} ({}): {what}", c.name, c.connector);
    }
    if denied || !Path::new("/dev/i2c-0").exists() && conns.iter().any(|c| !c.internal) {
        println!("\nGlint can't reach the monitors' I2C buses yet. Run once: sudo glint setup");
    }
    0
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("Glint for Linux only runs on Linux. {}", HELP.lines().next().unwrap_or(""));
}

#[cfg(test)]
mod tests {
    /// Every `t("...")` in the Linux UI must have translations.
    #[test]
    fn every_ui_string_is_translated() {
        let sources = [include_str!("tray.rs"), include_str!("app.rs")];
        let keys: Vec<&str> = sources.iter().flat_map(|s| glint_core::i18n::keys_in_source(s)).collect();
        assert!(keys.len() > 20, "expected the UI to use t(), found {}", keys.len());
        let missing: Vec<_> = keys.into_iter().filter(|k| !glint_core::i18n::has_key(k)).collect();
        assert!(missing.is_empty(), "untranslated: {missing:?}");
    }
}
