//! Which audio device Windows is playing through. When it is a monitor (HDMI/DisplayPort,
//! including through USB-C docks), Glint drives that monitor's speakers over DDC instead of
//! letting Windows change its digital volume.

use windows::core::GUID;
use windows::Win32::Foundation::PROPERTYKEY;
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{eConsole, eMultimedia, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_ALL, STGM_READ};

// Defined here rather than pulled from feature-gated modules: these are stable,
// documented property keys (mmdeviceapi.h, devpkey.h).
const PKEY_AUDIOENDPOINT_FORMFACTOR: PROPERTYKEY =
    PROPERTYKEY { fmtid: GUID::from_u128(0x1da5d803_d492_4edd_8c23_e0c0ffee7f0e), pid: 0 };
const PKEY_DEVICE_DEVICEDESC: PROPERTYKEY =
    PROPERTYKEY { fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), pid: 2 };
const PKEY_DEVICE_FRIENDLYNAME: PROPERTYKEY =
    PROPERTYKEY { fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), pid: 14 };
/// EndpointFormFactor::DigitalAudioDisplayDevice
const FORM_FACTOR_DISPLAY: u32 = 9;

pub struct Endpoint {
    /// Description first (usually the monitor's EDID name), then the friendly name.
    pub names: Vec<String>,
    pub is_display: bool,
}

pub struct Audio {
    enumerator: IMMDeviceEnumerator,
}

impl Audio {
    pub fn new() -> Option<Audio> {
        // SAFETY: COM is initialised on the calling thread before this is called.
        let enumerator: IMMDeviceEnumerator =
            unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.ok()?;
        Some(Audio { enumerator })
    }

    pub fn default_endpoint(&self) -> Option<Endpoint> {
        // SAFETY: COM calls on interfaces owned by this thread.
        unsafe {
            let device = self.enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia).ok()?;
            let store = device.OpenPropertyStore(STGM_READ).ok()?;
            let form: PROPVARIANT = store.GetValue(&PKEY_AUDIOENDPOINT_FORMFACTOR).ok()?;
            let form = u32::try_from(&form).unwrap_or(0);
            let mut names = Vec::new();
            for key in [&PKEY_DEVICE_DEVICEDESC, &PKEY_DEVICE_FRIENDLYNAME] {
                if let Ok(v) = store.GetValue(key) {
                    let s = v.to_string();
                    if !s.is_empty() {
                        names.push(s);
                    }
                }
            }
            Some(Endpoint { names, is_display: form == FORM_FACTOR_DISPLAY })
        }
    }

    fn endpoint_volume(&self) -> Option<IAudioEndpointVolume> {
        // SAFETY: COM calls on interfaces owned by this thread.
        unsafe {
            let device = self.enumerator.GetDefaultAudioEndpoint(eRender, eConsole).ok()?;
            device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None).ok()
        }
    }

    /// Windows' own volume for the default output, 0–100.
    pub fn system_volume(&self) -> Option<f64> {
        let ep = self.endpoint_volume()?;
        // SAFETY: COM call.
        unsafe { ep.GetMasterVolumeLevelScalar() }.ok().map(|v| (v as f64 * 100.0).clamp(0.0, 100.0))
    }

    pub fn set_system_volume(&self, percent: f64) -> bool {
        let Some(ep) = self.endpoint_volume() else { return false };
        // SAFETY: COM call; a null event context is allowed.
        unsafe { ep.SetMasterVolumeLevelScalar((percent / 100.0).clamp(0.0, 1.0) as f32, std::ptr::null()) }.is_ok()
    }

    pub fn system_muted(&self) -> Option<bool> {
        let ep = self.endpoint_volume()?;
        // SAFETY: COM call.
        unsafe { ep.GetMute() }.ok().map(|b| b.as_bool())
    }

    pub fn set_system_mute(&self, muted: bool) -> bool {
        let Some(ep) = self.endpoint_volume() else { return false };
        // SAFETY: COM call; a null event context is allowed.
        unsafe { ep.SetMute(muted, std::ptr::null()) }.is_ok()
    }
}
