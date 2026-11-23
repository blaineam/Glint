//! Monitor enumeration and DDC/CI over the Windows monitor configuration API (dxva2).
//! Everything here runs as a standard user: no driver, no admin.

use windows::core::BOOL;
use windows::Win32::Devices::Display::{
    CapabilitiesRequestAndCapabilitiesReply, DestroyPhysicalMonitors, DisplayConfigGetDeviceInfo,
    GetCapabilitiesStringLength, GetDisplayConfigBufferSizes, GetNumberOfPhysicalMonitorsFromHMONITOR,
    GetPhysicalMonitorsFromHMONITOR, GetVCPFeatureAndVCPFeatureReply, QueryDisplayConfig, SetVCPFeature,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
    DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED,
    DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL, DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS,
    DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SOURCE_DEVICE_NAME,
    DISPLAYCONFIG_TARGET_DEVICE_NAME, PHYSICAL_MONITOR, QDC_ONLY_ACTIVE_PATHS,
};
use windows::Win32::Foundation::{ERROR_SUCCESS, HANDLE, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW};

pub const VCP_BRIGHTNESS: u8 = 0x10;
pub const VCP_VOLUME: u8 = 0x62;

/// The monitor's MCCS capabilities string ("(prot(monitor)type(lcd)model(...)vcp(10 12 62 ...))").
/// Logged at each scan: it shows whether the real monitor answers DDC/CI and which
/// controls it says it supports (0x10 brightness, 0x62 volume).
pub fn capabilities(mon: &Monitor) -> Option<String> {
    let handle = mon.physical.first()?.hPhysicalMonitor;
    let mut len = 0u32;
    // SAFETY: valid physical monitor handle; the buffer is sized from the reported length.
    unsafe {
        if GetCapabilitiesStringLength(handle, &mut len) == 0 || len == 0 {
            return None;
        }
        let mut buf = vec![0u8; len as usize];
        if CapabilitiesRequestAndCapabilitiesReply(handle, &mut buf) == 0 {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        Some(String::from_utf8_lossy(&buf[..end]).into_owned())
    }
}

/// One logical display (an HMONITOR). Cloned outputs can put several physical monitors
/// behind one HMONITOR; reads use the first, writes go to all.
pub struct Monitor {
    pub name: String,
    /// For HDR state and SDR content brightness (see `hdr`).
    pub target: Option<crate::hdr::Target>,
    pub rect: RECT,
    pub internal: bool,
    pub physical: Vec<PHYSICAL_MONITOR>,
}

impl Drop for Monitor {
    fn drop(&mut self) {
        if !self.physical.is_empty() {
            // SAFETY: the handles came from GetPhysicalMonitorsFromHMONITOR and are dropped once.
            let _ = unsafe { DestroyPhysicalMonitors(&self.physical) };
        }
    }
}

fn wide_to_string(buf: &[u16]) -> String {
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..len])
}

struct PathName {
    target: crate::hdr::Target,
    gdi_name: String,
    friendly: String,
    internal: bool,
}

/// Maps GDI device names (\\.\DISPLAY1) to the EDID friendly name and whether the panel
/// is built in.
fn display_config_names() -> Vec<PathName> {
    let mut out = Vec::new();
    let mut n_paths = 0u32;
    let mut n_modes = 0u32;
    // SAFETY: plain out-parameters.
    if unsafe { GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut n_paths, &mut n_modes) } != ERROR_SUCCESS {
        return out;
    }
    let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); n_paths as usize];
    let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); n_modes as usize];
    // SAFETY: buffers are sized from GetDisplayConfigBufferSizes.
    let rc = unsafe {
        QueryDisplayConfig(
            QDC_ONLY_ACTIVE_PATHS,
            &mut n_paths,
            paths.as_mut_ptr(),
            &mut n_modes,
            modes.as_mut_ptr(),
            None,
        )
    };
    if rc != ERROR_SUCCESS {
        return out;
    }
    paths.truncate(n_paths as usize);
    for p in &paths {
        let mut src = DISPLAYCONFIG_SOURCE_DEVICE_NAME {
            header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
                size: std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32,
                adapterId: p.sourceInfo.adapterId,
                id: p.sourceInfo.id,
            },
            ..Default::default()
        };
        let mut tgt = DISPLAYCONFIG_TARGET_DEVICE_NAME {
            header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
                size: std::mem::size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32,
                adapterId: p.targetInfo.adapterId,
                id: p.targetInfo.id,
            },
            ..Default::default()
        };
        // SAFETY: headers carry the right type and size for each struct.
        let ok = unsafe {
            DisplayConfigGetDeviceInfo(&mut src.header) == 0 && DisplayConfigGetDeviceInfo(&mut tgt.header) == 0
        };
        if !ok {
            continue;
        }
        let tech = tgt.outputTechnology;
        out.push(PathName {
            target: crate::hdr::Target { adapter: p.targetInfo.adapterId, id: p.targetInfo.id },
            gdi_name: wide_to_string(&src.viewGdiDeviceName),
            friendly: wide_to_string(&tgt.monitorFriendlyDeviceName),
            internal: tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL
                || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
                || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED
                || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS,
        });
    }
    out
}

unsafe extern "system" fn collect_monitor(hmon: HMONITOR, _hdc: HDC, _rect: *mut RECT, data: LPARAM) -> BOOL {
    // SAFETY: data is the &mut Vec<HMONITOR> passed to EnumDisplayMonitors below.
    let list = unsafe { &mut *(data.0 as *mut Vec<HMONITOR>) };
    list.push(hmon);
    BOOL(1)
}

/// Enumerates every active display with its DDC handles.
pub fn enumerate() -> Vec<Monitor> {
    let mut hmons: Vec<HMONITOR> = Vec::new();
    // SAFETY: the callback only pushes into the Vec for the duration of this call.
    unsafe {
        let _ =
            EnumDisplayMonitors(None, None, Some(collect_monitor), LPARAM(&mut hmons as *mut Vec<HMONITOR> as isize));
    }
    let names = display_config_names();
    let mut out = Vec::new();
    for (i, hmon) in hmons.into_iter().enumerate() {
        let mut info = MONITORINFOEXW {
            monitorInfo: MONITORINFO { cbSize: std::mem::size_of::<MONITORINFOEXW>() as u32, ..Default::default() },
            ..Default::default()
        };
        // SAFETY: MONITORINFOEXW starts with MONITORINFO and cbSize says which one it is.
        if !unsafe { GetMonitorInfoW(hmon, &mut info.monitorInfo as *mut MONITORINFO) }.as_bool() {
            continue;
        }
        let gdi = wide_to_string(&info.szDevice);
        let path = names.iter().find(|n| n.gdi_name.eq_ignore_ascii_case(&gdi));
        let internal = path.map(|p| p.internal).unwrap_or(false);
        let mut name = path.map(|p| p.friendly.clone()).unwrap_or_default();
        if name.is_empty() {
            name = if internal {
                crate::i18n::t("Built-in display").to_string()
            } else {
                crate::i18n::t("Display {}").replace("{}", &(i + 1).to_string())
            };
        }
        let physical = if internal { Vec::new() } else { physical_monitors(hmon) };
        out.push(Monitor {
            name,
            rect: info.monitorInfo.rcMonitor,
            internal,
            physical,
            target: path.map(|p| p.target),
        });
    }
    out
}

fn physical_monitors(hmon: HMONITOR) -> Vec<PHYSICAL_MONITOR> {
    let mut count = 0u32;
    // SAFETY: out-parameter.
    if unsafe { GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, &mut count) }.is_err() || count == 0 {
        return Vec::new();
    }
    let mut list = vec![PHYSICAL_MONITOR::default(); count as usize];
    // SAFETY: the slice is sized from the count above.
    if unsafe { GetPhysicalMonitorsFromHMONITOR(hmon, &mut list) }.is_err() {
        return Vec::new();
    }
    list
}

/// Reads a VCP feature, retrying once (DDC over some docks and KVMs drops the first
/// transaction after idle). Returns (current, max).
pub fn read_vcp(mon: &Monitor, code: u8) -> Option<(u32, u32)> {
    let handle = mon.physical.first()?.hPhysicalMonitor;
    for attempt in 0..2 {
        let mut cur = 0u32;
        let mut max = 0u32;
        // SAFETY: valid physical monitor handle and out-parameters.
        let ok = unsafe { GetVCPFeatureAndVCPFeatureReply(handle, code, None, &mut cur, Some(&mut max)) } != 0;
        crate::gdebug!("ddc read '{}' vcp 0x{code:02X}: ok={ok} cur={cur} max={max}", mon.name);
        if ok && max > 0 {
            return Some((cur.min(max), max));
        }
        if attempt == 0 {
            std::thread::sleep(std::time::Duration::from_millis(40));
        }
    }
    None
}

/// Writes a VCP feature to every physical monitor behind the display. True if any accepted.
pub fn write_vcp(mon: &Monitor, code: u8, value: u32) -> bool {
    let mut any = false;
    for pm in &mon.physical {
        let ok = write_one(pm.hPhysicalMonitor, code, value);
        crate::gdebug!("ddc write '{}' vcp 0x{code:02X} = {value}: ok={ok}", mon.name);
        any |= ok;
    }
    any
}

fn write_one(handle: HANDLE, code: u8, value: u32) -> bool {
    for attempt in 0..2 {
        // SAFETY: valid physical monitor handle.
        if unsafe { SetVCPFeature(handle, code, value) } != 0 {
            return true;
        }
        if attempt == 0 {
            std::thread::sleep(std::time::Duration::from_millis(40));
        }
    }
    false
}
