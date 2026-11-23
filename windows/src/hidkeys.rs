//! Hardware brightness keys through Raw Input. Windows has no virtual-key code for
//! brightness: keyboards send HID Consumer Control usages 0x6F/0x70, which only reach an
//! app that registers for raw consumer-control input. Standard users can do this; no admin.

use std::collections::hash_map::Entry;
use std::collections::HashMap;

use windows::Win32::Devices::HumanInterfaceDevice::{HidP_GetUsages, HidP_Input, PHIDP_PREPARSED_DATA};
use windows::Win32::Foundation::{HANDLE, HWND, LPARAM};
use windows::Win32::UI::Input::{
    GetRawInputData, GetRawInputDeviceInfoW, RegisterRawInputDevices, HRAWINPUT, RAWINPUT, RAWINPUTDEVICE,
    RAWINPUTHEADER, RIDEV_INPUTSINK, RIDI_PREPARSEDDATA, RID_INPUT, RIM_TYPEHID,
};

const HID_USAGE_PAGE_CONSUMER: u16 = 0x0C;
const HID_USAGE_CONSUMER_CONTROL: u16 = 0x01;
const HIDP_STATUS_SUCCESS: i32 = 0x0011_0000;

/// Asks Windows to send consumer-control reports to `hwnd` even while Glint isn't focused.
pub fn register(hwnd: HWND) -> bool {
    let device = RAWINPUTDEVICE {
        usUsagePage: HID_USAGE_PAGE_CONSUMER,
        usUsage: HID_USAGE_CONSUMER_CONTROL,
        dwFlags: RIDEV_INPUTSINK,
        hwndTarget: hwnd,
    };
    // SAFETY: one fully initialised RAWINPUTDEVICE.
    unsafe { RegisterRawInputDevices(&[device], std::mem::size_of::<RAWINPUTDEVICE>() as u32) }.is_ok()
}

/// Preparsed HID descriptors, cached per device (8-byte aligned storage).
#[derive(Default)]
pub struct Decoder {
    preparsed: HashMap<isize, Vec<u64>>,
}

fn load_preparsed(device: HANDLE) -> Option<Vec<u64>> {
    let mut size = 0u32;
    // SAFETY: size query, then a buffer of that size.
    unsafe {
        GetRawInputDeviceInfoW(Some(device), RIDI_PREPARSEDDATA, None, &mut size);
        if size == 0 {
            return None;
        }
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let got = GetRawInputDeviceInfoW(Some(device), RIDI_PREPARSEDDATA, Some(buf.as_mut_ptr() as _), &mut size);
        (got != u32::MAX && got != 0).then_some(buf)
    }
}

impl Decoder {
    fn preparsed(&mut self, device: HANDLE) -> Option<&Vec<u64>> {
        match self.preparsed.entry(device.0 as isize) {
            Entry::Occupied(e) => Some(e.into_mut()),
            Entry::Vacant(e) => Some(e.insert(load_preparsed(device)?)),
        }
    }

    /// Consumer-page usages held down in a WM_INPUT message, or None if it isn't a HID
    /// consumer report Glint can decode.
    pub fn read(&mut self, lparam: LPARAM) -> Option<Vec<u16>> {
        let handle = HRAWINPUT(lparam.0 as *mut _);
        let header = std::mem::size_of::<RAWINPUTHEADER>() as u32;
        let mut size = 0u32;
        // SAFETY: size query, then a suitably aligned buffer of that size.
        unsafe {
            GetRawInputData(handle, RID_INPUT, None, &mut size, header);
            if size == 0 {
                return None;
            }
            let mut buf = vec![0u64; (size as usize).div_ceil(8)];
            if GetRawInputData(handle, RID_INPUT, Some(buf.as_mut_ptr() as _), &mut size, header) == u32::MAX {
                return None;
            }
            let raw = &*(buf.as_ptr() as *const RAWINPUT);
            if raw.header.dwType != RIM_TYPEHID.0 {
                return None;
            }
            let device = raw.header.hDevice;
            let hid = &raw.data.hid;
            let report_len = hid.dwSizeHid as usize;
            let count = hid.dwCount as usize;
            let base = std::ptr::addr_of!(hid.bRawData) as *const u8;
            let end = (buf.as_ptr() as *const u8).add(size as usize);
            if report_len == 0 || base.add(report_len * count) > end {
                return None;
            }
            let reports: Vec<Vec<u8>> = (0..count)
                .map(|i| std::slice::from_raw_parts(base.add(i * report_len), report_len).to_vec())
                .collect();
            let preparsed = PHIDP_PREPARSED_DATA(self.preparsed(device)?.as_ptr() as isize);
            let mut usages = Vec::new();
            for mut report in reports {
                let mut list = [0u16; 32];
                let mut len = list.len() as u32;
                let status = HidP_GetUsages(
                    HidP_Input,
                    HID_USAGE_PAGE_CONSUMER,
                    None,
                    list.as_mut_ptr(),
                    &mut len,
                    preparsed,
                    &mut report,
                );
                if status.0 == HIDP_STATUS_SUCCESS {
                    usages.extend_from_slice(&list[..len as usize]);
                }
            }
            Some(usages)
        }
    }
}
