//! Keyboard input through evdev, so it works the same under X11, Wayland, SteamOS Game
//! Mode and a bare console.
//!
//! Glint grabs each keyboard that has brightness or volume keys (EVIOCGRAB) and re-emits
//! every event it doesn't handle through one virtual keyboard (uinput), the approach keyd
//! and similar remappers use. That is what lets Glint *take* a volume key when the sound is
//! going to a monitor, as the Mac and Windows apps do, instead of the desktop also changing
//! its own volume. If uinput isn't available, Glint listens without grabbing ("passive").
//!
//! Lock-key LEDs set on the virtual keyboard are mirrored back to the real ones.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::keys::{self, Action, Mods, Policy};

const VIRTUAL_NAME: &str = "Glint virtual keyboard";

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;
const EV_MSC: u16 = 0x04;
const EV_LED: u16 = 0x11;
const KEY_MAX: u16 = 0x2ff;
const MSC_SCAN: u16 = 0x04;
const LED_MAX: u16 = 0x0f;

// ioctl encoding (asm-generic): dir<<30 | size<<16 | type<<8 | nr.
const fn ioc(dir: u64, ty: u8, nr: u8, size: u64) -> u64 {
    (dir << 30) | (size << 16) | ((ty as u64) << 8) | nr as u64
}
const fn ior(ty: u8, nr: u8, size: u64) -> u64 {
    ioc(2, ty, nr, size)
}
const fn iow(ty: u8, nr: u8, size: u64) -> u64 {
    ioc(1, ty, nr, size)
}
const EVIOCGRAB: u64 = iow(b'E', 0x90, 4);
const fn eviocgname(len: u64) -> u64 {
    ior(b'E', 0x06, len)
}
const fn eviocgbit(ev: u8, len: u64) -> u64 {
    ior(b'E', 0x20 + ev, len)
}
const fn eviocgkey(len: u64) -> u64 {
    ior(b'E', 0x18, len)
}
const UI_SET_EVBIT: u64 = iow(b'U', 100, 4);
const UI_SET_KEYBIT: u64 = iow(b'U', 101, 4);
const UI_SET_MSCBIT: u64 = iow(b'U', 104, 4);
const UI_SET_LEDBIT: u64 = iow(b'U', 105, 4);
const UI_DEV_SETUP: u64 = iow(b'U', 3, 92);
const UI_DEV_CREATE: u64 = 0x5501;

/// `struct input_event`: a timeval (two longs; 32-bit time on 32-bit kernels), then type,
/// code and value.
const WORD: usize = std::mem::size_of::<usize>();
pub const EVENT_SIZE: usize = 2 * WORD + 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub kind: u16,
    pub code: u16,
    pub value: i32,
}

pub fn decode(buf: &[u8]) -> Event {
    let o = 2 * WORD;
    Event {
        kind: u16::from_ne_bytes([buf[o], buf[o + 1]]),
        code: u16::from_ne_bytes([buf[o + 2], buf[o + 3]]),
        value: i32::from_ne_bytes([buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7]]),
    }
}

pub fn encode(e: Event) -> [u8; EVENT_SIZE] {
    let mut b = [0u8; EVENT_SIZE];
    let o = 2 * WORD;
    b[o..o + 2].copy_from_slice(&e.kind.to_ne_bytes());
    b[o + 2..o + 4].copy_from_slice(&e.code.to_ne_bytes());
    b[o + 4..o + 8].copy_from_slice(&e.value.to_ne_bytes());
    b
}

fn ioctl_buf(f: &File, req: u64, buf: &mut [u8]) -> bool {
    // SAFETY: the request's size field matches buf's length.
    unsafe { libc::ioctl(f.as_raw_fd(), req as _, buf.as_mut_ptr()) >= 0 }
}

fn ioctl_int(f: &File, req: u64, v: libc::c_int) -> bool {
    // SAFETY: these requests take an int by value.
    unsafe { libc::ioctl(f.as_raw_fd(), req as _, v) >= 0 }
}

fn bit(bits: &[u8], n: u16) -> bool {
    bits.get(n as usize / 8).is_some_and(|b| b & (1 << (n % 8)) != 0)
}

fn device_name(f: &File) -> String {
    let mut buf = [0u8; 256];
    if !ioctl_buf(f, eviocgname(buf.len() as u64), &mut buf) {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// A keyboard (or media-key device) worth listening to: it has brightness or volume keys,
/// and it isn't a mouse or touchpad (those are never grabbed), nor Glint's own device.
fn qualifies(f: &File) -> bool {
    let mut types = [0u8; 4];
    let mut keys_bits = [0u8; (KEY_MAX as usize / 8) + 1];
    if !ioctl_buf(f, eviocgbit(0, types.len() as u64), &mut types)
        || !ioctl_buf(f, eviocgbit(EV_KEY as u8, keys_bits.len() as u64), &mut keys_bits)
    {
        return false;
    }
    if !bit(&types, EV_KEY) || bit(&types, EV_REL) || bit(&types, EV_ABS) {
        return false;
    }
    keys::INTERESTING.iter().any(|&k| bit(&keys_bits, k)) && device_name(f) != VIRTUAL_NAME
}

/// Waits (up to 2 s) until no key on the device is held, so grabbing never leaves the
/// desktop thinking a key is stuck down (e.g. Enter, when Glint is started from a terminal).
fn wait_for_release(f: &File) {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut state = [0u8; (KEY_MAX as usize / 8) + 1];
    while Instant::now() < deadline {
        if !ioctl_buf(f, eviocgkey(state.len() as u64), &mut state) || state.iter().all(|&b| b == 0) {
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

/// The virtual keyboard everything Glint doesn't handle is re-emitted through.
pub struct Virtual {
    file: File,
}

impl Virtual {
    pub fn create() -> io::Result<Virtual> {
        let file = OpenOptions::new().read(true).write(true).open("/dev/uinput")?;
        let ok = ioctl_int(&file, UI_SET_EVBIT, EV_KEY as i32)
            && ioctl_int(&file, UI_SET_EVBIT, EV_SYN as i32)
            && ioctl_int(&file, UI_SET_EVBIT, EV_MSC as i32)
            && ioctl_int(&file, UI_SET_EVBIT, EV_LED as i32)
            && ioctl_int(&file, UI_SET_MSCBIT, MSC_SCAN as i32)
            && (1..=KEY_MAX).all(|k| ioctl_int(&file, UI_SET_KEYBIT, k as i32))
            && (0..=LED_MAX).all(|l| ioctl_int(&file, UI_SET_LEDBIT, l as i32));
        if !ok {
            return Err(io::Error::last_os_error());
        }
        // struct uinput_setup { struct input_id id; char name[80]; __u32 ff_effects_max; }
        let mut setup = [0u8; 92];
        setup[0..2].copy_from_slice(&0x06u16.to_ne_bytes()); // BUS_VIRTUAL
        setup[2..4].copy_from_slice(&0x1209u16.to_ne_bytes());
        setup[4..6].copy_from_slice(&0x6c74u16.to_ne_bytes());
        setup[6..8].copy_from_slice(&1u16.to_ne_bytes());
        setup[8..8 + VIRTUAL_NAME.len()].copy_from_slice(VIRTUAL_NAME.as_bytes());
        if !ioctl_buf(&file, UI_DEV_SETUP, &mut setup) || !ioctl_int(&file, UI_DEV_CREATE as _, 0) {
            return Err(io::Error::last_os_error());
        }
        Ok(Virtual { file })
    }

    pub fn emit(&self, e: Event) {
        let _ = (&self.file).write_all(&encode(e));
    }
}

/// Where key actions go, and the current policy for what to take.
pub struct Shared {
    pub policy: Mutex<Policy>,
    pub on_action: Box<dyn Fn(Action) + Send + Sync>,
    pub virtual_kbd: Option<Virtual>,
    /// Grabbed devices, for mirroring lock-key LEDs back to them.
    grabbed: Mutex<Vec<(PathBuf, File)>>,
    open: Mutex<HashSet<PathBuf>>,
}

impl Shared {
    pub fn new(on_action: Box<dyn Fn(Action) + Send + Sync>, policy: Policy) -> Arc<Shared> {
        let virtual_kbd = match Virtual::create() {
            Ok(v) => Some(v),
            Err(e) => {
                crate::log::log(&format!("input: no virtual keyboard ({e}); listening without taking keys"));
                None
            }
        };
        Arc::new(Shared {
            policy: Mutex::new(policy),
            on_action,
            virtual_kbd,
            grabbed: Mutex::new(Vec::new()),
            open: Mutex::new(HashSet::new()),
        })
    }

    /// Without a virtual keyboard Glint can't take keys away from the desktop.
    pub fn passive(&self) -> bool {
        self.virtual_kbd.is_none()
    }
}

fn run_device(shared: Arc<Shared>, path: PathBuf, file: File) {
    let name = device_name(&file);
    let grab = shared.virtual_kbd.is_some();
    if grab {
        wait_for_release(&file);
        if !ioctl_int(&file, EVIOCGRAB, 1) {
            crate::log::log(&format!("input: couldn't grab {name}"));
            return;
        }
        if let Ok(clone) = file.try_clone() {
            shared.grabbed.lock().unwrap().push((path.clone(), clone));
        }
    }
    crate::log::log(&format!("input: {} {name} ({})", if grab { "grabbed" } else { "listening to" }, path.display()));
    let mut mods = Mods::default();
    let mut swallowing: HashSet<u16> = HashSet::new();
    let mut buf = vec![0u8; EVENT_SIZE * 64];
    let mut reader = &file;
    loop {
        let n = match reader.read(&mut buf) {
            Ok(n) if n >= EVENT_SIZE => n,
            _ => break, // unplugged (KVM switch) or error
        };
        for chunk in buf[..n].chunks_exact(EVENT_SIZE) {
            let e = decode(chunk);
            let mut forward = true;
            if e.kind == EV_KEY {
                mods.update(e.code, e.value);
                let policy = *shared.policy.lock().unwrap();
                let (action, swallow) = keys::classify(e.code, e.value, mods, policy);
                if let Some(a) = action {
                    (shared.on_action)(a);
                }
                // A key swallowed on press stays swallowed until released, even if the
                // policy changes in between, so the desktop never sees half a key press.
                if swallow && e.value == 1 {
                    swallowing.insert(e.code);
                }
                if swallowing.contains(&e.code) {
                    forward = false;
                    if e.value == 0 {
                        swallowing.remove(&e.code);
                    }
                }
            }
            if grab && forward {
                if let Some(v) = &shared.virtual_kbd {
                    v.emit(e);
                }
            }
        }
    }
    shared.grabbed.lock().unwrap().retain(|(p, _)| p != &path);
    shared.open.lock().unwrap().remove(&path);
    crate::log::log(&format!("input: {name} went away"));
}

fn scan_once(shared: &Arc<Shared>, dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let path = e.path();
        if !e.file_name().to_string_lossy().starts_with("event") || shared.open.lock().unwrap().contains(&path) {
            continue;
        }
        let Ok(file) = OpenOptions::new().read(true).open(&path) else { continue };
        if !qualifies(&file) {
            continue;
        }
        shared.open.lock().unwrap().insert(path.clone());
        let s = shared.clone();
        thread::spawn(move || run_device(s, path, file));
    }
}

/// Mirrors Caps/Num/Scroll Lock LEDs from the virtual keyboard back to grabbed keyboards.
fn mirror_leds(shared: Arc<Shared>) {
    let Some(v) = &shared.virtual_kbd else { return };
    let Ok(mut reader) = v.file.try_clone() else { return };
    let mut buf = vec![0u8; EVENT_SIZE * 16];
    while let Ok(n) = reader.read(&mut buf) {
        for chunk in buf[..n].chunks_exact(EVENT_SIZE) {
            let e = decode(chunk);
            if e.kind == EV_LED {
                for (_, dev) in shared.grabbed.lock().unwrap().iter() {
                    let _ = (&*dev).write_all(&encode(e));
                    let _ = (&*dev).write_all(&encode(Event { kind: EV_SYN, code: 0, value: 0 }));
                }
            }
        }
    }
}

/// Starts listening: scans `/dev/input` now and every 2 s for keyboards that appear (USB
/// plug-in, KVM switch, Bluetooth reconnect).
pub fn start(shared: Arc<Shared>) {
    let s = shared.clone();
    thread::spawn(move || mirror_leds(s));
    thread::spawn(move || loop {
        scan_once(&shared, Path::new("/dev/input"));
        thread::sleep(Duration::from_secs(2));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioctl_numbers_match_the_kernel_headers() {
        assert_eq!(EVIOCGRAB, 0x4004_4590);
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
        assert_eq!(UI_SET_KEYBIT, 0x4004_5565);
        assert_eq!(UI_DEV_SETUP, 0x405c_5503);
        assert_eq!(eviocgname(256), 0x8100_4506);
        assert_eq!(eviocgbit(EV_KEY as u8, 96), 0x8060_4521);
    }

    #[test]
    fn events_round_trip() {
        let e = Event { kind: EV_KEY, code: keys::KEY_VOLUMEUP, value: 1 };
        assert_eq!(decode(&encode(e)), e);
        assert_eq!(EVENT_SIZE, if cfg!(target_pointer_width = "64") { 24 } else { 16 });
    }

    #[test]
    fn bit_lookup() {
        let mut bits = [0u8; 40];
        bits[keys::KEY_BRIGHTNESSUP as usize / 8] |= 1 << (keys::KEY_BRIGHTNESSUP % 8);
        assert!(bit(&bits, keys::KEY_BRIGHTNESSUP));
        assert!(!bit(&bits, keys::KEY_BRIGHTNESSDOWN));
        assert!(!bit(&bits, 9999));
    }
}
