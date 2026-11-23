//! Built-in (laptop) panel brightness through WMI's WmiMonitorBrightness classes. Standard
//! users may read and set it; no admin needed.

use std::mem::ManuallyDrop;

use windows::core::{w, BSTR};
use windows::Win32::System::Com::{
    CoCreateInstance, CoSetProxyBlanket, CLSCTX_INPROC_SERVER, EOAC_NONE, RPC_C_AUTHN_LEVEL_CALL,
    RPC_C_IMP_LEVEL_IMPERSONATE,
};
use windows::Win32::System::Rpc::{RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE};
use windows::Win32::System::Variant::{VARENUM, VARIANT, VARIANT_0, VARIANT_0_0, VARIANT_0_0_0, VT_I4, VT_UI1};
use windows::Win32::System::Wmi::{
    IWbemClassObject, IWbemLocator, IWbemServices, WbemLocator, WBEM_FLAG_FORWARD_ONLY, WBEM_FLAG_RETURN_IMMEDIATELY,
    WBEM_INFINITE,
};

/// A scalar VARIANT (no owned data, so dropping it frees nothing).
fn variant(vt: VARENUM, value: VARIANT_0_0_0) -> VARIANT {
    VARIANT {
        Anonymous: VARIANT_0 {
            Anonymous: ManuallyDrop::new(VARIANT_0_0 {
                vt,
                Anonymous: value,
                ..Default::default()
            }),
        },
    }
}

pub struct Wmi {
    services: IWbemServices,
}

impl Wmi {
    /// Connects to root\WMI. Call on a thread with COM initialised.
    pub fn connect() -> Option<Wmi> {
        // SAFETY: COM calls with owned arguments.
        unsafe {
            let locator: IWbemLocator = CoCreateInstance(&WbemLocator, None, CLSCTX_INPROC_SERVER).ok()?;
            let services = locator
                .ConnectServer(
                    &BSTR::from("root\\WMI"),
                    &BSTR::new(),
                    &BSTR::new(),
                    &BSTR::new(),
                    0,
                    &BSTR::new(),
                    None,
                )
                .ok()?;
            CoSetProxyBlanket(
                &services,
                RPC_C_AUTHN_WINNT,
                RPC_C_AUTHZ_NONE,
                None,
                RPC_C_AUTHN_LEVEL_CALL,
                RPC_C_IMP_LEVEL_IMPERSONATE,
                None,
                EOAC_NONE,
            )
            .ok()?;
            Some(Wmi { services })
        }
    }

    fn first(&self, query: &str) -> Option<IWbemClassObject> {
        // SAFETY: COM calls with owned arguments.
        unsafe {
            let rows = self
                .services
                .ExecQuery(
                    &BSTR::from("WQL"),
                    &BSTR::from(query),
                    WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY,
                    None,
                )
                .ok()?;
            let mut objs = [None];
            let mut returned = 0u32;
            rows.Next(WBEM_INFINITE, &mut objs, &mut returned).ok().ok()?;
            if returned == 0 {
                return None;
            }
            objs[0].take()
        }
    }

    /// Current built-in panel brightness, 0–100.
    pub fn brightness(&self) -> Option<u32> {
        let row = self.first("SELECT CurrentBrightness FROM WmiMonitorBrightness WHERE Active=TRUE")?;
        let mut value = VARIANT::default();
        // SAFETY: valid object and out-parameter.
        unsafe { row.Get(w!("CurrentBrightness"), 0, &mut value, None, None) }.ok()?;
        u32::try_from(&value).ok()
    }

    /// Sets built-in panel brightness, 0–100.
    pub fn set_brightness(&self, percent: u32) -> bool {
        self.try_set_brightness(percent.min(100) as u8).is_some()
    }

    fn try_set_brightness(&self, percent: u8) -> Option<()> {
        let instance = self.first("SELECT * FROM WmiMonitorBrightnessMethods WHERE Active=TRUE")?;
        // SAFETY: COM calls with owned arguments and out-parameters.
        unsafe {
            let mut path = VARIANT::default();
            instance.Get(w!("__PATH"), 0, &mut path, None, None).ok()?;
            let path = BSTR::try_from(&path).ok()?;

            let mut class = None;
            self.services
                .GetObject(
                    &BSTR::from("WmiMonitorBrightnessMethods"),
                    Default::default(),
                    None,
                    Some(&mut class),
                    None,
                )
                .ok()?;
            let class = class?;
            let mut in_def = None;
            class
                .GetMethod(w!("WmiSetBrightness"), 0, &mut in_def, std::ptr::null_mut())
                .ok()?;
            let params = in_def?.SpawnInstance(0).ok()?;
            // Microsoft's WmiSetBrightness sample: Timeout as VT_I4, Brightness as VT_UI1.
            params
                .Put(w!("Timeout"), 0, &variant(VT_I4, VARIANT_0_0_0 { lVal: 0 }), 0)
                .ok()?;
            params
                .Put(
                    w!("Brightness"),
                    0,
                    &variant(VT_UI1, VARIANT_0_0_0 { bVal: percent }),
                    0,
                )
                .ok()?;
            self.services
                .ExecMethod(
                    &path,
                    &BSTR::from("WmiSetBrightness"),
                    Default::default(),
                    None,
                    &params,
                    None,
                    None,
                )
                .ok()?;
        }
        Some(())
    }
}
