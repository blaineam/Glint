//! Per-user install, no admin: Glint copies itself to `%LOCALAPPDATA%\Programs\Glint`,
//! adds a Start menu shortcut, starts at login, and registers in Settings › Apps (the
//! per-user Uninstall key) so it can be removed like any app. Running a newer downloaded
//! exe offers to update the installed copy; running the same version opens the installed
//! one. Choosing "No" keeps Glint portable, and the tray menu offers to install later.
//!
//! Command line: `--install` (no questions), `--uninstall [--quiet]`, `--portable` (skip the
//! offer once), `--wait <pid>` (let a previous instance exit first; used when handing over).

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use windows::core::{Interface, HSTRING, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, LPARAM, WPARAM};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Registry::{RegDeleteTreeW, HKEY_CURRENT_USER};
use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
use windows::Win32::UI::WindowsAndMessaging::{
    FindWindowW, IsWindow, MessageBoxW, PostMessageW, IDYES, MB_ICONERROR, MB_ICONINFORMATION, MB_ICONQUESTION, MB_OK,
    MB_YESNO, MESSAGEBOX_STYLE, WM_CLOSE,
};

use crate::app::{MAIN_CLASS, VERSION};
use crate::i18n::t;
use crate::logic::compare_versions;
use crate::settings;

const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Glint";
const SETTINGS_KEY: &str = r"Software\wemiller\Glint";
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from)
}

pub fn install_dir() -> Option<PathBuf> {
    env_dir("LOCALAPPDATA").map(|d| d.join("Programs").join("Glint"))
}

pub fn installed_exe() -> Option<PathBuf> {
    install_dir().map(|d| d.join("Glint.exe"))
}

fn start_menu_link() -> Option<PathBuf> {
    env_dir("APPDATA").map(|d| d.join(r"Microsoft\Windows\Start Menu\Programs\Glint.lnk"))
}

fn same_file(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf()).to_string_lossy().to_lowercase();
    norm(a) == norm(b)
}

/// Whether this process is the installed copy.
pub fn is_installed_copy() -> bool {
    match (std::env::current_exe(), installed_exe()) {
        (Ok(me), Some(inst)) => same_file(&me, &inst),
        _ => false,
    }
}

fn installed() -> Option<(PathBuf, String)> {
    let exe = installed_exe().filter(|p| p.exists())?;
    let version = settings::get_string(UNINSTALL_KEY, "DisplayVersion").unwrap_or_else(|| "0".into());
    Some((exe, version))
}

fn message(title: &str, text: &str, style: MESSAGEBOX_STYLE) -> bool {
    // SAFETY: modal message box with owned strings.
    unsafe { MessageBoxW(None, &HSTRING::from(text), &HSTRING::from(title), style) == IDYES }
}

/// Asks a running Glint to quit and waits (up to 5 s) until its window is gone.
pub fn close_running() {
    // SAFETY: finding and messaging another process's top-level window by class.
    unsafe {
        let Ok(hwnd) = FindWindowW(MAIN_CLASS, PCWSTR::null()) else { return };
        let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
        let deadline = Instant::now() + Duration::from_secs(5);
        while IsWindow(Some(hwnd)).as_bool() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
        // The process exits right after its window; give it a moment to release the exe.
        std::thread::sleep(Duration::from_millis(300));
    }
}

/// Waits (up to 10 s) for a previous Glint process to exit before this one starts.
pub fn wait_for_pid(pid: u32) {
    // SAFETY: a synchronize-only handle, closed below.
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_SYNCHRONIZE, false, pid) {
            WaitForSingleObject(h, 10_000);
            let _ = CloseHandle(h);
        }
    }
}

pub fn launch(exe: &Path, args: &[&str]) {
    let _ = Command::new(exe).args(args).spawn();
}

fn create_shortcut(exe: &Path, link: &Path) -> windows::core::Result<()> {
    // SAFETY: COM on this thread (initialised here if it wasn't already).
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let shell: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        let exe_h = HSTRING::from(exe.as_os_str());
        shell.SetPath(&exe_h)?;
        shell.SetIconLocation(&exe_h, 0)?;
        shell.SetDescription(&HSTRING::from("Glint: DDC display control from your keyboard"))?;
        if let Some(dir) = exe.parent() {
            shell.SetWorkingDirectory(&HSTRING::from(dir.as_os_str()))?;
        }
        let file: IPersistFile = shell.cast()?;
        file.Save(&HSTRING::from(link.as_os_str()), true)?;
    }
    Ok(())
}

/// Copies this exe into place and registers it. The running installed copy, if any, must
/// already be closed.
pub fn install() -> Result<PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = install_dir().ok_or("LOCALAPPDATA isn't set")?;
    let exe = dir.join("Glint.exe");
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !same_file(&me, &exe) {
        // The old copy may take a moment to let go of its file after quitting.
        let mut last = None;
        for _ in 0..20 {
            match std::fs::copy(&me, &exe) {
                Ok(_) => {
                    last = None;
                    break;
                }
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
        }
        if let Some(e) = last {
            return Err(format!("{}: {e}", exe.display()));
        }
    }
    if let Some(link) = start_menu_link() {
        if let Err(e) = create_shortcut(&exe, &link) {
            crate::glog!("install: shortcut failed: {e}");
        }
    }
    let quoted = format!("\"{}\"", exe.display());
    settings::set_string(UNINSTALL_KEY, "DisplayName", "Glint");
    settings::set_string(UNINSTALL_KEY, "DisplayVersion", VERSION);
    settings::set_string(UNINSTALL_KEY, "Publisher", "Blaine Miller");
    settings::set_string(UNINSTALL_KEY, "DisplayIcon", &format!("{quoted},0"));
    settings::set_string(UNINSTALL_KEY, "InstallLocation", &dir.display().to_string());
    settings::set_string(UNINSTALL_KEY, "UninstallString", &format!("{quoted} --uninstall"));
    settings::set_string(UNINSTALL_KEY, "QuietUninstallString", &format!("{quoted} --uninstall --quiet"));
    settings::set_string(UNINSTALL_KEY, "URLInfoAbout", "https://glint.wemiller.com");
    settings::set_dword(UNINSTALL_KEY, "NoModify", 1);
    settings::set_dword(UNINSTALL_KEY, "NoRepair", 1);
    let size_kb = std::fs::metadata(&exe).map(|m| (m.len() / 1024) as u32).unwrap_or(0);
    settings::set_dword(UNINSTALL_KEY, "EstimatedSize", size_kb);
    // Start at login, from the installed copy.
    settings::set_string(RUN_KEY, "Glint", &format!("{quoted} --background"));
    crate::glog!("installed v{VERSION} to {}", exe.display());
    Ok(exe)
}

fn report_error(e: &str) {
    message(&t("Glint couldn't be installed: {}").replace("{}", e), "", MB_OK | MB_ICONERROR);
}

/// At launch from anywhere but the installed copy: offer to install or update, or open
/// the installed copy. Returns true when this process should exit (another copy takes over).
pub fn offer() -> bool {
    if let Some((exe, version)) = installed() {
        if compare_versions(VERSION, &version) == std::cmp::Ordering::Greater {
            let text = t("The installed Glint is {old}. Update it to {new}?")
                .replace("{old}", &version)
                .replace("{new}", VERSION);
            if !message(t("Update Glint?"), &text, MB_YESNO | MB_ICONQUESTION) {
                return false;
            }
            close_running();
            match install() {
                Ok(exe) => launch(&exe, &[]),
                Err(e) => {
                    report_error(&e);
                    return false;
                }
            }
        } else {
            // Same or newer version already installed: use it.
            launch(&exe, &[]);
        }
        return true;
    }
    if settings::get_dword(SETTINGS_KEY, "PortableChosen") == Some(1) {
        return false;
    }
    let text = format!(
        "{}\n\n{}",
        t("Glint can install itself for your user: it is copied to your user folder, added to the Start menu and to Settings › Apps, and starts at login. No administrator rights are needed."),
        t("Choose No to keep running it from where it is.")
    );
    if !message(t("Install Glint?"), &text, MB_YESNO | MB_ICONQUESTION) {
        settings::set_dword(SETTINGS_KEY, "PortableChosen", 1);
        return false;
    }
    match install() {
        Ok(exe) => {
            launch(&exe, &[]);
            true
        }
        Err(e) => {
            report_error(&e);
            false
        }
    }
}

/// "Install Glint…" from the tray of a portable copy: install, then hand over to the
/// installed copy once this process has quit. Returns true if the caller should quit.
pub fn install_from_tray() -> bool {
    match install() {
        Ok(exe) => {
            let pid = std::process::id().to_string();
            launch(&exe, &["--wait", &pid]);
            true
        }
        Err(e) => {
            report_error(&e);
            false
        }
    }
}

/// `--uninstall`: removes the installed copy, its shortcut, login entry, Settings › Apps
/// entry, settings and log. The exe can't delete itself while running, so a hidden `cmd`
/// removes it a moment after this process exits.
pub fn uninstall(quiet: bool) {
    if !quiet
        && !message(
            t("Uninstall Glint?"),
            t("This removes Glint, its Start menu entry and its settings."),
            MB_YESNO | MB_ICONQUESTION,
        )
    {
        return;
    }
    // Settings › Apps starts a second copy with --uninstall; quit the one in the tray.
    close_running();
    // SAFETY: deleting our own per-user registry trees.
    unsafe {
        let _ = RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(UNINSTALL_KEY));
        let _ = RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(SETTINGS_KEY));
    }
    settings::delete_value(RUN_KEY, "Glint");
    if let Some(link) = start_menu_link() {
        let _ = std::fs::remove_file(link);
    }
    if let Some(d) = crate::log::dir() {
        let _ = std::fs::remove_dir_all(d);
    }
    if let (Some(exe), Some(dir)) = (installed_exe(), install_dir()) {
        if is_installed_copy() {
            let script =
                format!("ping 127.0.0.1 -n 3 >nul & del /f /q \"{}\" & rmdir \"{}\"", exe.display(), dir.display());
            let _ = Command::new("cmd.exe").args(["/c", &script]).creation_flags(CREATE_NO_WINDOW).spawn();
        } else {
            let _ = std::fs::remove_file(&exe);
            let _ = std::fs::remove_dir(&dir);
        }
    }
    if !quiet {
        message("Glint", t("Glint was uninstalled."), MB_OK | MB_ICONINFORMATION);
    }
}
