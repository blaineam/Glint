//! Notification-area (tray) icon.

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP, NIIF_NONE, NIM_ADD, NIM_DELETE,
    NIM_MODIFY, NIM_SETVERSION, NOTIFYICONDATAW, NOTIFYICONDATAW_0, NOTIFYICON_VERSION_4,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, LoadIconW, LoadImageW, HICON, IDI_APPLICATION, IMAGE_ICON, LR_DEFAULTCOLOR, SM_CXSMICON,
    SM_CYSMICON,
};

pub const WM_APP_TRAY: u32 = 0x8000 + 1;

pub struct Tray {
    hwnd: HWND,
    icon: HICON,
    visible: bool,
}

fn copy_into(dst: &mut [u16], s: &str) {
    let mut n = 0;
    for (d, c) in dst.iter_mut().zip(s.encode_utf16()) {
        *d = c;
        n += 1;
    }
    let end = n.min(dst.len() - 1);
    dst[end] = 0;
}

/// The app icon embedded as resource id 1 (build.rs), at small-icon size.
pub fn app_icon(small: bool) -> HICON {
    // SAFETY: loading a resource from our own module; falls back to the stock icon.
    unsafe {
        let module = GetModuleHandleW(None).ok();
        let (cx, cy) = if small {
            (GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON))
        } else {
            (0, 0)
        };
        if let Some(m) = module {
            if let Ok(h) = LoadImageW(
                Some(m.into()),
                PCWSTR(std::ptr::without_provenance::<u16>(1)), // MAKEINTRESOURCE(1)
                IMAGE_ICON,
                cx,
                cy,
                LR_DEFAULTCOLOR,
            ) {
                return HICON(h.0);
            }
        }
        LoadIconW(None, IDI_APPLICATION).unwrap_or_default()
    }
}

impl Tray {
    pub fn new(hwnd: HWND) -> Tray {
        Tray {
            hwnd,
            icon: app_icon(true),
            visible: false,
        }
    }

    fn data(&self) -> NOTIFYICONDATAW {
        NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: 1,
            ..Default::default()
        }
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    pub fn show(&mut self, tip: &str) {
        let mut nid = self.data();
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
        nid.uCallbackMessage = WM_APP_TRAY;
        nid.hIcon = self.icon;
        copy_into(&mut nid.szTip, tip);
        // SAFETY: nid is fully initialised for our window.
        unsafe {
            if !Shell_NotifyIconW(NIM_ADD, &nid).as_bool() {
                // Already there (e.g. after TaskbarCreated): update instead.
                let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
            }
            nid.Anonymous = NOTIFYICONDATAW_0 {
                uVersion: NOTIFYICON_VERSION_4,
            };
            let _ = Shell_NotifyIconW(NIM_SETVERSION, &nid);
        }
        self.visible = true;
    }

    pub fn hide(&mut self) {
        let nid = self.data();
        // SAFETY: removes our own icon.
        let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &nid) };
        self.visible = false;
    }

    pub fn set_tip(&self, tip: &str) {
        if !self.visible {
            return;
        }
        let mut nid = self.data();
        nid.uFlags = NIF_TIP | NIF_SHOWTIP;
        copy_into(&mut nid.szTip, tip);
        // SAFETY: modifies our own icon.
        let _ = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) };
    }

    /// A Windows notification from the tray icon (used once, on first launch).
    pub fn notify(&self, title: &str, text: &str) {
        if !self.visible {
            return;
        }
        let mut nid = self.data();
        nid.uFlags = NIF_INFO;
        nid.dwInfoFlags = NIIF_NONE;
        copy_into(&mut nid.szInfoTitle, title);
        copy_into(&mut nid.szInfo, text);
        // SAFETY: modifies our own icon.
        let _ = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) };
    }
}

#[cfg(test)]
mod tests {
    use super::copy_into;

    #[test]
    fn copy_truncates_and_terminates() {
        let mut buf = [1u16; 4];
        copy_into(&mut buf, "abcdef");
        assert_eq!(buf, [97, 98, 99, 0]);
        let mut buf = [1u16; 8];
        copy_into(&mut buf, "ab");
        assert_eq!(&buf[..3], &[97, 98, 0]);
    }
}
