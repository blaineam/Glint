//! DDC runs on its own thread (a transaction takes 40–100 ms). Same model as the Windows
//! worker: key presses become commands, held keys are coalesced, values are cached for 2 s,
//! the first write of each control is read back once to catch monitors that ignore it.
//!
//! Linux has no global cursor position under Wayland, so brightness keys act on every
//! display: in sync mode all move to one level (the default, as on the Mac), otherwise each
//! steps from its own level.

use std::collections::HashMap;
use std::path::Path;
use std::sync::mpsc::{Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use glint_core::logic::{self, Direction};

use crate::dbus::Logind;
use crate::drm;
use crate::i2c::Bus;
use crate::{config, edid, gdebug, glog, pactl};

const VCP_BRIGHTNESS: u8 = 0x10;
const VCP_VOLUME: u8 = 0x62;
const CACHE_TTL: Duration = Duration::from_secs(2);
const ASSUMED_START: u32 = 50;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WorkerPrefs {
    pub always_brightness: bool,
    pub write_only_volume: bool,
}

pub enum Cmd {
    Rescan,
    Prefs(WorkerPrefs),
    Brightness { dir: Direction, step: f64, sync: bool },
    SetBrightness { index: usize, percent: f64, all: bool },
    Volume { endpoint: Vec<String>, dir: Direction, step: f64, sync: bool },
    SetVolume { index: usize, percent: f64 },
    ToggleMute { endpoint: Vec<String>, sync: bool },
    Quit,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayInfo {
    pub name: String,
    pub internal: bool,
    pub brightness: Option<f64>,
    pub volume: Option<f64>,
}

impl DisplayInfo {
    pub fn has_volume(&self) -> bool {
        self.volume.is_some()
    }
}

pub enum Out {
    Osd {
        brightness: bool,
        muted: bool,
        percent: f64,
    },
    Snapshot(Vec<DisplayInfo>),
    /// A monitor accepted a DDC write but didn't apply it.
    Ignored(String),
}

#[derive(Clone, Copy)]
struct Vcp {
    cur: u32,
    max: u32,
    at: Instant,
    assumed: bool,
}

impl Vcp {
    fn read(cur: u32, max: u32) -> Vcp {
        Vcp { cur, max, at: Instant::now(), assumed: false }
    }
    fn assumed() -> Vcp {
        Vcp { cur: ASSUMED_START, max: 100, at: Instant::now(), assumed: true }
    }
    fn percent(&self) -> f64 {
        logic::raw_to_percent(self.cur, self.max)
    }
}

enum Control {
    Ddc(Bus),
    Backlight(String),
    None,
}

struct Display {
    name: String,
    key: String,
    internal: bool,
    control: Control,
    brightness: Option<Vcp>,
    volume: Option<Vcp>,
    verified: [bool; 2],
}

struct Worker {
    displays: Vec<Display>,
    prefs: WorkerPrefs,
    logind: Option<Logind>,
    logind_tried: bool,
    out: Box<dyn Fn(Out) + Send>,
}

pub fn spawn(prefs: WorkerPrefs, out: Box<dyn Fn(Out) + Send>) -> (Sender<Cmd>, thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = thread::Builder::new()
        .name("glint-ddc".into())
        .spawn(move || {
            let mut w = Worker { displays: Vec::new(), prefs, logind: None, logind_tried: false, out };
            w.run(rx);
        })
        .expect("spawning the DDC thread");
    (tx, handle)
}

fn coalesce(cmds: Vec<Cmd>) -> Vec<(Cmd, u32)> {
    let mut out: Vec<(Cmd, u32)> = Vec::new();
    for cmd in cmds {
        if let Some((last, presses)) = out.last_mut() {
            let same = match (&*last, &cmd) {
                (Cmd::Brightness { dir: a, sync: sa, .. }, Cmd::Brightness { dir: b, sync: sb, .. }) => {
                    a == b && sa == sb
                }
                (Cmd::Volume { dir: a, sync: sa, .. }, Cmd::Volume { dir: b, sync: sb, .. }) => a == b && sa == sb,
                (Cmd::SetBrightness { index: a, .. }, Cmd::SetBrightness { index: b, .. }) => a == b,
                (Cmd::SetVolume { index: a, .. }, Cmd::SetVolume { index: b, .. }) => a == b,
                (Cmd::Rescan, Cmd::Rescan) => true,
                _ => false,
            };
            if same {
                *presses += 1;
                *last = cmd;
                continue;
            }
        }
        out.push((cmd, 1));
    }
    out
}

fn pick_volume_targets(names: &[(String, bool)], endpoint: &[String]) -> Vec<usize> {
    let capable: Vec<usize> = (0..names.len()).filter(|&i| names[i].1).collect();
    let matched: Vec<usize> = capable
        .iter()
        .copied()
        .filter(|&i| endpoint.iter().any(|e| logic::endpoint_matches_monitor(e, &names[i].0)))
        .collect();
    if matched.is_empty() {
        capable
    } else {
        matched
    }
}

/// Opens each external monitor's DDC bus. Drivers that don't link a bus (NVIDIA's
/// proprietary one) are matched by reading the EDID on each candidate bus.
fn connect(sys: &Path, conns: &[drm::Connector]) -> Vec<Option<Bus>> {
    let mut buses: Vec<Option<Bus>> =
        conns.iter().map(|c| c.i2c_bus.filter(|_| !c.internal).and_then(|n| Bus::open(n).ok())).collect();
    let unmatched: Vec<usize> = (0..conns.len()).filter(|&i| !conns[i].internal && buses[i].is_none()).collect();
    if unmatched.is_empty() {
        return buses;
    }
    let linked: Vec<u32> = conns.iter().filter_map(|c| c.i2c_bus).collect();
    for n in drm::candidate_buses(sys).into_iter().filter(|n| !linked.contains(n)) {
        let Ok(mut bus) = Bus::open(n) else { continue };
        let Some(e) = bus.read_edid() else { continue };
        if let Some(&i) = unmatched.iter().find(|&&i| buses[i].is_none() && edid::same_monitor(&conns[i].edid, &e)) {
            glog!("ddc: '{}' matched to /dev/i2c-{n} by EDID", conns[i].name);
            buses[i] = Some(bus);
        }
    }
    buses
}

/// Reads brightness or volume from a display's control (DDC, or the backlight in sysfs).
fn read_control(control: &mut Control, name: &str, code: u8) -> Option<Vcp> {
    match control {
        Control::Ddc(bus) => {
            let r = bus.get_vcp(code);
            gdebug!("ddc read '{name}' 0x{code:02X}: {r:?}");
            r.ok().filter(|r| r.max > 0).map(|r| Vcp::read(r.current as u32, r.max as u32))
        }
        Control::Backlight(dev) if code == VCP_BRIGHTNESS => {
            drm::backlight_level(Path::new("/sys"), dev).map(|(c, m)| Vcp::read(c, m))
        }
        _ => None,
    }
}

impl Worker {
    fn run(&mut self, rx: Receiver<Cmd>) {
        while let Ok(first) = rx.recv() {
            let mut batch = vec![first];
            while let Ok(more) = rx.try_recv() {
                batch.push(more);
            }
            for (cmd, presses) in coalesce(batch) {
                match cmd {
                    Cmd::Quit => return,
                    Cmd::Rescan => self.rescan(),
                    Cmd::Prefs(p) => {
                        if p != self.prefs {
                            self.prefs = p;
                            self.rescan();
                        }
                    }
                    Cmd::Brightness { dir, step, sync } => self.brightness(dir, step, sync, presses),
                    Cmd::SetBrightness { index, percent, all } => self.set_brightness(index, percent, all),
                    Cmd::Volume { endpoint, dir, step, sync } => self.volume(&endpoint, dir, step, sync, presses),
                    Cmd::SetVolume { index, percent } => self.set_volume(index, percent),
                    Cmd::ToggleMute { endpoint, sync } => self.toggle_mute(&endpoint, sync),
                }
            }
        }
    }

    fn logind(&mut self) -> Option<&Logind> {
        if !self.logind_tried {
            self.logind_tried = true;
            self.logind = Logind::connect();
            glog!("logind: {}", if self.logind.is_some() { "connected" } else { "unavailable" });
        }
        self.logind.as_ref()
    }

    fn rescan(&mut self) {
        let sys = Path::new("/sys");
        let conns = drm::scan(sys);
        let buses = connect(sys, &conns);
        let backlight = drm::backlight(sys);
        self.displays.clear();
        let mut seen: HashMap<String, usize> = HashMap::new();
        for (c, bus) in conns.into_iter().zip(buses) {
            let dup = seen.entry(c.name.clone()).or_default();
            let key = logic::monitor_key(&c.name, *dup);
            *dup += 1;
            let control = match (c.internal, bus, &backlight) {
                (true, _, Some(b)) => Control::Backlight(b.clone()),
                (false, Some(bus), _) => Control::Ddc(bus),
                _ => Control::None,
            };
            let mut d = Display {
                name: c.name.clone(),
                key,
                internal: c.internal,
                control,
                brightness: None,
                volume: None,
                verified: [false; 2],
            };
            d.brightness = read_control(&mut d.control, &c.name, VCP_BRIGHTNESS);
            d.volume = read_control(&mut d.control, &c.name, VCP_VOLUME);
            if let Control::Ddc(_) = d.control {
                if d.brightness.is_none() && self.prefs.always_brightness {
                    d.brightness = Some(Vcp::assumed());
                }
                if d.volume.is_none() && self.prefs.write_only_volume {
                    d.volume = Some(Vcp::assumed());
                }
            }
            glog!(
                "display '{}' ({}) internal={} control={} brightness={:?} volume={:?}",
                d.name,
                c.connector,
                d.internal,
                match &d.control {
                    Control::Ddc(b) => format!("/dev/i2c-{}", b.number),
                    Control::Backlight(n) => format!("backlight {n}"),
                    Control::None => "none".into(),
                },
                d.brightness.map(|v| (v.cur, v.max, v.assumed)),
                d.volume.map(|v| (v.cur, v.max, v.assumed)),
            );
            self.displays.push(d);
        }
        self.publish();
    }

    fn publish(&self) {
        let infos = self
            .displays
            .iter()
            .map(|d| DisplayInfo {
                name: d.name.clone(),
                internal: d.internal,
                brightness: d.brightness.map(|v| v.percent()),
                volume: d.volume.map(|v| v.percent()),
            })
            .collect();
        (self.out)(Out::Snapshot(infos));
    }

    fn fresh(&mut self, i: usize, code: u8) -> Option<Vcp> {
        let slot = if code == VCP_BRIGHTNESS { self.displays[i].brightness } else { self.displays[i].volume };
        if let Some(v) = slot {
            if v.assumed || v.at.elapsed() < CACHE_TTL {
                return Some(v);
            }
        }
        let name = self.displays[i].name.clone();
        let read = read_control(&mut self.displays[i].control, &name, code);
        let v = read.or(slot.map(|c| Vcp { at: Instant::now(), ..c }));
        if code == VCP_BRIGHTNESS {
            self.displays[i].brightness = v;
        } else {
            self.displays[i].volume = v;
        }
        v
    }

    fn write(&mut self, i: usize, code: u8, raw: u32) -> bool {
        let name = self.displays[i].name.clone();
        let ok = match &mut self.displays[i].control {
            Control::Ddc(bus) => {
                let ok = bus.set_vcp(code, raw.min(u16::MAX as u32) as u16);
                gdebug!("ddc write '{name}' 0x{code:02X} = {raw}: ok={ok}");
                ok
            }
            Control::Backlight(dev) => {
                let dev = dev.clone();
                let ok = self.logind().map(|l| l.set_brightness(&dev, raw)).unwrap_or(false);
                gdebug!("backlight '{dev}' = {raw}: ok={ok}");
                ok
            }
            Control::None => false,
        };
        let slot = if code == VCP_BRIGHTNESS { &mut self.displays[i].brightness } else { &mut self.displays[i].volume };
        if let Some(v) = slot.as_mut() {
            if ok {
                v.cur = raw;
            }
            v.at = Instant::now();
        }
        if ok {
            self.verify(i, code, raw);
        } else {
            glog!("'{name}': write 0x{code:02X} = {raw} failed");
        }
        ok
    }

    /// Reads a DDC control back once after its first write (KVMs, docks and picture modes
    /// such as HDR can make a monitor accept a write and ignore it).
    fn verify(&mut self, i: usize, code: u8, wanted: u32) {
        let slot = if code == VCP_BRIGHTNESS { 0 } else { 1 };
        let d = &self.displays[i];
        let assumed = if slot == 0 { d.brightness } else { d.volume }.is_some_and(|v| v.assumed);
        if d.verified[slot] || assumed || !matches!(d.control, Control::Ddc(_)) {
            return;
        }
        self.displays[i].verified[slot] = true;
        thread::sleep(Duration::from_millis(80));
        let name = self.displays[i].name.clone();
        let back = match &mut self.displays[i].control {
            Control::Ddc(bus) => bus.get_vcp(code).ok().map(|r| r.current as u32),
            _ => None,
        };
        match logic::write_took(wanted, back) {
            Some(true) => glog!("'{name}' applied DDC 0x{code:02X} = {wanted}"),
            Some(false) => {
                glog!("'{name}' accepted DDC 0x{code:02X} = {wanted} but still reports {back:?}: a picture mode (HDR, sRGB, eco, dynamic contrast) may lock it, or something between the PC and the monitor drops DDC/CI writes");
                (self.out)(Out::Ignored(name));
            }
            None => glog!("'{name}': couldn't read DDC 0x{code:02X} back after writing {wanted}"),
        }
    }

    fn brightness(&mut self, dir: Direction, step: f64, sync: bool, presses: u32) {
        let indices: Vec<usize> = (0..self.displays.len()).collect();
        let levels: Vec<(usize, Vcp)> =
            indices.iter().filter_map(|&i| self.fresh(i, VCP_BRIGHTNESS).map(|v| (i, v))).collect();
        let Some(&(_, base)) = levels.iter().find(|(i, _)| !self.displays[*i].internal).or(levels.first()) else {
            glog!("brightness: no display answered");
            return;
        };
        let shown = if sync {
            let pct = logic::step_percent(base.percent(), step, dir, presses);
            for (i, v) in levels {
                self.write(i, VCP_BRIGHTNESS, logic::percent_to_raw(pct, v.max));
            }
            pct
        } else {
            let mut first = None;
            for (i, v) in levels {
                let raw = logic::step_raw(v.cur, v.max, step, dir, presses);
                self.write(i, VCP_BRIGHTNESS, raw);
                first.get_or_insert(logic::raw_to_percent(raw, v.max));
            }
            first.unwrap_or(0.0)
        };
        (self.out)(Out::Osd { brightness: true, muted: false, percent: shown });
        self.publish();
    }

    fn set_brightness(&mut self, index: usize, percent: f64, all: bool) {
        if index >= self.displays.len() {
            return;
        }
        let targets: Vec<usize> = if all { (0..self.displays.len()).collect() } else { vec![index] };
        for i in targets {
            if let Some(v) = self.fresh(i, VCP_BRIGHTNESS) {
                self.write(i, VCP_BRIGHTNESS, logic::percent_to_raw(percent, v.max));
            }
        }
        self.publish();
    }

    fn volume_targets(&self, endpoint: &[String]) -> Vec<usize> {
        let names: Vec<(String, bool)> = self.displays.iter().map(|d| (d.name.clone(), d.volume.is_some())).collect();
        pick_volume_targets(&names, endpoint)
    }

    fn all_volume(&self) -> Vec<usize> {
        (0..self.displays.len()).filter(|&i| self.displays[i].volume.is_some()).collect()
    }

    fn volume(&mut self, endpoint: &[String], dir: Direction, step: f64, sync: bool, presses: u32) {
        if sync {
            // Mac sync mode: the system volume and every monitor's speakers move together,
            // starting from the system level.
            let displays = self.all_volume();
            let system = pactl::default_sink().and_then(|s| s.volume);
            let base = system
                .or_else(|| displays.first().and_then(|&i| self.fresh(i, VCP_VOLUME)).map(|v| v.percent()))
                .unwrap_or(ASSUMED_START as f64);
            let pct = logic::step_percent(base, step, dir, presses);
            pactl::set_volume(pct);
            if dir == Direction::Up {
                pactl::set_mute(false);
            }
            for i in displays {
                if let Some(v) = self.fresh(i, VCP_VOLUME) {
                    self.write(i, VCP_VOLUME, logic::percent_to_raw(pct, v.max));
                }
            }
            (self.out)(Out::Osd { brightness: false, muted: pct == 0.0, percent: pct });
            self.publish();
            return;
        }
        let mut shown = None;
        for i in self.volume_targets(endpoint) {
            if let Some(v) = self.fresh(i, VCP_VOLUME) {
                let raw = logic::step_raw(v.cur, v.max, step, dir, presses);
                self.write(i, VCP_VOLUME, raw);
                shown.get_or_insert(logic::raw_to_percent(raw, v.max));
            }
        }
        if let Some(p) = shown {
            (self.out)(Out::Osd { brightness: false, muted: p == 0.0, percent: p });
            self.publish();
        }
    }

    fn set_volume(&mut self, index: usize, percent: f64) {
        if index < self.displays.len() {
            if let Some(v) = self.fresh(index, VCP_VOLUME) {
                self.write(index, VCP_VOLUME, logic::percent_to_raw(percent, v.max));
                self.publish();
            }
        }
    }

    fn toggle_mute(&mut self, endpoint: &[String], sync: bool) {
        let targets = if sync { self.all_volume() } else { self.volume_targets(endpoint) };
        let current: Vec<(usize, Vcp)> =
            targets.iter().filter_map(|&i| self.fresh(i, VCP_VOLUME).map(|v| (i, v))).collect();
        let sink = if sync { pactl::default_sink() } else { None };
        if current.is_empty() && sink.is_none() {
            return;
        }
        let mut levels: Vec<u32> = current.iter().map(|(_, v)| v.cur).collect();
        if sink.as_ref().is_some_and(|s| !s.muted) {
            levels.push(1);
        }
        let mute = logic::should_mute(&levels);
        let mut shown = 0.0;
        for (i, v) in current {
            let key = self.displays[i].key.clone();
            if mute {
                if v.cur > 0 {
                    config::set_pre_mute_volume(&key, v.cur);
                }
                self.write(i, VCP_VOLUME, 0);
            } else {
                let raw = logic::unmute_raw(config::pre_mute_volume(&key), v.max);
                self.write(i, VCP_VOLUME, raw);
                shown = logic::raw_to_percent(raw, v.max);
            }
        }
        if let Some(s) = sink {
            pactl::set_mute(mute);
            if !mute {
                shown = s.volume.unwrap_or(shown);
            }
        }
        glog!("mute: -> {}", if mute { "muted" } else { "unmuted" });
        (self.out)(Out::Osd { brightness: false, muted: mute, percent: shown });
        self.publish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesce_merges_held_keys() {
        let b = |dir| Cmd::Brightness { dir, step: 5.0, sync: true };
        let out = coalesce(vec![b(Direction::Up), b(Direction::Up), b(Direction::Down), Cmd::Rescan, Cmd::Rescan]);
        let presses: Vec<u32> = out.iter().map(|(_, p)| *p).collect();
        assert_eq!(presses, vec![2, 1, 2]);
    }

    #[test]
    fn volume_targets_prefer_the_playing_monitor() {
        let names =
            vec![("DELL U2720Q".to_string(), true), ("LG HDR 4K".to_string(), true), ("Panel".to_string(), false)];
        assert_eq!(pick_volume_targets(&names, &["DELL U2720Q".into()]), vec![0]);
        assert_eq!(pick_volume_targets(&names, &["Speakers".into()]), vec![0, 1]);
    }
}
