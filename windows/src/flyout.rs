//! The tray flyout: per-display brightness and volume sliders, the Windows counterpart of
//! the Mac app's menu-bar popover. Opens on a left click, closes when it loses focus.

use std::cell::Cell;

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, GetMonitorInfoW, GetSysColor, GetSysColorBrush, MonitorFromPoint, SetBkColor, SetTextColor,
    ANTIALIASED_QUALITY, CLIP_DEFAULT_PRECIS, COLOR_GRAYTEXT, COLOR_WINDOW, COLOR_WINDOWTEXT, DEFAULT_CHARSET,
    FF_DONTCARE, FW_NORMAL, FW_SEMIBOLD, HBRUSH, HDC, HFONT, MONITORINFO, MONITOR_DEFAULTTONEAREST, OUT_DEFAULT_PRECIS,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{InitCommonControlsEx, ICC_BAR_CLASSES, INITCOMMONCONTROLSEX};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetDlgCtrlID, GetWindowLongPtrW, IsWindow, PostMessageW,
    RegisterClassW, SendMessageW, SetDlgItemTextW, SetForegroundWindow, SetWindowLongPtrW, ShowWindow, GWLP_USERDATA,
    HMENU, SW_SHOW, WINDOW_STYLE, WM_ACTIVATE, WM_CTLCOLORSTATIC, WM_HSCROLL, WM_SETFONT, WNDCLASSW, WS_BORDER,
    WS_CHILD, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WS_VISIBLE,
};

use crate::i18n::t;
use crate::logic::percent_label;
use crate::worker::DisplayInfo;

/// Posted to the main window: wparam = control id (see `encode_id`), lparam = 0–100.
pub const WM_APP_SLIDER: u32 = 0x8000 + 20;

const ID_BASE: usize = 100;
const WA_INACTIVE: usize = 0;
const WM_USER: u32 = 0x0400;
const TBM_GETPOS: u32 = WM_USER;
const TBM_SETPOS: u32 = WM_USER + 5;
const TBM_SETRANGE: u32 = WM_USER + 6;
const TBS_NOTICKS: u32 = 0x0010;
const SS_ENDELLIPSIS: u32 = 0x4000;
/// The "46%" label beside each slider has the slider's id plus this.
const VALUE_LABEL_OFFSET: usize = 1000;

/// "Brightness", or "Brightness (HDR)" when it is Windows' SDR content brightness.
pub fn brightness_label(hdr: bool) -> String {
    if hdr {
        format!("{} (HDR)", t("Brightness"))
    } else {
        t("Brightness").to_string()
    }
}

pub fn encode_id(index: usize, is_volume: bool) -> usize {
    ID_BASE + index * 2 + is_volume as usize
}

pub fn decode_id(id: usize) -> Option<(usize, bool)> {
    id.checked_sub(ID_BASE).map(|n| (n / 2, n % 2 == 1))
}

thread_local! {
    static FONTS: Cell<Option<(u32, HFONT, HFONT)>> = const { Cell::new(None) };
}

/// Regular and semibold Segoe UI for a DPI, created once per DPI.
fn fonts(dpi: u32) -> (HFONT, HFONT) {
    FONTS.with(|f| {
        if let Some((d, regular, bold)) = f.get() {
            if d == dpi {
                return (regular, bold);
            }
        }
        let make = |weight: i32| {
            // SAFETY: creates a GDI font kept for the life of the process.
            unsafe {
                CreateFontW(
                    -((9.0 * dpi as f64 / 72.0).round() as i32),
                    0,
                    0,
                    0,
                    weight,
                    0,
                    0,
                    0,
                    DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS,
                    CLIP_DEFAULT_PRECIS,
                    ANTIALIASED_QUALITY,
                    FF_DONTCARE.0 as u32,
                    w!("Segoe UI"),
                )
            }
        };
        let pair = (make(FW_NORMAL.0 as i32), make(FW_SEMIBOLD.0 as i32));
        f.set(Some((dpi, pair.0, pair.1)));
        pair
    })
}

unsafe extern "system" fn flyout_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // SAFETY: Win32 calls on our own window and its children.
    unsafe {
        match msg {
            WM_ACTIVATE if (wparam.0 & 0xFFFF) == WA_INACTIVE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_HSCROLL if lparam.0 != 0 => {
                let slider = HWND(lparam.0 as *mut _);
                let id = GetDlgCtrlID(slider) as usize;
                let pos = SendMessageW(slider, TBM_GETPOS, None, None).0;
                let _ =
                    SetDlgItemTextW(hwnd, (id + VALUE_LABEL_OFFSET) as i32, &HSTRING::from(percent_label(pos as f64)));
                let owner = HWND(GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut _);
                let _ = PostMessageW(Some(owner), WM_APP_SLIDER, WPARAM(id), LPARAM(pos));
                LRESULT(0)
            }
            WM_CTLCOLORSTATIC => {
                // Labels and sliders paint on the window colour (light or dark theme).
                let hdc = HDC(wparam.0 as *mut _);
                let child = HWND(lparam.0 as *mut _);
                let muted = GetDlgCtrlID(child) == 1;
                SetTextColor(hdc, COLORREF(GetSysColor(if muted { COLOR_GRAYTEXT } else { COLOR_WINDOWTEXT })));
                SetBkColor(hdc, COLORREF(GetSysColor(COLOR_WINDOW)));
                LRESULT(GetSysColorBrush(COLOR_WINDOW).0 as isize)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

pub struct Flyout {
    owner: HWND,
    current: Cell<Option<HWND>>,
}

impl Flyout {
    pub fn new(owner: HWND) -> Option<Flyout> {
        // SAFETY: registering a window class and the trackbar control class.
        unsafe {
            let icc = INITCOMMONCONTROLSEX {
                dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
                dwICC: ICC_BAR_CLASSES,
            };
            let _ = InitCommonControlsEx(&icc);
            let instance = GetModuleHandleW(None).ok()?;
            let class = WNDCLASSW {
                lpfnWndProc: Some(flyout_proc),
                hInstance: instance.into(),
                hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as usize as *mut _),
                lpszClassName: w!("GlintFlyout"),
                ..Default::default()
            };
            RegisterClassW(&class);
        }
        Some(Flyout { owner, current: Cell::new(None) })
    }

    /// Opens the flyout near `anchor` (the tray click), above the taskbar.
    pub fn show(&self, displays: &[DisplayInfo], anchor: POINT) {
        // SAFETY: creates, lays out and shows our own window and its children.
        unsafe {
            if let Some(old) = self.current.take() {
                if IsWindow(Some(old)).as_bool() {
                    let _ = DestroyWindow(old);
                }
            }
            let Ok(instance) = GetModuleHandleW(None) else { return };
            let hmon = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            let _ = GetMonitorInfoW(hmon, &mut info);
            let (mut dpi, mut _dpi_y) = (96u32, 96u32);
            let _ = GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi, &mut _dpi_y);
            let px = |v: f64| (v * dpi as f64 / 96.0).round() as i32;
            let (font, bold) = fonts(dpi);

            let width = px(320.0);
            let pad = px(14.0);
            let label_w = px(76.0);
            let row_h = px(30.0);

            // Rows first, so the window height is known before it is created.
            enum Item {
                Name(String),
                Slider { id: usize, label: String, value: f64 },
                Note(&'static str),
            }
            let mut items = Vec::new();
            let mut any = false;
            for (i, d) in displays.iter().enumerate() {
                if d.brightness.is_none() && d.volume.is_none() {
                    continue;
                }
                any = true;
                let name = if d.internal && d.name != t("Built-in display") {
                    format!("{} {}", d.name, t("(built-in)"))
                } else {
                    d.name.clone()
                };
                items.push(Item::Name(name));
                if let Some(b) = d.brightness {
                    items.push(Item::Slider { id: encode_id(i, false), label: brightness_label(d.hdr), value: b });
                }
                if let Some(v) = d.volume {
                    items.push(Item::Slider { id: encode_id(i, true), label: t("Volume").into(), value: v });
                }
            }
            if !any {
                items.push(Item::Note(t("No display answered DDC/CI. Try Rescan displays.")));
            }
            items.push(Item::Note(t("Right-click the tray icon for settings.")));
            let height: i32 = pad * 2
                + items
                    .iter()
                    .map(|it| match it {
                        Item::Name(_) => px(24.0),
                        Item::Slider { .. } => row_h,
                        Item::Note(_) => px(26.0),
                    })
                    .sum::<i32>();

            let work: RECT = info.rcWork;
            let x = (anchor.x - width / 2).clamp(work.left + px(8.0), work.right - width - px(8.0));
            let y = if anchor.y > (work.top + work.bottom) / 2 {
                work.bottom - height - px(8.0)
            } else {
                work.top + px(8.0)
            };
            let Ok(hwnd) = CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                w!("GlintFlyout"),
                w!("Glint"),
                WS_POPUP | WS_BORDER,
                x,
                y,
                width,
                height,
                None,
                None,
                Some(instance.into()),
                None,
            ) else {
                return;
            };
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, self.owner.0 as isize);

            let child = |class: PCWSTR, text: &str, style: u32, id: usize, r: (i32, i32, i32, i32), f: HFONT| {
                let h = CreateWindowExW(
                    Default::default(),
                    class,
                    &HSTRING::from(text),
                    WS_CHILD | WS_VISIBLE | WINDOW_STYLE(style),
                    r.0,
                    r.1,
                    r.2,
                    r.3,
                    Some(hwnd),
                    Some(HMENU(id as *mut _)),
                    Some(instance.into()),
                    None,
                );
                if let Ok(h) = h {
                    SendMessageW(h, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
                }
                h.ok()
            };

            let mut y = pad;
            for item in &items {
                match item {
                    Item::Name(name) => {
                        child(
                            w!("STATIC"),
                            name,
                            SS_ENDELLIPSIS,
                            0,
                            (pad, y + px(4.0), width - pad * 2, px(18.0)),
                            bold,
                        );
                        y += px(24.0);
                    }
                    Item::Slider { id, label, value } => {
                        child(w!("STATIC"), label, 0, 0, (pad, y + px(7.0), label_w, px(18.0)), font);
                        let value_w = px(40.0);
                        let slider_w = width - pad * 2 - label_w - value_w;
                        if let Some(s) = child(
                            w!("msctls_trackbar32"),
                            "",
                            TBS_NOTICKS,
                            *id,
                            (pad + label_w, y, slider_w, row_h),
                            font,
                        ) {
                            SendMessageW(s, TBM_SETRANGE, Some(WPARAM(1)), Some(LPARAM(100 << 16)));
                            SendMessageW(s, TBM_SETPOS, Some(WPARAM(1)), Some(LPARAM(value.round() as isize)));
                        }
                        child(
                            w!("STATIC"),
                            &percent_label(*value),
                            0x0002, // SS_RIGHT
                            *id + VALUE_LABEL_OFFSET,
                            (width - pad - value_w, y + px(7.0), value_w, px(18.0)),
                            font,
                        );
                        y += row_h;
                    }
                    Item::Note(text) => {
                        child(w!("STATIC"), text, 0, 1, (pad, y + px(6.0), width - pad * 2, px(18.0)), font);
                        y += px(26.0);
                    }
                }
            }

            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
            self.current.set(Some(hwnd));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slider_ids_round_trip() {
        for i in 0..8 {
            for v in [false, true] {
                assert_eq!(decode_id(encode_id(i, v)), Some((i, v)));
            }
        }
        assert_eq!(decode_id(5), None);
    }
}
