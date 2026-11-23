//! UI thread: hidden window, message loop, tray menu, hotkeys and the keyboard hook.

use std::cell::{Cell, OnceCell, RefCell};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use windows::core::{implement, w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Media::Audio::{
    EDataFlow, ERole, IMMDeviceEnumerator, IMMNotificationClient, IMMNotificationClient_Impl, MMDeviceEnumerator,
    DEVICE_STATE,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, VK_F1, VK_F14, VK_F15, VK_F2, VK_NEXT,
    VK_PRIOR, VK_VOLUME_DOWN, VK_VOLUME_MUTE, VK_VOLUME_UP,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CallNextHookEx, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
    DispatchMessageW, FindWindowW, GetCursorPos, GetMessageW, KillTimer, MessageBoxW, PostMessageW, PostQuitMessage,
    RegisterClassW, RegisterWindowMessageW, SetForegroundWindow, SetTimer, SetWindowsHookExW, TrackPopupMenu,
    TranslateMessage, UnhookWindowsHookEx, HMENU, IDOK, KBDLLHOOKSTRUCT, MB_ICONINFORMATION, MB_OKCANCEL, MF_CHECKED,
    MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MSG, SW_SHOWNORMAL, TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    WH_KEYBOARD_LL, WINDOW_EX_STYLE, WM_CONTEXTMENU, WM_DESTROY, WM_DEVICECHANGE, WM_DISPLAYCHANGE, WM_HOTKEY,
    WM_INPUT, WM_KEYDOWN, WM_LBUTTONUP, WM_NULL, WM_POWERBROADCAST, WM_SYSKEYDOWN, WM_TIMER, WNDCLASSW, WS_OVERLAPPED,
};

use crate::audio::Audio;
use crate::glog;
use crate::hidkeys;
use crate::logic::{self, Direction, HotkeyScheme, Settings, STEP_OPTIONS};
use crate::osd::Osd;
use crate::settings;
use crate::tray::{app_icon, Tray, WM_APP_TRAY};
use crate::worker::{self, Cmd, Snapshot, WM_APP_OSD, WM_APP_SNAPSHOT};

pub const VERSION: &str = match option_env!("GLINT_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

const CLASS: PCWSTR = w!("GlintMainWindow");
const WM_APP_SHOW: u32 = 0x8000 + 2;
const WM_APP_VOLKEY: u32 = 0x8000 + 3;
const WM_APP_AUDIO_CHANGED: u32 = 0x8000 + 4;

const TIMER_RESCAN: usize = 10;
const TIMER_ROUTE: usize = 11;
const TIMER_KEY_REPEAT: usize = 12;
/// Held hardware brightness key: first repeat after this delay, then every REPEAT_MS.
const REPEAT_DELAY_MS: u32 = 400;
const REPEAT_MS: u32 = 110;

const HK_DOWN: i32 = 1;
const HK_UP: i32 = 2;

const NIN_SELECT: u32 = 0x0400;
const NIN_KEYSELECT: u32 = 0x0401;
const DBT_DEVNODES_CHANGED: usize = 0x0007;
const PBT_APMRESUMEAUTOMATIC: usize = 0x0012;

const WEBSITE: &str = "https://glint.wemiller.com";
const SUPPORT: &str = "https://wemiller.com/support";

// Menu command ids.
const ID_QUIT: usize = 100;
const ID_RESCAN: usize = 101;
const ID_SYNC: usize = 102;
const ID_ROUTE: usize = 103;
const ID_LOGIN: usize = 104;
const ID_HIDE: usize = 105;
const ID_WEBSITE: usize = 106;
const ID_SUPPORT: usize = 107;
const ID_LOG: usize = 108;
const ID_OSD: usize = 109;
const ID_BSTEP: usize = 200;
const ID_VSTEP: usize = 300;
const ID_HOTKEY: usize = 400;
const ID_LEVEL: usize = 1000; // + display * 20 + level (0..=10)

struct App {
    hwnd: HWND,
    settings: RefCell<Settings>,
    tx: Sender<Cmd>,
    snapshot: Snapshot,
    audio: Option<Audio>,
    /// Decided outside the hook (on audio-device and display changes) so the hook itself
    /// never makes a COM call.
    route_volume: Cell<bool>,
    endpoint_names: RefCell<Vec<String>>,
    osd: Option<Osd>,
    tray: RefCell<Tray>,
    hotkeys_ok: Cell<bool>,
    hid: RefCell<hidkeys::Decoder>,
    hid_held: Cell<Option<Direction>>,
    hid_last: RefCell<Vec<u16>>,
    taskbar_created: u32,
    _audio_notifier: Option<(IMMDeviceEnumerator, IMMNotificationClient)>,
}

thread_local! {
    static APP: OnceCell<App> = const { OnceCell::new() };
}

fn with_app<R>(f: impl FnOnce(&App) -> R) -> Option<R> {
    APP.with(|a| a.get().map(f))
}

/// Tells the UI thread when the default audio device changes (callbacks arrive on a COM
/// worker thread, so they only post a message).
#[implement(IMMNotificationClient)]
struct AudioNotifier {
    hwnd: isize,
}

impl AudioNotifier {
    fn poke(&self) {
        // SAFETY: posting to our own window.
        let _ = unsafe {
            PostMessageW(
                Some(HWND(self.hwnd as *mut _)),
                WM_APP_AUDIO_CHANGED,
                WPARAM(0),
                LPARAM(0),
            )
        };
    }
}

impl IMMNotificationClient_Impl for AudioNotifier_Impl {
    fn OnDeviceStateChanged(&self, _id: &PCWSTR, _state: DEVICE_STATE) -> windows::core::Result<()> {
        self.poke();
        Ok(())
    }
    fn OnDeviceAdded(&self, _id: &PCWSTR) -> windows::core::Result<()> {
        self.poke();
        Ok(())
    }
    fn OnDeviceRemoved(&self, _id: &PCWSTR) -> windows::core::Result<()> {
        self.poke();
        Ok(())
    }
    fn OnDefaultDeviceChanged(&self, _flow: EDataFlow, _role: ERole, _id: &PCWSTR) -> windows::core::Result<()> {
        self.poke();
        Ok(())
    }
    fn OnPropertyValueChanged(
        &self,
        _id: &PCWSTR,
        _key: &windows::Win32::Foundation::PROPERTYKEY,
    ) -> windows::core::Result<()> {
        Ok(())
    }
}

fn register_audio_notifier(hwnd: HWND) -> Option<(IMMDeviceEnumerator, IMMNotificationClient)> {
    // SAFETY: COM is initialised on this thread.
    unsafe {
        let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let client: IMMNotificationClient = AudioNotifier { hwnd: hwnd.0 as isize }.into();
        enumerator.RegisterEndpointNotificationCallback(&client).ok()?;
        Some((enumerator, client))
    }
}

pub fn run() {
    let background = std::env::args().any(|a| a == "--background");
    // SAFETY: Win32 setup on the UI thread; every handle lives until process exit.
    unsafe {
        let _instance_mutex = CreateMutexW(None, true, w!("Local\\Glint-wemiller-single-instance"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            // Already running: running Glint again brings a hidden tray icon back.
            if let Ok(existing) = FindWindowW(CLASS, PCWSTR::null()) {
                let _ = PostMessageW(Some(existing), WM_APP_SHOW, WPARAM(0), LPARAM(0));
            }
            return;
        }
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let Ok(instance) = GetModuleHandleW(None) else { return };
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance.into(),
            hIcon: app_icon(false),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassW(&class);
        // A hidden top-level window (not message-only) so it receives broadcasts such as
        // WM_DISPLAYCHANGE and TaskbarCreated.
        let Ok(hwnd) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CLASS,
            w!("Glint"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance.into()),
            None,
        ) else {
            return;
        };

        let mut s = settings::load();
        if !background && s.tray_hidden {
            // Opened by hand: show the icon again.
            s.tray_hidden = false;
            settings::save(&s);
        }
        settings::repair_launch_at_login();

        let snapshot: Snapshot = Arc::new(Mutex::new(Vec::new()));
        let (tx, worker) = worker::spawn(hwnd, snapshot.clone());
        let _ = tx.send(Cmd::Rescan);

        let app = App {
            hwnd,
            settings: RefCell::new(s),
            tx,
            snapshot,
            audio: Audio::new(),
            route_volume: Cell::new(false),
            endpoint_names: RefCell::new(Vec::new()),
            osd: Osd::new(),
            tray: RefCell::new(Tray::new(hwnd)),
            hotkeys_ok: Cell::new(false),
            hid: RefCell::new(hidkeys::Decoder::default()),
            hid_held: Cell::new(None),
            hid_last: RefCell::new(Vec::new()),
            taskbar_created: RegisterWindowMessageW(w!("TaskbarCreated")),
            _audio_notifier: register_audio_notifier(hwnd),
        };
        APP.with(|a| {
            let _ = a.set(app);
        });
        with_app(|app| {
            app.apply_hotkeys();
            let raw = hidkeys::register(app.hwnd);
            glog!(
                "hardware brightness keys (raw input): {}",
                if raw { "listening" } else { "unavailable" }
            );
            app.refresh_route();
            if !app.settings.borrow().tray_hidden {
                app.tray.borrow_mut().show(&app.tooltip());
                if !settings::has_seen_welcome() {
                    app.tray.borrow().notify(
                        "Glint is running",
                        "Brightness keys (or Ctrl+Alt+Page Up / Page Down) and volume keys now control your monitor. \
                         Click the tray icon for settings.",
                    );
                    settings::mark_welcome_seen();
                }
            }
        });
        // Fallback for audio routing in case device notifications are missed.
        SetTimer(Some(hwnd), TIMER_ROUTE, 5000, None);

        let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(instance.into()), 0).ok();
        glog!("started v{VERSION} background={background} hook={}", hook.is_some());

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        if let Some(h) = hook {
            let _ = UnhookWindowsHookEx(h);
        }
        with_app(|app| {
            app.tray.borrow_mut().hide();
            if let Some((enumerator, client)) = &app._audio_notifier {
                let _ = enumerator.UnregisterEndpointNotificationCallback(client);
            }
            let _ = app.tx.send(Cmd::Quit);
        });
        let _ = worker.join();
        glog!("quit");
        CoUninitialize();
    }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        // SAFETY: for WH_KEYBOARD_LL, lparam points at a KBDLLHOOKSTRUCT.
        let kb = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let vk = kb.vkCode;
        let is_volume_key =
            vk == VK_VOLUME_UP.0 as u32 || vk == VK_VOLUME_DOWN.0 as u32 || vk == VK_VOLUME_MUTE.0 as u32;
        if is_volume_key {
            let swallowed = with_app(|app| {
                if !app.route_volume.get() {
                    return false;
                }
                let m = wparam.0 as u32;
                if m == WM_KEYDOWN || m == WM_SYSKEYDOWN {
                    // SAFETY: posting to our own window; the work happens outside the hook.
                    let _ = unsafe { PostMessageW(Some(app.hwnd), WM_APP_VOLKEY, WPARAM(vk as usize), LPARAM(0)) };
                }
                true
            })
            .unwrap_or(false);
            if swallowed {
                return LRESULT(1);
            }
        }
    }
    // SAFETY: pass everything else on.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let handled = with_app(|app| app.handle(msg, wparam, lparam)).flatten();
    if let Some(r) = handled {
        return r;
    }
    if msg == WM_DESTROY {
        // SAFETY: ends the message loop.
        unsafe { PostQuitMessage(0) };
        return LRESULT(0);
    }
    // SAFETY: default handling.
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

fn cursor() -> POINT {
    let mut p = POINT::default();
    // SAFETY: out-parameter.
    let _ = unsafe { GetCursorPos(&mut p) };
    p
}

fn open(target: &str) {
    // SAFETY: opens a URL or folder with the user's default handler.
    unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            &HSTRING::from(target),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
}

fn append(menu: HMENU, flags: windows::Win32::UI::WindowsAndMessaging::MENU_ITEM_FLAGS, id: usize, text: &str) {
    // SAFETY: appends to a menu we own; the string is copied by Windows.
    let _ = unsafe { AppendMenuW(menu, flags, id, &HSTRING::from(text)) };
}

fn separator(menu: HMENU) {
    // SAFETY: appends to a menu we own.
    let _ = unsafe { AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null()) };
}

fn checked(on: bool) -> windows::Win32::UI::WindowsAndMessaging::MENU_ITEM_FLAGS {
    if on {
        MF_STRING | MF_CHECKED
    } else {
        MF_STRING
    }
}

fn step_label(step: f64) -> String {
    if step.fract() == 0.0 {
        format!("{}%", step as i64)
    } else {
        format!("{step}%")
    }
}

impl App {
    fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }

    fn handle(&self, msg: u32, wparam: WPARAM, lparam: LPARAM) -> Option<LRESULT> {
        match msg {
            WM_APP_TRAY => {
                let event = (lparam.0 as u32) & 0xFFFF;
                if event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONUP {
                    self.show_menu();
                }
                Some(LRESULT(0))
            }
            WM_APP_SHOW => {
                self.set_tray_hidden(false);
                Some(LRESULT(0))
            }
            WM_APP_VOLKEY => {
                self.volume_key(wparam.0 as u32);
                Some(LRESULT(0))
            }
            WM_APP_AUDIO_CHANGED => {
                self.refresh_route();
                Some(LRESULT(0))
            }
            WM_HOTKEY => {
                let dir = if wparam.0 as i32 == HK_UP {
                    Direction::Up
                } else {
                    Direction::Down
                };
                self.brightness(dir, false);
                Some(LRESULT(0))
            }
            WM_INPUT => {
                self.raw_input(lparam);
                // DefWindowProc must still see WM_INPUT to clean up.
                None
            }
            WM_TIMER if wparam.0 == TIMER_KEY_REPEAT => {
                match self.hid_held.get() {
                    Some(dir) => {
                        self.brightness(dir, true);
                        // SAFETY: our own timer; re-arming changes its interval.
                        unsafe { SetTimer(Some(self.hwnd), TIMER_KEY_REPEAT, REPEAT_MS, None) };
                    }
                    None => {
                        // SAFETY: our own timer.
                        let _ = unsafe { KillTimer(Some(self.hwnd), TIMER_KEY_REPEAT) };
                    }
                }
                Some(LRESULT(0))
            }
            WM_APP_OSD => {
                if self.settings.borrow().show_osd {
                    if let Some(osd) = &self.osd {
                        osd.show(wparam.0, lparam.0 as f64 / 100.0);
                    }
                }
                Some(LRESULT(0))
            }
            WM_APP_SNAPSHOT => {
                self.refresh_route();
                self.tray.borrow().set_tip(&self.tooltip());
                Some(LRESULT(0))
            }
            WM_DISPLAYCHANGE => {
                self.schedule_rescan();
                None
            }
            WM_DEVICECHANGE if wparam.0 == DBT_DEVNODES_CHANGED => {
                // KVM switches often reconnect monitors without a mode change.
                self.schedule_rescan();
                None
            }
            WM_POWERBROADCAST if wparam.0 == PBT_APMRESUMEAUTOMATIC => {
                self.schedule_rescan();
                None
            }
            WM_TIMER if wparam.0 == TIMER_RESCAN => {
                // SAFETY: our own timer.
                let _ = unsafe { KillTimer(Some(self.hwnd), TIMER_RESCAN) };
                glog!("display change: rescanning");
                self.send(Cmd::Rescan);
                Some(LRESULT(0))
            }
            WM_TIMER if wparam.0 == TIMER_ROUTE => {
                self.refresh_route();
                Some(LRESULT(0))
            }
            m if m == self.taskbar_created && m != 0 => {
                // Explorer restarted: the tray icon is gone until re-added.
                if !self.settings.borrow().tray_hidden {
                    self.tray.borrow_mut().show(&self.tooltip());
                }
                Some(LRESULT(0))
            }
            _ => None,
        }
    }

    fn brightness(&self, dir: Direction, skip_internal: bool) {
        let p = cursor();
        let (step, sync) = {
            let s = self.settings.borrow();
            (s.brightness_step, s.sync)
        };
        self.send(Cmd::Brightness {
            point: (p.x, p.y),
            dir,
            step,
            sync,
            skip_internal,
        });
    }

    /// Hardware brightness keys (HID consumer usages 0x6F/0x70) from any keyboard.
    fn raw_input(&self, lparam: LPARAM) {
        let Ok(mut decoder) = self.hid.try_borrow_mut() else {
            return;
        };
        let Some(usages) = decoder.read(lparam) else { return };
        drop(decoder);
        if !usages.is_empty() && *self.hid_last.borrow() != usages {
            // Logged so an unrecognised keyboard can be diagnosed from the log folder.
            glog!("consumer keys: {:02X?}", usages);
        }
        *self.hid_last.borrow_mut() = usages.clone();
        let (held, pressed) = logic::brightness_transition(self.hid_held.get(), &usages);
        self.hid_held.set(held);
        if pressed {
            if let Some(dir) = held {
                // Windows itself applies these keys to a built-in laptop panel.
                self.brightness(dir, true);
                // SAFETY: our own timer.
                unsafe { SetTimer(Some(self.hwnd), TIMER_KEY_REPEAT, REPEAT_DELAY_MS, None) };
            }
        } else if held.is_none() {
            // SAFETY: our own timer.
            let _ = unsafe { KillTimer(Some(self.hwnd), TIMER_KEY_REPEAT) };
        }
    }

    fn schedule_rescan(&self) {
        // Debounced: displays settle over a second or two after a KVM switch or wake.
        // SAFETY: our own timer.
        unsafe { SetTimer(Some(self.hwnd), TIMER_RESCAN, 1500, None) };
    }

    /// Whether volume keys go to a monitor over DDC. Only when Windows is playing through
    /// a display (HDMI/DisplayPort) and that display (or, when names don't match any
    /// display, some display) answers DDC volume.
    fn refresh_route(&self) {
        let enabled = self.settings.borrow().route_volume;
        let endpoint = self.audio.as_ref().and_then(|a| a.default_endpoint());
        let mut route = false;
        let mut names = Vec::new();
        if let (true, Some(ep)) = (enabled, endpoint) {
            if ep.is_display {
                if let Ok(displays) = self.snapshot.lock() {
                    let matches = |n: &str| ep.names.iter().any(|e| logic::endpoint_matches_monitor(e, n));
                    let matched_capable = displays.iter().any(|d| d.has_volume && matches(&d.name));
                    let matched_any = displays.iter().any(|d| matches(&d.name));
                    let any_capable = displays.iter().any(|d| d.has_volume);
                    route = matched_capable || (!matched_any && any_capable);
                }
            }
            names = ep.names;
        }
        if route != self.route_volume.get() {
            glog!(
                "volume keys -> {} (endpoint {:?})",
                if route { "monitor DDC" } else { "Windows" },
                names
            );
        }
        self.route_volume.set(route);
        *self.endpoint_names.borrow_mut() = names;
    }

    fn volume_key(&self, vk: u32) {
        let endpoint = self.endpoint_names.borrow().clone();
        let step = self.settings.borrow().volume_step;
        if vk == VK_VOLUME_MUTE.0 as u32 {
            self.send(Cmd::ToggleMute { endpoint });
        } else {
            let dir = if vk == VK_VOLUME_UP.0 as u32 {
                Direction::Up
            } else {
                Direction::Down
            };
            self.send(Cmd::Volume { endpoint, dir, step });
        }
    }

    fn apply_hotkeys(&self) {
        // SAFETY: (un)registering hotkeys on our own window.
        unsafe {
            let _ = UnregisterHotKey(Some(self.hwnd), HK_DOWN);
            let _ = UnregisterHotKey(Some(self.hwnd), HK_UP);
            let scheme = self.settings.borrow().hotkeys;
            let ctrl_alt = MOD_CONTROL | MOD_ALT;
            let keys = match scheme {
                HotkeyScheme::CtrlAltPage => Some((ctrl_alt, VK_NEXT, VK_PRIOR)),
                HotkeyScheme::CtrlAltF1F2 => Some((ctrl_alt, VK_F1, VK_F2)),
                HotkeyScheme::F1F2 => Some((HOT_KEY_MODIFIERS(0), VK_F1, VK_F2)),
                HotkeyScheme::F14F15 => Some((HOT_KEY_MODIFIERS(0), VK_F14, VK_F15)),
                HotkeyScheme::Off => None,
            };
            let ok = match keys {
                Some((mods, down, up)) => {
                    let a = RegisterHotKey(Some(self.hwnd), HK_DOWN, mods, down.0 as u32).is_ok();
                    let b = RegisterHotKey(Some(self.hwnd), HK_UP, mods, up.0 as u32).is_ok();
                    a && b
                }
                None => true,
            };
            if !ok {
                glog!("hotkeys {:?}: another app already uses them", scheme);
            }
            self.hotkeys_ok.set(ok);
        }
    }

    fn tooltip(&self) -> String {
        let mut tip = String::from("Glint");
        if let Ok(displays) = self.snapshot.lock() {
            for d in displays.iter() {
                if let Some(b) = d.brightness {
                    tip.push_str(&format!("\n{} {}", d.name, logic::percent_label(b)));
                }
            }
        }
        tip.chars().take(127).collect()
    }

    fn set_tray_hidden(&self, hidden: bool) {
        {
            let mut s = self.settings.borrow_mut();
            s.tray_hidden = hidden;
            settings::save(&s);
        }
        if hidden {
            self.tray.borrow_mut().hide();
        } else if !self.tray.borrow().is_visible() {
            self.tray.borrow_mut().show(&self.tooltip());
        }
    }

    fn update_settings(&self, f: impl FnOnce(&mut Settings)) {
        let mut s = self.settings.borrow_mut();
        f(&mut s);
        settings::save(&s);
    }

    fn show_menu(&self) {
        let displays = self.snapshot.lock().map(|d| d.clone()).unwrap_or_default();
        let s = self.settings.borrow().clone();
        let login = settings::launch_at_login();
        // SAFETY: menus are created, shown and destroyed here.
        let cmd = unsafe {
            let Ok(menu) = CreatePopupMenu() else { return };
            append(menu, MF_STRING | MF_GRAYED, 0, &format!("Glint {VERSION}"));
            separator(menu);

            let controllable: Vec<_> = displays
                .iter()
                .enumerate()
                .filter(|(_, d)| d.brightness.is_some())
                .collect();
            if controllable.is_empty() {
                append(menu, MF_STRING | MF_GRAYED, 0, "No display answered DDC/CI");
            }
            for (i, d) in &controllable {
                let Ok(sub) = CreatePopupMenu() else { continue };
                let current = d.brightness.unwrap_or(0.0);
                for level in (0..=10).rev() {
                    let pct = level as f64 * 10.0;
                    let on = (current - pct).abs() < 5.0;
                    append(sub, checked(on), ID_LEVEL + i * 20 + level, &format!("{}%", level * 10));
                }
                let label = format!("{} \u{2014} {}", d.name, logic::percent_label(current));
                let _ = AppendMenuW(menu, MF_POPUP, sub.0 as usize, &HSTRING::from(label));
            }
            separator(menu);

            let hotkeys = CreatePopupMenu().ok();
            if let Some(sub) = hotkeys {
                for (i, scheme) in HotkeyScheme::ALL.iter().enumerate() {
                    append(sub, checked(*scheme == s.hotkeys), ID_HOTKEY + i, scheme.label());
                }
                let label = if self.hotkeys_ok.get() {
                    format!("Brightness keys: {}", s.hotkeys.label())
                } else {
                    format!("Brightness keys: {} (in use by another app)", s.hotkeys.label())
                };
                let _ = AppendMenuW(menu, MF_POPUP, sub.0 as usize, &HSTRING::from(label));
            }
            for (base, current, title) in [
                (ID_BSTEP, s.brightness_step, "Brightness step"),
                (ID_VSTEP, s.volume_step, "Volume step"),
            ] {
                if let Ok(sub) = CreatePopupMenu() {
                    for (i, step) in STEP_OPTIONS.iter().enumerate() {
                        append(sub, checked(*step == current), base + i, &step_label(*step));
                    }
                    let label = format!("{title}: {}", step_label(current));
                    let _ = AppendMenuW(menu, MF_POPUP, sub.0 as usize, &HSTRING::from(label));
                }
            }
            append(menu, checked(s.sync), ID_SYNC, "Sync brightness across displays");
            append(
                menu,
                checked(s.route_volume),
                ID_ROUTE,
                "Volume keys control monitor speakers",
            );
            append(menu, checked(s.show_osd), ID_OSD, "Show on-screen indicator");
            append(menu, checked(login), ID_LOGIN, "Launch at login");
            append(menu, MF_STRING, ID_HIDE, "Hide tray icon\u{2026}");
            append(menu, MF_STRING, ID_RESCAN, "Rescan displays");
            separator(menu);
            append(menu, MF_STRING, ID_WEBSITE, "Glint website");
            append(menu, MF_STRING, ID_SUPPORT, "Support future development");
            append(menu, MF_STRING, ID_LOG, "Open log folder");
            separator(menu);
            append(menu, MF_STRING, ID_QUIT, "Quit Glint");

            let p = cursor();
            let _ = SetForegroundWindow(self.hwnd);
            let cmd = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                p.x,
                p.y,
                Some(0),
                self.hwnd,
                None,
            );
            let _ = PostMessageW(Some(self.hwnd), WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            cmd.0 as usize
        };
        self.run_command(cmd, &displays);
    }

    fn run_command(&self, cmd: usize, displays: &[worker::DisplayInfo]) {
        match cmd {
            0 => {}
            ID_QUIT => {
                // SAFETY: destroying our own window ends the message loop.
                let _ = unsafe { DestroyWindow(self.hwnd) };
            }
            ID_RESCAN => self.send(Cmd::Rescan),
            ID_SYNC => self.update_settings(|s| s.sync = !s.sync),
            ID_ROUTE => {
                self.update_settings(|s| s.route_volume = !s.route_volume);
                self.refresh_route();
            }
            ID_OSD => self.update_settings(|s| s.show_osd = !s.show_osd),
            ID_LOGIN => settings::set_launch_at_login(!settings::launch_at_login()),
            ID_HIDE => {
                // SAFETY: modal message box owned by our window.
                let answer = unsafe {
                    MessageBoxW(
                        Some(self.hwnd),
                        w!("Glint keeps running without a tray icon. Open Glint again (Start menu or the exe) to bring the icon back."),
                        w!("Hide Glint's tray icon?"),
                        MB_OKCANCEL | MB_ICONINFORMATION,
                    )
                };
                if answer == IDOK {
                    self.set_tray_hidden(true);
                }
            }
            ID_WEBSITE => open(WEBSITE),
            ID_SUPPORT => open(SUPPORT),
            ID_LOG => {
                if let Some(d) = crate::log::dir() {
                    let _ = std::fs::create_dir_all(&d);
                    open(&d.display().to_string());
                }
            }
            c if (ID_BSTEP..ID_BSTEP + STEP_OPTIONS.len()).contains(&c) => {
                self.update_settings(|s| s.brightness_step = STEP_OPTIONS[c - ID_BSTEP]);
            }
            c if (ID_VSTEP..ID_VSTEP + STEP_OPTIONS.len()).contains(&c) => {
                self.update_settings(|s| s.volume_step = STEP_OPTIONS[c - ID_VSTEP]);
            }
            c if (ID_HOTKEY..ID_HOTKEY + HotkeyScheme::ALL.len()).contains(&c) => {
                self.update_settings(|s| s.hotkeys = HotkeyScheme::ALL[c - ID_HOTKEY]);
                self.apply_hotkeys();
            }
            c if c >= ID_LEVEL => {
                let index = (c - ID_LEVEL) / 20;
                let level = (c - ID_LEVEL) % 20;
                if index < displays.len() && level <= 10 {
                    self.send(Cmd::SetBrightness {
                        index,
                        percent: level as f64 * 10.0,
                    });
                }
            }
            _ => {}
        }
    }
}
