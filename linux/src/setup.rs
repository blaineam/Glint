//! `sudo glint setup`: the one-time, root-only part. Linux only lets regular users talk
//! to I²C buses and input devices after a udev rule grants it, so this installs
//! `packaging/60-glint.rules` (seat-user access via systemd's `uaccess`) and loads the
//! i2c-dev and uinput modules now and at boot. The .deb/.rpm packages do the same at
//! install time. `--remove` undoes it.

use std::fs;
use std::path::Path;
use std::process::Command;

pub const RULES: &str = include_str!("../packaging/60-glint.rules");
pub const MODULES: &str = include_str!("../packaging/glint-modules.conf");
const RULES_PATH: &str = "/etc/udev/rules.d/60-glint.rules";
const PACKAGED_RULES: &str = "/usr/lib/udev/rules.d/60-glint.rules";
const MODULES_PATH: &str = "/etc/modules-load.d/glint.conf";

fn run(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd).args(args).status().map(|s| s.success()).unwrap_or(false)
}

fn reload() {
    run("udevadm", &["control", "--reload-rules"]);
    for sub in ["i2c-dev", "misc", "input"] {
        run("udevadm", &["trigger", "--action=change", &format!("--subsystem-match={sub}")]);
    }
    run("udevadm", &["settle", "--timeout=5"]);
}

pub fn setup(remove: bool) -> i32 {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        eprintln!(
            "glint setup changes system settings, so it needs root: sudo glint setup{}",
            if remove { " --remove" } else { "" }
        );
        return 1;
    }
    if remove {
        let _ = fs::remove_file(RULES_PATH);
        let _ = fs::remove_file(MODULES_PATH);
        reload();
        println!(
            "Removed Glint's udev rule and module list. Glint can no longer reach monitors or keys for regular users."
        );
        return 0;
    }
    if Path::new(PACKAGED_RULES).exists() {
        println!("The Glint package already installed its udev rule ({PACKAGED_RULES}).");
    } else if let Err(e) = fs::write(RULES_PATH, RULES) {
        eprintln!("Couldn't write {RULES_PATH}: {e}");
        return 1;
    } else {
        println!("Installed {RULES_PATH}");
    }
    if !Path::new("/usr/lib/modules-load.d/glint.conf").exists() {
        if let Err(e) = fs::write(MODULES_PATH, MODULES) {
            eprintln!("Couldn't write {MODULES_PATH}: {e}");
            return 1;
        }
        println!("Installed {MODULES_PATH}");
    }
    for m in ["i2c-dev", "uinput"] {
        if !run("modprobe", &[m]) {
            eprintln!("Note: couldn't load the {m} module now; it will load at the next boot.");
        }
    }
    reload();
    println!(
        "Done. The user logged in at this computer can now use Glint. If Glint is already running, restart it: systemctl --user restart glint (or quit and reopen it)."
    );
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_grant_only_what_glint_needs() {
        let rules: Vec<&str> = RULES.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()).collect();
        assert_eq!(rules.len(), 3);
        assert!(rules.iter().all(|r| r.contains("TAG+=\"uaccess\"")), "seat-user ACLs only, no world-writable modes");
        assert!(!RULES.contains("MODE=\"0666\""));
        assert!(MODULES.lines().any(|l| l == "i2c-dev") && MODULES.lines().any(|l| l == "uinput"));
    }
}
