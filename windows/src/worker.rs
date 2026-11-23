//! DDC runs on its own thread: a DDC/CI transaction takes 40–100 ms, far too long for the
//! keyboard hook or the UI thread. Key presses become commands; bursts (holding a key) are
//! coalesced so the monitor gets one write per burst instead of a queue of stale ones.

use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

use crate::audio::Audio;
use crate::ddc::{self, Monitor, VCP_BRIGHTNESS, VCP_VOLUME};
use crate::glog;
use crate::logic::{self, Direction};
use crate::settings;
use crate::wmi::Wmi;

pub const WM_APP_OSD: u32 = 0x8000 + 10;
pub const WM_APP_SNAPSHOT: u32 = 0x8000 + 11;

pub const OSD_BRIGHTNESS: usize = 0;
pub const OSD_VOLUME: usize = 1;
pub const OSD_MUTED: usize = 2;

/// Cached DDC values are trusted this long after Glint last wrote or read them; after
/// that they're re-read, in case the monitor's own buttons changed them.
const CACHE_TTL: Duration = Duration::from_secs(2);
/// Where an assumed (write-only) value starts, as on the Mac.
const ASSUMED_START: u32 = 50;

/// The settings the DDC thread needs (sent whenever they change).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WorkerPrefs {
    /// Monitors that accept DDC brightness writes but don't answer reads start at an
    /// assumed 50% and are tracked in memory.
    pub always_brightness: bool,
    /// The same for volume (the Mac's "Write-only volume").
    pub write_only_volume: bool,
}

pub enum Cmd {
    Rescan,
    Prefs(WorkerPrefs),
    Brightness {
        point: (i32, i32),
        dir: Direction,
        step: f64,
        sync: bool,
        /// From a hardware brightness key, which Windows already applies to a built-in panel.
        skip_internal: bool,
    },
    SetBrightness {
        index: usize,
        percent: f64,
        /// Sync mode: every display follows.
        all: bool,
    },
    Volume {
        endpoint: Vec<String>,
        dir: Direction,
        step: f64,
        /// Sync mode: every monitor's speakers and Windows' own volume move together.
        sync: bool,
    },
    SetVolume {
        index: usize,
        percent: f64,
    },
    ToggleMute {
        endpoint: Vec<String>,
        sync: bool,
    },
    Quit,
}

/// What the UI thread needs to know about each display (tray menu, tooltip, routing).
#[derive(Clone, Debug)]
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

pub type Snapshot = Arc<Mutex<Vec<DisplayInfo>>>;

#[derive(Clone, Copy)]
struct Vcp {
    cur: u32,
    max: u32,
    at: Instant,
    /// Never read back from the monitor (write-only); Glint's own value is the truth.
    assumed: bool,
}

impl Vcp {
    fn read(cur: u32, max: u32) -> Vcp {
        Vcp {
            cur,
            max,
            at: Instant::now(),
            assumed: false,
        }
    }

    fn assumed() -> Vcp {
        Vcp {
            cur: ASSUMED_START,
            max: 100,
            at: Instant::now(),
            assumed: true,
        }
    }

    fn percent(&self) -> f64 {
        logic::raw_to_percent(self.cur, self.max)
    }
}

struct Display {
    mon: Monitor,
    key: String,
    brightness: Option<Vcp>,
    volume: Option<Vcp>,
}

struct Worker {
    hwnd: isize,
    displays: Vec<Display>,
    prefs: WorkerPrefs,
    wmi: Option<Wmi>,
    wmi_tried: bool,
    audio: Option<Audio>,
    snapshot: Snapshot,
}

pub fn spawn(hwnd: HWND, snapshot: Snapshot, prefs: WorkerPrefs) -> (Sender<Cmd>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel();
    let hwnd = hwnd.0 as isize;
    let handle = std::thread::Builder::new()
        .name("glint-ddc".into())
        .spawn(move || {
            // SAFETY: paired with CoUninitialize below on this thread.
            let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            let mut w = Worker {
                hwnd,
                displays: Vec::new(),
                prefs,
                wmi: None,
                wmi_tried: false,
                audio: Audio::new(),
                snapshot,
            };
            w.run(rx);
            w.displays.clear();
            w.wmi = None;
            w.audio = None;
            // SAFETY: matches CoInitializeEx above.
            unsafe { CoUninitialize() };
        })
        .expect("spawning the DDC thread");
    (tx, handle)
}

/// Merges a burst of commands: consecutive adjustments of the same kind and direction add
/// up their presses; consecutive rescans run once.
fn coalesce(cmds: Vec<Cmd>) -> Vec<(Cmd, u32)> {
    let mut out: Vec<(Cmd, u32)> = Vec::new();
    for cmd in cmds {
        if let Some((last, presses)) = out.last_mut() {
            let same = match (&*last, &cmd) {
                (Cmd::Brightness { dir: a, sync: sa, .. }, Cmd::Brightness { dir: b, sync: sb, .. }) => {
                    a == b && sa == sb
                }
                (Cmd::Volume { dir: a, sync: sa, .. }, Cmd::Volume { dir: b, sync: sb, .. }) => a == b && sa == sb,
                // Dragging through menu levels: only the last one matters.
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

/// Displays whose speakers the volume keys drive: the ones Windows plays through when the
/// names match, otherwise every display with DDC volume. Pure so it can be tested.
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
                    Cmd::Brightness {
                        point,
                        dir,
                        step,
                        sync,
                        skip_internal,
                    } => self.brightness(point, dir, step, sync, skip_internal, presses),
                    Cmd::SetBrightness { index, percent, all } => self.set_brightness(index, percent, all),
                    Cmd::Volume {
                        endpoint,
                        dir,
                        step,
                        sync,
                    } => self.volume(&endpoint, dir, step, sync, presses),
                    Cmd::SetVolume { index, percent } => self.set_volume(index, percent),
                    Cmd::ToggleMute { endpoint, sync } => self.toggle_mute(&endpoint, sync),
                }
            }
        }
    }

    fn post(&self, msg: u32, w: usize, l: isize) {
        // SAFETY: posting to our own window; the handle outlives the worker.
        let _ = unsafe { PostMessageW(Some(HWND(self.hwnd as *mut _)), msg, WPARAM(w), LPARAM(l)) };
    }

    fn osd(&self, kind: usize, percent: f64) {
        self.post(WM_APP_OSD, kind, (percent * 100.0).round() as isize);
    }

    fn wmi(&mut self) -> Option<&Wmi> {
        if !self.wmi_tried {
            self.wmi_tried = true;
            self.wmi = Wmi::connect();
            glog!("wmi: {}", if self.wmi.is_some() { "connected" } else { "unavailable" });
        }
        self.wmi.as_ref()
    }

    fn rescan(&mut self) {
        self.displays.clear();
        let mons = ddc::enumerate();
        let mut seen: Vec<String> = Vec::new();
        for mon in mons {
            let dup = seen.iter().filter(|n| **n == mon.name).count();
            seen.push(mon.name.clone());
            let key = logic::monitor_key(&mon.name, dup);
            let (brightness, volume) = if mon.internal {
                let b = self.wmi().and_then(|w| w.brightness()).map(|cur| Vcp::read(cur, 100));
                (b, None)
            } else {
                let has_ddc = !mon.physical.is_empty();
                let b = ddc::read_vcp(&mon, VCP_BRIGHTNESS)
                    .map(|(cur, max)| Vcp::read(cur, max))
                    .or_else(|| (has_ddc && self.prefs.always_brightness).then(Vcp::assumed));
                let v = ddc::read_vcp(&mon, VCP_VOLUME)
                    .map(|(cur, max)| Vcp::read(cur, max))
                    .or_else(|| (has_ddc && self.prefs.write_only_volume).then(Vcp::assumed));
                (b, v)
            };
            glog!(
                "display '{}' internal={} ddc_handles={} brightness={:?} volume={:?}",
                mon.name,
                mon.internal,
                mon.physical.len(),
                brightness.map(|v| (v.cur, v.max, v.assumed)),
                volume.map(|v| (v.cur, v.max, v.assumed))
            );
            self.displays.push(Display {
                mon,
                key,
                brightness,
                volume,
            });
        }
        self.publish();
    }

    fn publish(&self) {
        let infos = self
            .displays
            .iter()
            .map(|d| DisplayInfo {
                name: d.mon.name.clone(),
                internal: d.mon.internal,
                brightness: d.brightness.map(|v| v.percent()),
                volume: d.volume.map(|v| v.percent()),
            })
            .collect();
        if let Ok(mut s) = self.snapshot.lock() {
            *s = infos;
        }
        self.post(WM_APP_SNAPSHOT, 0, 0);
    }

    fn display_at(&self, (x, y): (i32, i32)) -> Option<usize> {
        let p = POINT { x, y };
        self.displays.iter().position(|d| {
            p.x >= d.mon.rect.left && p.x < d.mon.rect.right && p.y >= d.mon.rect.top && p.y < d.mon.rect.bottom
        })
    }

    // ---- Brightness ----

    /// Current brightness, re-read when the cache is stale (never for assumed values).
    fn fresh_brightness(&mut self, i: usize) -> Option<Vcp> {
        let cached = self.displays[i].brightness;
        if let Some(v) = cached {
            if v.assumed || v.at.elapsed() < CACHE_TTL {
                return Some(v);
            }
        }
        let read = if self.displays[i].mon.internal {
            self.wmi().and_then(|w| w.brightness()).map(|cur| Vcp::read(cur, 100))
        } else {
            ddc::read_vcp(&self.displays[i].mon, VCP_BRIGHTNESS).map(|(cur, max)| Vcp::read(cur, max))
        };
        // A failed re-read keeps the last known value (some monitors answer writes but
        // drop reads); a display never read stays unsupported unless "always" is on.
        let v = read.or(cached.map(|c| Vcp {
            at: Instant::now(),
            ..c
        }));
        self.displays[i].brightness = v;
        v
    }

    fn write_brightness(&mut self, i: usize, raw: u32) -> bool {
        let ok = if self.displays[i].mon.internal {
            self.wmi().map(|w| w.set_brightness(raw)).unwrap_or(false)
        } else {
            ddc::write_vcp(&self.displays[i].mon, VCP_BRIGHTNESS, raw)
        };
        if let Some(v) = self.displays[i].brightness.as_mut() {
            if ok {
                v.cur = raw;
            }
            v.at = Instant::now();
        }
        ok
    }

    fn brightness(
        &mut self,
        point: (i32, i32),
        dir: Direction,
        step: f64,
        sync: bool,
        skip_internal: bool,
        presses: u32,
    ) {
        let Some(target) = self.display_at(point) else { return };
        if skip_internal && self.displays[target].mon.internal && !sync {
            return;
        }
        // Sync mode (Mac behaviour): every display moves to the cursor display's level.
        let base = if skip_internal && self.displays[target].mon.internal {
            None
        } else {
            self.fresh_brightness(target)
        };
        let base = base.or_else(|| {
            if sync {
                (0..self.displays.len()).find_map(|i| {
                    (!(skip_internal && self.displays[i].mon.internal))
                        .then(|| self.fresh_brightness(i))
                        .flatten()
                })
            } else {
                None
            }
        });
        let Some(cur) = base else {
            glog!("brightness: '{}' has no DDC brightness", self.displays[target].mon.name);
            return;
        };
        let mut failed = false;
        let shown;
        if sync {
            let pct = logic::step_percent(cur.percent(), step, dir, presses);
            for i in 0..self.displays.len() {
                if skip_internal && self.displays[i].mon.internal {
                    continue;
                }
                if let Some(v) = self.fresh_brightness(i) {
                    failed |= !self.write_brightness(i, logic::percent_to_raw(pct, v.max));
                }
            }
            shown = pct;
        } else {
            let raw = logic::step_raw(cur.cur, cur.max, step, dir, presses);
            failed = !self.write_brightness(target, raw);
            shown = logic::raw_to_percent(raw, cur.max);
        }
        self.osd(OSD_BRIGHTNESS, shown);
        self.publish();
        if failed {
            glog!("brightness: write failed, rescanning");
            self.rescan();
        }
    }

    fn set_brightness(&mut self, index: usize, percent: f64, all: bool) {
        if index >= self.displays.len() {
            return;
        }
        let targets: Vec<usize> = if all {
            (0..self.displays.len()).collect()
        } else {
            vec![index]
        };
        for i in targets {
            if let Some(v) = self.fresh_brightness(i) {
                if !self.write_brightness(i, logic::percent_to_raw(percent, v.max)) {
                    glog!("set brightness: write failed on '{}'", self.displays[i].mon.name);
                }
            }
        }
        self.publish();
    }

    // ---- Volume ----

    fn volume_targets(&self, endpoint: &[String]) -> Vec<usize> {
        let names: Vec<(String, bool)> = self
            .displays
            .iter()
            .map(|d| (d.mon.name.clone(), d.volume.is_some()))
            .collect();
        pick_volume_targets(&names, endpoint)
    }

    fn all_volume_displays(&self) -> Vec<usize> {
        (0..self.displays.len())
            .filter(|&i| self.displays[i].volume.is_some())
            .collect()
    }

    fn fresh_volume(&mut self, i: usize) -> Option<Vcp> {
        let cached = self.displays[i].volume;
        if let Some(v) = cached {
            if v.assumed || v.at.elapsed() < CACHE_TTL {
                return Some(v);
            }
        }
        let read = ddc::read_vcp(&self.displays[i].mon, VCP_VOLUME).map(|(cur, max)| Vcp::read(cur, max));
        let v = read.or(cached.map(|c| Vcp {
            at: Instant::now(),
            ..c
        }));
        self.displays[i].volume = v;
        v
    }

    fn write_volume(&mut self, i: usize, raw: u32) -> bool {
        let ok = ddc::write_vcp(&self.displays[i].mon, VCP_VOLUME, raw);
        if !ok {
            glog!("volume: write failed on '{}'", self.displays[i].mon.name);
        }
        if let Some(v) = self.displays[i].volume.as_mut() {
            if ok {
                v.cur = raw;
            }
            v.at = Instant::now();
        }
        ok
    }

    fn volume(&mut self, endpoint: &[String], dir: Direction, step: f64, sync: bool, presses: u32) {
        if sync {
            // Mac sync mode: Windows' volume and every monitor's speakers move in lockstep,
            // starting from Windows' level.
            let displays = self.all_volume_displays();
            let system = self.audio.as_ref().and_then(|a| a.system_volume());
            let base = system
                .or_else(|| {
                    displays
                        .first()
                        .and_then(|&i| self.fresh_volume(i))
                        .map(|v| v.percent())
                })
                .unwrap_or(ASSUMED_START as f64);
            let pct = logic::step_percent(base, step, dir, presses);
            if let Some(a) = &self.audio {
                a.set_system_volume(pct);
                if dir == Direction::Up {
                    a.set_system_mute(false);
                }
            }
            for i in displays {
                if let Some(v) = self.fresh_volume(i) {
                    self.write_volume(i, logic::percent_to_raw(pct, v.max));
                }
            }
            self.osd(if pct == 0.0 { OSD_MUTED } else { OSD_VOLUME }, pct);
            self.publish();
            return;
        }
        let mut shown = None;
        for i in self.volume_targets(endpoint) {
            if let Some(v) = self.fresh_volume(i) {
                let raw = logic::step_raw(v.cur, v.max, step, dir, presses);
                self.write_volume(i, raw);
                shown.get_or_insert(logic::raw_to_percent(raw, v.max));
            }
        }
        if let Some(p) = shown {
            self.osd(if p == 0.0 { OSD_MUTED } else { OSD_VOLUME }, p);
            self.publish();
        }
    }

    fn set_volume(&mut self, index: usize, percent: f64) {
        if index >= self.displays.len() {
            return;
        }
        if let Some(v) = self.fresh_volume(index) {
            self.write_volume(index, logic::percent_to_raw(percent, v.max));
            self.publish();
        }
    }

    fn toggle_mute(&mut self, endpoint: &[String], sync: bool) {
        let targets = if sync {
            self.all_volume_displays()
        } else {
            self.volume_targets(endpoint)
        };
        let current: Vec<(usize, Vcp)> = targets
            .iter()
            .filter_map(|&i| self.fresh_volume(i).map(|v| (i, v)))
            .collect();
        let system_muted = if sync {
            self.audio.as_ref().and_then(|a| a.system_muted())
        } else {
            None
        };
        if current.is_empty() && system_muted.is_none() {
            return;
        }
        // One decision for everything Glint controls: anything audible → mute all.
        let mut levels: Vec<u32> = current.iter().map(|(_, v)| v.cur).collect();
        if system_muted == Some(false) {
            levels.push(1);
        }
        let mute = logic::should_mute(&levels);
        let mut shown = 0.0;
        for (i, v) in current {
            let key = self.displays[i].key.clone();
            if mute {
                if v.cur > 0 {
                    settings::set_pre_mute_volume(&key, v.cur);
                }
                self.write_volume(i, 0);
            } else {
                let raw = logic::unmute_raw(settings::pre_mute_volume(&key), v.max);
                self.write_volume(i, raw);
                shown = logic::raw_to_percent(raw, v.max);
            }
        }
        if system_muted.is_some() {
            if let Some(a) = &self.audio {
                a.set_system_mute(mute);
                if !mute {
                    shown = a.system_volume().unwrap_or(shown);
                }
            }
        }
        glog!("mute: -> {}", if mute { "muted" } else { "unmuted" });
        self.osd(if mute { OSD_MUTED } else { OSD_VOLUME }, shown);
        self.publish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bright(x: i32, dir: Direction) -> Cmd {
        Cmd::Brightness {
            point: (x, x),
            dir,
            step: 5.0,
            sync: false,
            skip_internal: false,
        }
    }

    fn vol(dir: Direction) -> Cmd {
        Cmd::Volume {
            endpoint: vec![],
            dir,
            step: 5.0,
            sync: false,
        }
    }

    #[test]
    fn coalesce_merges_held_keys() {
        let cmds = vec![
            bright(0, Direction::Up),
            bright(1, Direction::Up),
            bright(2, Direction::Down),
            vol(Direction::Up),
            vol(Direction::Up),
            Cmd::Rescan,
            Cmd::Rescan,
        ];
        let out = coalesce(cmds);
        let presses: Vec<u32> = out.iter().map(|(_, p)| *p).collect();
        assert_eq!(presses, vec![2, 1, 2, 2]); // the merged rescans run once
        assert!(matches!(out[0].0, Cmd::Brightness { point: (1, 1), .. }));
    }

    #[test]
    fn coalesce_keeps_mute_separate() {
        let cmds = vec![
            Cmd::ToggleMute {
                endpoint: vec![],
                sync: false,
            },
            Cmd::ToggleMute {
                endpoint: vec![],
                sync: false,
            },
        ];
        assert_eq!(coalesce(cmds).len(), 2);
    }

    #[test]
    fn coalesce_keeps_last_menu_level() {
        let cmds = vec![
            Cmd::SetVolume {
                index: 0,
                percent: 10.0,
            },
            Cmd::SetVolume {
                index: 0,
                percent: 40.0,
            },
            Cmd::SetVolume {
                index: 1,
                percent: 70.0,
            },
        ];
        let out = coalesce(cmds);
        assert_eq!(out.len(), 2);
        assert!(matches!(out[0].0, Cmd::SetVolume { index: 0, percent } if percent == 40.0));
    }

    #[test]
    fn volume_targets_prefer_the_playing_monitor() {
        let names = vec![
            ("DELL U2720Q".to_string(), true),
            ("LG HDR 4K".to_string(), true),
            ("Built-in display".to_string(), false),
        ];
        assert_eq!(
            pick_volume_targets(&names, &["LG HDR 4K (NVIDIA High Definition Audio)".into()]),
            vec![1]
        );
        // No name match: every capable monitor.
        assert_eq!(pick_volume_targets(&names, &["Speakers".into()]), vec![0, 1]);
        assert_eq!(pick_volume_targets(&names, &[]), vec![0, 1]);
    }

    #[test]
    fn assumed_values_start_at_half() {
        let v = Vcp::assumed();
        assert!(v.assumed);
        assert_eq!(v.percent(), 50.0);
    }
}
