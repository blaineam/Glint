//! The pill-shaped brightness/volume overlay. A click-through, never-activated layered
//! window drawn with per-pixel alpha so the rounded ends are antialiased.

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject, DrawTextW, GetMonitorInfoW,
    MonitorFromPoint, SelectObject, SetBkMode, SetTextColor, AC_SRC_ALPHA, AC_SRC_OVER, ANTIALIASED_QUALITY,
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS,
    DT_CENTER, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, FF_DONTCARE, FW_NORMAL, FW_SEMIBOLD, HDC, HGDIOBJ, MONITORINFO,
    MONITOR_DEFAULTTONEAREST, OUT_DEFAULT_PRECIS, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, GetCursorPos, KillTimer, RegisterClassW, SetTimer, SetWindowPos, ShowWindow,
    UpdateLayeredWindow, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, ULW_ALPHA,
    WM_TIMER, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

use crate::logic::percent_label;
use crate::worker::{OSD_BRIGHTNESS, OSD_MUTED};

const HIDE_TIMER: usize = 1;
const SHOW_MS: u32 = 1500;

// Segoe MDL2 Assets glyphs (present on Windows 10 and 11).
const GLYPH_BRIGHTNESS: &str = "\u{E706}";
const GLYPH_VOLUME: &str = "\u{E767}";
const GLYPH_MUTE: &str = "\u{E74F}";

pub struct Osd {
    hwnd: HWND,
}

unsafe extern "system" fn osd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_TIMER && wparam.0 == HIDE_TIMER {
        // SAFETY: our own window.
        unsafe {
            let _ = KillTimer(Some(hwnd), HIDE_TIMER);
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        return LRESULT(0);
    }
    // SAFETY: default handling.
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

impl Osd {
    pub fn new() -> Option<Osd> {
        // SAFETY: standard window class registration and creation.
        unsafe {
            let instance = GetModuleHandleW(None).ok()?;
            let class = WNDCLASSW {
                lpfnWndProc: Some(osd_proc),
                hInstance: instance.into(),
                lpszClassName: w!("GlintOSD"),
                ..Default::default()
            };
            RegisterClassW(&class);
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                w!("GlintOSD"),
                w!("Glint"),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(instance.into()),
                None,
            )
            .ok()?;
            Some(Osd { hwnd })
        }
    }

    /// Shows the overlay on the display under the cursor, near the bottom of its work area
    /// (where Windows 11 shows its own volume flyout), then hides it after 1.5 s.
    pub fn show(&self, kind: usize, percent: f64) {
        // SAFETY: GDI and window calls on handles created and released here.
        unsafe {
            let mut cursor = POINT::default();
            let _ = GetCursorPos(&mut cursor);
            let hmon = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if !GetMonitorInfoW(hmon, &mut info).as_bool() {
                return;
            }
            let (mut dpi_x, mut dpi_y) = (96u32, 96u32);
            let _ = GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y);
            let scale = dpi_x as f64 / 96.0;
            let w = (240.0 * scale).round() as i32;
            let h = (48.0 * scale).round() as i32;
            let work = info.rcWork;
            let x = work.left + (work.right - work.left - w) / 2;
            let y = work.bottom - h - (56.0 * scale).round() as i32;

            let glyph = match kind {
                OSD_BRIGHTNESS => GLYPH_BRIGHTNESS,
                OSD_MUTED => GLYPH_MUTE,
                _ => GLYPH_VOLUME,
            };
            let label = if kind == OSD_MUTED {
                "Muted".to_string()
            } else {
                percent_label(percent)
            };
            let fraction = if kind == OSD_MUTED {
                0.0
            } else {
                (percent / 100.0).clamp(0.0, 1.0)
            };

            let screen_dc = HDC::default();
            let mem = CreateCompatibleDC(Some(screen_dc));
            let bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
            let Ok(bmp) = CreateDIBSection(Some(mem), &bmi, DIB_RGB_COLORS, &mut bits, None, 0) else {
                let _ = DeleteDC(mem);
                return;
            };
            let old = SelectObject(mem, HGDIOBJ(bmp.0));
            let pixels = std::slice::from_raw_parts_mut(bits as *mut u32, (w * h) as usize);
            pixels.fill(0);

            // 1. Text coverage: white text on black, grayscale antialiased.
            SetBkMode(mem, TRANSPARENT);
            SetTextColor(mem, COLORREF(0x00FF_FFFF));
            let glyph_font = font((20.0 * scale) as i32, FW_NORMAL.0 as i32, w!("Segoe MDL2 Assets"));
            let text_font = font((15.0 * scale) as i32, FW_SEMIBOLD.0 as i32, w!("Segoe UI"));
            let prev_font = SelectObject(mem, HGDIOBJ(glyph_font.0));
            let mut glyph_rect = RECT {
                left: 0,
                top: 0,
                right: h,
                bottom: h,
            };
            let mut g: Vec<u16> = glyph.encode_utf16().collect();
            DrawTextW(mem, &mut g, &mut glyph_rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            SelectObject(mem, HGDIOBJ(text_font.0));
            let pad = (18.0 * scale) as i32;
            let mut text_rect = RECT {
                left: w - (64.0 * scale) as i32,
                top: 0,
                right: w - pad,
                bottom: h,
            };
            let mut t: Vec<u16> = label.encode_utf16().collect();
            DrawTextW(mem, &mut t, &mut text_rect, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
            SelectObject(mem, prev_font);
            let _ = DeleteObject(HGDIOBJ(glyph_font.0));
            let _ = DeleteObject(HGDIOBJ(text_font.0));
            let coverage: Vec<f64> = pixels.iter().map(|p| ((p >> 16) & 0xFF) as f64 / 255.0).collect();

            // 2. Compose pill + bar + text with premultiplied alpha.
            let bar_left = h as f64;
            let bar_right = (w - (72.0 * scale) as i32) as f64;
            let bar_h = 6.0 * scale;
            let bar_y = h as f64 / 2.0;
            let fill_right = bar_left + (bar_right - bar_left) * fraction;
            for py in 0..h {
                for px in 0..w {
                    let (fx, fy) = (px as f64 + 0.5, py as f64 + 0.5);
                    let pill = coverage_round_rect(fx, fy, 0.0, 0.0, w as f64, h as f64, h as f64 / 2.0);
                    let mut c = Premul::new(28, 28, 30, 0.90 * pill);
                    let track = coverage_round_rect(
                        fx,
                        fy,
                        bar_left,
                        bar_y - bar_h / 2.0,
                        bar_right,
                        bar_y + bar_h / 2.0,
                        bar_h / 2.0,
                    );
                    if track > 0.0 {
                        c = c.over(255, 255, 255, 0.22 * track);
                    }
                    if fill_right > bar_left {
                        let fill = coverage_round_rect(
                            fx,
                            fy,
                            bar_left,
                            bar_y - bar_h / 2.0,
                            fill_right.max(bar_left + bar_h),
                            bar_y + bar_h / 2.0,
                            bar_h / 2.0,
                        );
                        if fill > 0.0 {
                            c = c.over(255, 255, 255, 0.95 * fill);
                        }
                    }
                    let text = coverage[(py * w + px) as usize];
                    if text > 0.0 {
                        c = c.over(255, 255, 255, text * pill);
                    }
                    pixels[(py * w + px) as usize] = c.pack();
                }
            }

            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            let _ = UpdateLayeredWindow(
                self.hwnd,
                None,
                Some(&POINT { x, y }),
                Some(&SIZE { cx: w, cy: h }),
                Some(mem),
                Some(&POINT { x: 0, y: 0 }),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            );
            SelectObject(mem, old);
            let _ = DeleteObject(HGDIOBJ(bmp.0));
            let _ = DeleteDC(mem);

            let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
            SetTimer(Some(self.hwnd), HIDE_TIMER, SHOW_MS, None);
        }
    }
}

fn font(height: i32, weight: i32, face: PCWSTR) -> windows::Win32::Graphics::Gdi::HFONT {
    // SAFETY: creates a GDI font the caller deletes.
    unsafe {
        CreateFontW(
            -height,
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
            face,
        )
    }
}

/// Antialiased coverage of a pixel center by a rounded rectangle (signed distance).
fn coverage_round_rect(x: f64, y: f64, l: f64, t: f64, r: f64, b: f64, radius: f64) -> f64 {
    let cx = (l + r) / 2.0;
    let cy = (t + b) / 2.0;
    let hx = (r - l) / 2.0 - radius;
    let hy = (b - t) / 2.0 - radius;
    let qx = ((x - cx).abs() - hx).max(0.0);
    let qy = ((y - cy).abs() - hy).max(0.0);
    let outside = (qx * qx + qy * qy).sqrt();
    let inside = ((x - cx).abs() - hx).max((y - cy).abs() - hy).min(0.0);
    let d = outside + inside - radius;
    (0.5 - d).clamp(0.0, 1.0)
}

/// A premultiplied BGRA pixel.
#[derive(Clone, Copy)]
struct Premul {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}

impl Premul {
    fn new(r: u8, g: u8, b: u8, a: f64) -> Premul {
        Premul {
            r: r as f64 * a,
            g: g as f64 * a,
            b: b as f64 * a,
            a,
        }
    }

    fn over(self, r: u8, g: u8, b: u8, a: f64) -> Premul {
        let top = Premul::new(r, g, b, a);
        Premul {
            r: top.r + self.r * (1.0 - a),
            g: top.g + self.g * (1.0 - a),
            b: top.b + self.b * (1.0 - a),
            a: top.a + self.a * (1.0 - a),
        }
    }

    fn pack(self) -> u32 {
        let c = |v: f64| v.round().clamp(0.0, 255.0) as u32;
        (c(self.a * 255.0) << 24) | (c(self.r) << 16) | (c(self.g) << 8) | c(self.b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_rect_coverage() {
        // Center fully covered, far outside not, corner outside the arc not.
        assert_eq!(coverage_round_rect(50.0, 10.0, 0.0, 0.0, 100.0, 20.0, 10.0), 1.0);
        assert_eq!(coverage_round_rect(150.0, 10.0, 0.0, 0.0, 100.0, 20.0, 10.0), 0.0);
        assert_eq!(coverage_round_rect(0.5, 0.5, 0.0, 0.0, 100.0, 20.0, 10.0), 0.0);
        // Exactly on the straight edge: half covered.
        assert!((coverage_round_rect(50.0, 0.0, 0.0, 0.0, 100.0, 20.0, 10.0) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn premultiplied_over() {
        let p = Premul::new(0, 0, 0, 0.0).over(255, 255, 255, 1.0).pack();
        assert_eq!(p, 0xFFFF_FFFF);
        let half = Premul::new(0, 0, 0, 0.0).over(255, 255, 255, 0.5).pack();
        assert_eq!(half >> 24, 128);
        assert_eq!(half & 0xFF, 128);
    }
}
