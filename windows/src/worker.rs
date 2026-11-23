//! DDC runs on its own thread: a DDC/CI transaction takes 40–100 ms, far too long for the
//! keyboard hook or the UI thread. Key presses become commands; bursts (holding a key) are
//! coalesced so the monitor gets one write per burst instead of a queue of stale ones.

use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

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

pub enum Cmd {
    Rescan,
    Brightness {
        point: (i32, i32),
        dir: Direction,
        step: f64,
        sync: bool,
    },
    SetBrightness {
        index: usize,
        percent: f64,
    },
    Volume {
        endpoint: Vec<String>,
        dir: Direction,
        step: f64,
    },
    ToggleMute {
        endpoint: Vec<String>,
    },
    Quit,
}

/// What the UI thread needs to know about each display (tray menu, tooltip, routing).
#[derive(Clone, Debug)]
pub struct DisplayInfo {
    pub name: String,
    pub brightness: Option<f64>,
    pub has_volume: bool,
}

pub type Snapshot = Arc<Mutex<Vec<DisplayInfo>>>;

#[derive(Clone, Copy)]
struct Vcp {
    cur: u32,
    max: u32,
    at: Instant,
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
    wmi: Option<Wmi>,
    wmi_tried: bool,
    snapshot: Snapshot,
}

pub fn spawn(hwnd: HWND, snapshot: Snapshot) -> (Sender<Cmd>, std::thread::JoinHandle<()>) {
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
                wmi: None,
                wmi_tried: false,
                snapshot,
            };
            w.run(rx);
            w.displays.clear();
            w.wmi = None;
            // SAFETY: matches CoInitializeEx above.
            unsafe { CoUninitialize() };
        })
        .expect("spawning the DDC thread");
    (tx, handle)
}

/// Merges a burst of commands: consecutive adjustments of the same kind and direction add
/// up their presses; a Rescan or Quit anywhere wins.
fn coalesce(cmds: Vec<Cmd>) -> Vec<(Cmd, u32)> {
    let mut out: Vec<(Cmd, u32)> = Vec::new();
    for cmd in cmds {
        if let Some((last, presses)) = out.last_mut() {
            let same = match (&*last, &cmd) {
                (Cmd::Brightness { dir: a, sync: sa, .. }, Cmd::Brightness { dir: b, sync: sb, .. }) => {
                    a == b && sa == sb
                }
                (Cmd::Volume { dir: a, .. }, Cmd::Volume { dir: b, .. }) => a == b,
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
                    Cmd::Brightness { point, dir, step, sync } => self.brightness(point, dir, step, sync, presses),
                    Cmd::SetBrightness { index, percent } => self.set_brightness(index, percent),
                    Cmd::Volume { endpoint, dir, step } => self.volume(&endpoint, dir, step, presses),
                    Cmd::ToggleMute { endpoint } => self.toggle_mute(&endpoint),
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
            let now = Instant::now();
            let (brightness, volume) = if mon.internal {
                let b = self
                    .wmi()
                    .and_then(|w| w.brightness())
                    .map(|cur| Vcp { cur, max: 100, at: now });
                (b, None)
            } else {
                let b = ddc::read_vcp(&mon, VCP_BRIGHTNESS).map(|(cur, max)| Vcp { cur, max, at: now });
                let v = ddc::read_vcp(&mon, VCP_VOLUME).map(|(cur, max)| Vcp { cur, max, at: now });
                (b, v)
            };
            glog!(
                "display '{}' internal={} ddc_handles={} brightness={:?} volume={:?}",
                mon.name,
                mon.internal,
                mon.physical.len(),
                brightness.map(|v| (v.cur, v.max)),
                volume.map(|v| (v.cur, v.max))
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
                brightness: d.brightness.map(|v| logic::raw_to_percent(v.cur, v.max)),
                has_volume: d.volume.is_some(),
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

    /// Current brightness, re-read when the cache is stale.
    fn fresh_brightness(&mut self, i: usize) -> Option<Vcp> {
        let cached = self.displays[i].brightness;
        if let Some(v) = cached {
            if v.at.elapsed() < CACHE_TTL {
                return Some(v);
            }
        }
        let now = Instant::now();
        let read = if self.displays[i].mon.internal {
            self.wmi()
                .and_then(|w| w.brightness())
                .map(|cur| Vcp { cur, max: 100, at: now })
        } else {
            ddc::read_vcp(&self.displays[i].mon, VCP_BRIGHTNESS).map(|(cur, max)| Vcp { cur, max, at: now })
        };
        // A failed re-read keeps the last known value (some monitors answer writes but
        // drop reads); a display never read stays unsupported.
        let v = read.or(cached.map(|c| Vcp { at: now, ..c }));
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

    fn brightness(&mut self, point: (i32, i32), dir: Direction, step: f64, sync: bool, presses: u32) {
        let Some(target) = self.display_at(point) else { return };
        let Some(cur) = self.fresh_brightness(target) else {
            glog!("brightness: '{}' has no DDC brightness", self.displays[target].mon.name);
            return;
        };
        let mut failed = false;
        let shown;
        if sync {
            let pct = logic::step_percent(logic::raw_to_percent(cur.cur, cur.max), step, dir, presses);
            for i in 0..self.displays.len() {
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

    fn set_brightness(&mut self, index: usize, percent: f64) {
        if index >= self.displays.len() {
            return;
        }
        if let Some(v) = self.fresh_brightness(index) {
            if !self.write_brightness(index, logic::percent_to_raw(percent, v.max)) {
                glog!("set brightness: write failed on '{}'", self.displays[index].mon.name);
            }
            self.publish();
        }
    }

    /// Displays whose speakers the volume keys drive: the one Windows plays through when
    /// its name matches, otherwise every external display with DDC volume.
    fn volume_targets(&self, endpoint: &[String]) -> Vec<usize> {
        let capable: Vec<usize> = (0..self.displays.len())
            .filter(|&i| self.displays[i].volume.is_some())
            .collect();
        let matched: Vec<usize> = capable
            .iter()
            .copied()
            .filter(|&i| {
                endpoint
                    .iter()
                    .any(|e| logic::endpoint_matches_monitor(e, &self.displays[i].mon.name))
            })
            .collect();
        if matched.is_empty() {
            capable
        } else {
            matched
        }
    }

    fn fresh_volume(&mut self, i: usize) -> Option<Vcp> {
        let cached = self.displays[i].volume;
        if let Some(v) = cached {
            if v.at.elapsed() < CACHE_TTL {
                return Some(v);
            }
        }
        let now = Instant::now();
        let read = ddc::read_vcp(&self.displays[i].mon, VCP_VOLUME).map(|(cur, max)| Vcp { cur, max, at: now });
        let v = read.or(cached.map(|c| Vcp { at: now, ..c }));
        self.displays[i].volume = v;
        v
    }

    fn write_volume(&mut self, i: usize, raw: u32) -> bool {
        let ok = ddc::write_vcp(&self.displays[i].mon, VCP_VOLUME, raw);
        if let Some(v) = self.displays[i].volume.as_mut() {
            if ok {
                v.cur = raw;
            }
            v.at = Instant::now();
        }
        ok
    }

    fn volume(&mut self, endpoint: &[String], dir: Direction, step: f64, presses: u32) {
        let targets = self.volume_targets(endpoint);
        let mut shown = None;
        for i in targets {
            if let Some(v) = self.fresh_volume(i) {
                let raw = logic::step_raw(v.cur, v.max, step, dir, presses);
                if !self.write_volume(i, raw) {
                    glog!("volume: write failed on '{}'", self.displays[i].mon.name);
                }
                shown.get_or_insert(logic::raw_to_percent(raw, v.max));
            }
        }
        if let Some(p) = shown {
            self.osd(if p == 0.0 { OSD_MUTED } else { OSD_VOLUME }, p);
        }
    }

    fn toggle_mute(&mut self, endpoint: &[String]) {
        let targets = self.volume_targets(endpoint);
        let current: Vec<(usize, Vcp)> = targets
            .iter()
            .filter_map(|&i| self.fresh_volume(i).map(|v| (i, v)))
            .collect();
        if current.is_empty() {
            return;
        }
        let levels: Vec<u32> = current.iter().map(|(_, v)| v.cur).collect();
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
        glog!("mute: -> {}", if mute { "muted" } else { "unmuted" });
        self.osd(if mute { OSD_MUTED } else { OSD_VOLUME }, shown);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesce_merges_held_keys() {
        let cmds = vec![
            Cmd::Brightness {
                point: (0, 0),
                dir: Direction::Up,
                step: 5.0,
                sync: false,
            },
            Cmd::Brightness {
                point: (1, 1),
                dir: Direction::Up,
                step: 5.0,
                sync: false,
            },
            Cmd::Brightness {
                point: (2, 2),
                dir: Direction::Down,
                step: 5.0,
                sync: false,
            },
            Cmd::Volume {
                endpoint: vec![],
                dir: Direction::Up,
                step: 5.0,
            },
            Cmd::Volume {
                endpoint: vec![],
                dir: Direction::Up,
                step: 5.0,
            },
            Cmd::Rescan,
            Cmd::Rescan,
        ];
        let out = coalesce(cmds);
        let presses: Vec<u32> = out.iter().map(|(_, p)| *p).collect();
        assert_eq!(presses, vec![2, 1, 2, 1]);
        assert!(matches!(out[0].0, Cmd::Brightness { point: (1, 1), .. }));
    }

    #[test]
    fn coalesce_keeps_mute_separate() {
        let cmds = vec![
            Cmd::ToggleMute { endpoint: vec![] },
            Cmd::ToggleMute { endpoint: vec![] },
        ];
        assert_eq!(coalesce(cmds).len(), 2);
    }
}
