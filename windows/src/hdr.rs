//! Brightness for monitors in HDR. In HDR mode monitors lock their backlight, so DDC
//! brightness writes are ignored. Windows instead offers "SDR content brightness"
//! (Settings › Display › HDR), which sets how bright desktop and SDR app content is inside
//! the HDR signal. Glint drives that for HDR displays.
//!
//! Reading the HDR state and the SDR white level is documented
//! (DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO / GET_SDR_WHITE_LEVEL). Setting the
//! white level is not: it uses the device-info type Windows' own Settings app sends (-18),
//! the same call other HDR utilities use. No admin is needed.

use windows::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, DisplayConfigSetDeviceInfo, DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO,
    DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_DEVICE_INFO_TYPE,
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO, DISPLAYCONFIG_SDR_WHITE_LEVEL,
};
use windows::Win32::Foundation::LUID;

/// Undocumented DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL.
const SET_SDR_WHITE_LEVEL: DISPLAYCONFIG_DEVICE_INFO_TYPE = DISPLAYCONFIG_DEVICE_INFO_TYPE(-18);
/// advancedColorEnabled in DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO's bitfield.
const ADVANCED_COLOR_ENABLED: u32 = 0b10;

#[repr(C)]
struct SetSdrWhiteLevel {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    sdr_white_level: u32,
    final_value: u8,
}

/// A display-configuration target (adapter + target id), as QueryDisplayConfig reports it.
#[derive(Clone, Copy, Debug)]
pub struct Target {
    pub adapter: LUID,
    pub id: u32,
}

fn header(t: Target, kind: DISPLAYCONFIG_DEVICE_INFO_TYPE, size: usize) -> DISPLAYCONFIG_DEVICE_INFO_HEADER {
    DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: kind, size: size as u32, adapterId: t.adapter, id: t.id }
}

/// Whether Windows is driving this display in HDR.
pub fn active(t: Target) -> bool {
    let mut info = DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO {
        header: header(
            t,
            DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO,
            std::mem::size_of::<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO>(),
        ),
        ..Default::default()
    };
    // SAFETY: the header carries this struct's type and size; the union is read as u32.
    unsafe { DisplayConfigGetDeviceInfo(&mut info.header) == 0 && info.Anonymous.value & ADVANCED_COLOR_ENABLED != 0 }
}

/// SDR content brightness as Windows' slider shows it, 0–100.
pub fn sdr_brightness(t: Target) -> Option<f64> {
    let mut level = DISPLAYCONFIG_SDR_WHITE_LEVEL {
        header: header(
            t,
            DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL,
            std::mem::size_of::<DISPLAYCONFIG_SDR_WHITE_LEVEL>(),
        ),
        SDRWhiteLevel: 0,
    };
    // SAFETY: the header carries this struct's type and size.
    let ok = unsafe { DisplayConfigGetDeviceInfo(&mut level.header) } == 0;
    (ok && level.SDRWhiteLevel > 0).then(|| crate::logic::sdr_level_to_percent(level.SDRWhiteLevel))
}

/// Sets SDR content brightness, 0–100. True if Windows accepted it.
pub fn set_sdr_brightness(t: Target, percent: f64) -> bool {
    let packet = SetSdrWhiteLevel {
        header: header(t, SET_SDR_WHITE_LEVEL, std::mem::size_of::<SetSdrWhiteLevel>()),
        sdr_white_level: crate::logic::percent_to_sdr_level(percent),
        final_value: 1,
    };
    // SAFETY: the header carries this struct's type and size.
    unsafe { DisplayConfigSetDeviceInfo(&packet.header) == 0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Windows checks `header.size` against its own C layout: a 20-byte header, the
    /// 4-byte level and a 1-byte flag, padded to 4-byte alignment.
    #[test]
    fn set_packet_matches_the_c_layout() {
        assert_eq!(std::mem::size_of::<DISPLAYCONFIG_DEVICE_INFO_HEADER>(), 20);
        assert_eq!(std::mem::size_of::<SetSdrWhiteLevel>(), 28);
        assert_eq!(std::mem::offset_of!(SetSdrWhiteLevel, sdr_white_level), 20);
        assert_eq!(std::mem::offset_of!(SetSdrWhiteLevel, final_value), 24);
    }
}
