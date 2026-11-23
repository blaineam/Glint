//! The daemon: one controller loop owns the settings and ties together the key reader,
//! the DDC worker, audio routing, the tray, the indicator and the control socket.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use glint_core::i18n::t;
use glint_core::logic::{self, Direction, HotkeyScheme, RouteInput, Settings, STEP_OPTIONS};
use ksni::blocking::TrayMethods;

use crate::dbus::Notifier;
use crate::input::{self, Shared};
use crate::keys::{Action, Policy};
use crate::tray::GlintTray;
use crate::worker::{self, Cmd, DisplayInfo, Out, WorkerPrefs};
use crate::{config, drm, glog, pactl};

const WEBSITE: &str = "https://glint.wemiller.com";
const SUPPORT: &str = "https://wemiller.com/support";

#[derive(Clone, Debug)]
pub enum MenuCmd {
    Level { index: usize, volume: bool, percent: f64 },
    InterceptBrightness,
    AlwaysBrightness,
    Hotkeys(usize),
    InterceptVolume,
    AlwaysVolume,
    WriteOnlyVolume,
    BrightnessStep(usize),
    VolumeStep(usize),
    Sync,
    Osd,
    LaunchAtLogin,
    HideTray,
    Rescan,
    DebugLogging,
    OpenLog,
    Website,
    Support,
    Quit,
}

pub enum Msg {
    Key(Action),
    Menu(MenuCmd),
    Worker(Out),
    Sink(Option<pactl::Sink>),
    /// A command line from `glint <command>` and where to send the reply.
    Control(String, Sender<String>),
    DisplaysChanged,
}

pub fn socket_path() -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    // SAFETY: getuid has no preconditions.
    dir.join(format!("glint-{}.sock", unsafe { libc::getuid() }))
}

/// Sends one command to a running Glint; None if none is running.
pub fn send_command(line: &str) -> Option<String> {
    let mut s = UnixStream::connect(socket_path()).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    writeln!(s, "{line}").ok()?;
    let mut reply = String::new();
    BufReader::new(s).read_line(&mut reply).ok()?;
    Some(reply.trim_end().replace("\\n", "\n"))
}

fn systemctl(args: &[&str]) -> bool {
    Command::new("systemctl").arg("--user").args(args).output().map(|o| o.status.success()).unwrap_or(false)
}

fn launch_at_login() -> bool {
    systemctl(&["is-enabled", "--quiet", "glint.service"])
}

fn open(target: &str) {
    let _ = Command::new("xdg-open").arg(target).spawn();
}

fn worker_prefs(s: &Settings) -> WorkerPrefs {
    WorkerPrefs { always_brightness: s.always_brightness, write_only_volume: s.write_only_volume }
}

struct Daemon {
    tx: Sender<Msg>,
    settings: Settings,
    displays: Vec<DisplayInfo>,
    sink: Option<pactl::Sink>,
    worker: Sender<Cmd>,
    keys: Arc<Shared>,
    tray: Option<ksni::blocking::Handle<GlintTray>>,
    notifier: Notifier,
    warned: Vec<String>,
}

pub fn run() {
    // One Glint per user: a second launch brings a hidden tray icon back.
    let sock = socket_path();
    if UnixStream::connect(&sock).is_ok() {
        let _ = send_command("show");
        eprintln!("Glint is already running.");
        return;
    }
    let _ = std::fs::remove_file(&sock);
    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("glint: can't open {}: {e}", sock.display());
            return;
        }
    };

    let mut settings = config::load();
    if settings.tray_hidden && std::env::var_os("GLINT_BACKGROUND").is_none() {
        // Opened by hand (not by the login service): show the icon again.
        settings.tray_hidden = false;
        config::save(&settings);
    }
    crate::log::set_debug(settings.debug_logging);
    glog!("started v{} on {}", crate::VERSION, std::env::consts::ARCH);

    let (tx, rx) = channel::<Msg>();
    let wtx = tx.clone();
    let (worker, worker_thread) =
        worker::spawn(worker_prefs(&settings), Box::new(move |o| drop(wtx.send(Msg::Worker(o)))));
    let _ = worker.send(Cmd::Rescan);

    let ktx = tx.clone();
    let keys = Shared::new(
        Box::new(move |a| drop(ktx.send(Msg::Key(a)))),
        Policy { intercept_brightness: settings.intercept_brightness, hotkeys: settings.hotkeys, route_volume: false },
    );
    input::start(keys.clone());

    // Control socket: `glint brightness up`, desktop shortcuts, a second launch.
    let ctx = tx.clone();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let ctx = ctx.clone();
            thread::spawn(move || {
                let mut line = String::new();
                if BufReader::new(&stream).read_line(&mut line).is_ok() {
                    let (rtx, rrx) = channel();
                    let _ = ctx.send(Msg::Control(line.trim().to_string(), rtx));
                    let reply = rrx.recv_timeout(Duration::from_secs(4)).unwrap_or_default();
                    let _ = writeln!(&stream, "{}", reply.replace('\n', "\\n"));
                }
            });
        }
    });

    // Audio routing: which sink is playing (cheap `pactl` calls, every 2 s).
    let atx = tx.clone();
    thread::spawn(move || {
        let mut last: Option<Option<pactl::Sink>> = None;
        loop {
            let sink = pactl::default_sink();
            if last.as_ref() != Some(&sink) {
                last = Some(sink.clone());
                if atx.send(Msg::Sink(sink)).is_err() {
                    return;
                }
            }
            thread::sleep(Duration::from_secs(2));
        }
    });

    // Monitor hotplug (KVM switches, docks): watch connector status and EDIDs.
    let dtx = tx.clone();
    thread::spawn(move || {
        let signature = || {
            drm::scan(std::path::Path::new("/sys"))
                .iter()
                .map(|c| format!("{}:{}", c.connector, c.edid.len()))
                .collect::<Vec<_>>()
        };
        let mut last = signature();
        loop {
            thread::sleep(Duration::from_secs(3));
            let now = signature();
            if now != last {
                last = now;
                if dtx.send(Msg::DisplaysChanged).is_err() {
                    return;
                }
            }
        }
    });

    let mut d = Daemon {
        tx: tx.clone(),
        settings,
        displays: Vec::new(),
        sink: None,
        worker,
        keys,
        tray: None,
        notifier: Notifier::new(),
        warned: Vec::new(),
    };
    d.apply_policy();
    if !d.settings.tray_hidden {
        d.show_tray();
    }
    let first_run = !config::state_dir().join("welcomed").exists();
    if first_run {
        let _ = std::fs::create_dir_all(config::state_dir());
        let _ = std::fs::write(config::state_dir().join("welcomed"), "");
        d.notifier.message(
            t("Glint is running"),
            t("Brightness keys (or Ctrl+Alt+Page Up / Page Down) and volume keys now control your monitor. Open the tray icon for settings."),
        );
    }
    if d.keys.passive() {
        glog!("input: passive (no /dev/uinput access); run `sudo glint setup` so Glint can take keys");
    }

    while let Ok(msg) = rx.recv() {
        if !d.handle(msg) {
            break;
        }
    }
    let _ = d.worker.send(Cmd::Quit);
    let _ = worker_thread.join();
    let _ = std::fs::remove_file(socket_path());
    glog!("quit");
}

impl Daemon {
    fn save(&mut self) {
        config::save(&self.settings);
        self.apply_policy();
        self.refresh_tray();
    }

    /// Recomputes which keys Glint takes. Volume routing follows the Mac rules
    /// (`logic::route_volume_keys`); without uinput Glint can't take keys, so sync mode
    /// mustn't drive the system volume on top of the desktop doing the same.
    fn apply_policy(&mut self) {
        let s = &self.settings;
        let names = self.sink.as_ref().map(|x| x.names.clone()).unwrap_or_default();
        let matches = |n: &str| names.iter().any(|e| logic::endpoint_matches_monitor(e, n));
        let passive = self.keys.passive();
        let route = logic::route_volume_keys(RouteInput {
            intercept: s.route_volume,
            always: s.always_volume,
            sync: s.sync && !passive,
            endpoint_is_display: self.sink.as_ref().is_some_and(|x| x.is_display),
            matched_capable: self.displays.iter().any(|d| d.has_volume() && matches(&d.name)),
            matched_any: self.displays.iter().any(|d| matches(&d.name)),
            any_capable: self.displays.iter().any(|d| d.has_volume()),
        });
        let mut p = self.keys.policy.lock().unwrap();
        if p.route_volume != route {
            glog!("volume keys -> {} (sink {:?})", if route { "Glint" } else { "desktop" }, names);
        }
        *p = Policy { intercept_brightness: s.intercept_brightness, hotkeys: s.hotkeys, route_volume: route };
    }

    fn show_tray(&mut self) {
        if self.tray.is_some() {
            return;
        }
        let tray = GlintTray {
            tx: self.tx.clone(),
            displays: self.displays.clone(),
            settings: self.settings.clone(),
            login: launch_at_login(),
            passive: self.keys.passive(),
        };
        // Some desktops start their tray host after Glint; ksni waits for it.
        match tray.assume_sni_available(true).spawn() {
            Ok(h) => self.tray = Some(h),
            Err(e) => glog!("tray: unavailable ({e})"),
        }
    }

    fn refresh_tray(&self) {
        if let Some(h) = &self.tray {
            let (displays, settings, login) = (self.displays.clone(), self.settings.clone(), launch_at_login());
            h.update(move |t| {
                t.displays = displays;
                t.settings = settings;
                t.login = login;
            });
        }
    }

    fn brightness(&self, dir: Direction) {
        let s = &self.settings;
        let _ = self.worker.send(Cmd::Brightness { dir, step: s.brightness_step, sync: s.sync });
    }

    fn volume(&self, action: Action) {
        let s = &self.settings;
        let endpoint = self.sink.as_ref().map(|x| x.names.clone()).unwrap_or_default();
        let sync = s.sync && !self.keys.passive();
        let _ = self.worker.send(match action {
            Action::Mute => Cmd::ToggleMute { endpoint, sync },
            Action::Volume(dir) => Cmd::Volume { endpoint, dir, step: s.volume_step, sync },
            Action::Brightness(_) => return,
        });
    }

    fn handle(&mut self, msg: Msg) -> bool {
        match msg {
            Msg::Key(Action::Brightness(dir)) => self.brightness(dir),
            Msg::Key(a) => self.volume(a),
            Msg::Worker(Out::Snapshot(displays)) => {
                self.displays = displays;
                self.apply_policy();
                self.refresh_tray();
            }
            Msg::Worker(Out::Osd { brightness, muted, percent }) => {
                if self.settings.show_osd {
                    let (label, icon) = match (brightness, muted) {
                        (true, _) => (t("Brightness"), "display-brightness-symbolic"),
                        (false, true) => (t("Muted"), "audio-volume-muted-symbolic"),
                        (false, false) => (t("Volume"), "audio-volume-high-symbolic"),
                    };
                    let summary =
                        if muted { label.to_string() } else { format!("{label} {}", logic::percent_label(percent)) };
                    self.notifier.show(&summary, icon, (!muted).then_some(percent));
                }
            }
            Msg::Worker(Out::Ignored(name)) => {
                if !self.warned.contains(&name) {
                    self.notifier.message(
                        t("Monitor isn't applying changes"),
                        &t("{} accepted the change over DDC/CI but didn't apply it. A KVM, dock or adapter may be blocking DDC/CI, or a picture mode (HDR, sRGB, eco, dynamic contrast) may lock it.").replace("{}", &name),
                    );
                    self.warned.push(name);
                }
            }
            Msg::Sink(sink) => {
                self.sink = sink;
                self.apply_policy();
            }
            Msg::DisplaysChanged => {
                glog!("display change: rescanning");
                let _ = self.worker.send(Cmd::Rescan);
            }
            Msg::Control(line, reply) => {
                let (answer, keep_running) = self.control(&line);
                let _ = reply.send(answer);
                return keep_running;
            }
            Msg::Menu(cmd) => return self.menu(cmd),
        }
        true
    }

    /// Commands from `glint <command>` (and desktop shortcuts bound to them).
    fn control(&mut self, line: &str) -> (String, bool) {
        let words: Vec<&str> = line.split_whitespace().collect();
        let parse =
            |w: Option<&&str>| w.and_then(|v| v.trim_end_matches('%').parse::<f64>().ok()).map(|v| v.clamp(0.0, 100.0));
        match words.as_slice() {
            ["show"] => {
                self.settings.tray_hidden = false;
                self.save();
                self.show_tray();
                ("ok".into(), true)
            }
            ["brightness", "up"] => {
                self.brightness(Direction::Up);
                ("ok".into(), true)
            }
            ["brightness", "down"] => {
                self.brightness(Direction::Down);
                ("ok".into(), true)
            }
            ["brightness", v] => match parse(Some(v)) {
                Some(p) => {
                    for index in 0..self.displays.len() {
                        let _ = self.worker.send(Cmd::SetBrightness { index, percent: p, all: false });
                    }
                    ("ok".into(), true)
                }
                None => ("usage: glint brightness up|down|0-100".into(), true),
            },
            ["volume", "up"] => {
                self.volume(Action::Volume(Direction::Up));
                ("ok".into(), true)
            }
            ["volume", "down"] => {
                self.volume(Action::Volume(Direction::Down));
                ("ok".into(), true)
            }
            ["volume", "mute"] => {
                self.volume(Action::Mute);
                ("ok".into(), true)
            }
            ["volume", v] => match parse(Some(v)) {
                Some(p) => {
                    for (index, d) in self.displays.iter().enumerate().filter(|(_, d)| d.has_volume()) {
                        let _ = d;
                        let _ = self.worker.send(Cmd::SetVolume { index, percent: p });
                    }
                    ("ok".into(), true)
                }
                None => ("usage: glint volume up|down|mute|0-100".into(), true),
            },
            ["rescan"] => {
                let _ = self.worker.send(Cmd::Rescan);
                ("ok".into(), true)
            }
            ["status"] => (self.status(), true),
            ["quit"] => ("ok".into(), false),
            _ => (format!("unknown command: {line}"), true),
        }
    }

    fn status(&self) -> String {
        let mut out = format!("Glint {} (running)\n", crate::VERSION);
        if self.displays.is_empty() {
            out.push_str("No displays found.\n");
        }
        for d in &self.displays {
            let f = |v: Option<f64>| v.map(logic::percent_label).unwrap_or_else(|| "n/a".into());
            out.push_str(&format!(
                "  {}{}: brightness {}, volume {}\n",
                d.name,
                if d.internal { " (built-in)" } else { "" },
                f(d.brightness),
                f(d.volume)
            ));
        }
        let p = *self.keys.policy.lock().unwrap();
        out.push_str(&format!(
            "Keys: {} · brightness {} · volume keys to {}\nSound: {}\n",
            if self.keys.passive() { "listening only (run sudo glint setup)" } else { "taken from the desktop" },
            if p.intercept_brightness { "on" } else { "off" },
            if p.route_volume { "Glint" } else { "the desktop" },
            self.sink.as_ref().map(|s| s.names.join(" / ")).unwrap_or_else(|| "no sound server".into()),
        ));
        out
    }

    fn menu(&mut self, cmd: MenuCmd) -> bool {
        match cmd {
            MenuCmd::Level { index, volume, percent } => {
                let c = if volume {
                    Cmd::SetVolume { index, percent }
                } else {
                    Cmd::SetBrightness { index, percent, all: self.settings.sync }
                };
                let _ = self.worker.send(c);
            }
            MenuCmd::InterceptBrightness => {
                self.settings.intercept_brightness = !self.settings.intercept_brightness;
                self.save();
            }
            MenuCmd::AlwaysBrightness => {
                self.settings.always_brightness = !self.settings.always_brightness;
                self.save();
                let _ = self.worker.send(Cmd::Prefs(worker_prefs(&self.settings)));
            }
            MenuCmd::Hotkeys(i) => {
                self.settings.hotkeys = HotkeyScheme::ALL[i.min(HotkeyScheme::ALL.len() - 1)];
                self.save();
            }
            MenuCmd::InterceptVolume => {
                self.settings.route_volume = !self.settings.route_volume;
                self.save();
            }
            MenuCmd::AlwaysVolume => {
                self.settings.always_volume = !self.settings.always_volume;
                self.save();
            }
            MenuCmd::WriteOnlyVolume => {
                self.settings.write_only_volume = !self.settings.write_only_volume;
                self.save();
                let _ = self.worker.send(Cmd::Prefs(worker_prefs(&self.settings)));
            }
            MenuCmd::BrightnessStep(i) => {
                self.settings.brightness_step = STEP_OPTIONS[i.min(STEP_OPTIONS.len() - 1)];
                self.save();
            }
            MenuCmd::VolumeStep(i) => {
                self.settings.volume_step = STEP_OPTIONS[i.min(STEP_OPTIONS.len() - 1)];
                self.save();
            }
            MenuCmd::Sync => {
                self.settings.sync = !self.settings.sync;
                self.save();
            }
            MenuCmd::Osd => {
                self.settings.show_osd = !self.settings.show_osd;
                self.save();
            }
            MenuCmd::LaunchAtLogin => {
                let on = !launch_at_login();
                let ok = systemctl(&[if on { "enable" } else { "disable" }, "glint.service"]);
                glog!(
                    "launch at login {} ({})",
                    if on { "on" } else { "off" },
                    if ok { "ok" } else { "systemctl failed" }
                );
                self.refresh_tray();
            }
            MenuCmd::HideTray => {
                self.settings.tray_hidden = true;
                config::save(&self.settings);
                if let Some(h) = self.tray.take() {
                    h.shutdown();
                }
                self.notifier.message(
                    t("Hide tray icon…"),
                    t("Glint keeps running without a tray icon. Run glint again, or open it from your app menu, to bring the icon back."),
                );
            }
            MenuCmd::Rescan => {
                let _ = self.worker.send(Cmd::Rescan);
            }
            MenuCmd::DebugLogging => {
                self.settings.debug_logging = !self.settings.debug_logging;
                crate::log::set_debug(self.settings.debug_logging);
                glog!("debug logging {}", if self.settings.debug_logging { "on" } else { "off" });
                self.save();
            }
            MenuCmd::OpenLog => open(&config::state_dir().display().to_string()),
            MenuCmd::Website => open(WEBSITE),
            MenuCmd::Support => open(SUPPORT),
            MenuCmd::Quit => return false,
        }
        true
    }
}
