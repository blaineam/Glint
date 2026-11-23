//! Tray icon (freedesktop StatusNotifierItem): KDE Plasma, SteamOS Desktop Mode, XFCE,
//! LXQt, Cinnamon, Budgie, Ubuntu's GNOME (AppIndicator extension) and Raspberry Pi OS's
//! panel. Same settings menu as the Windows app; SNI menus have no sliders, so displays get
//! 10% levels. Without a tray host Glint keeps working; `glint` on the command line and the
//! config file still reach every setting.

use std::sync::mpsc::Sender;

use glint_core::i18n::t;
use glint_core::logic::{percent_label, HotkeyScheme, Settings, STEP_OPTIONS};
use ksni::menu::{CheckmarkItem, RadioGroup, RadioItem, StandardItem, SubMenu};
use ksni::{Icon, MenuItem, ToolTip};

use crate::app::{MenuCmd, Msg};
use crate::worker::DisplayInfo;

pub struct GlintTray {
    pub tx: Sender<Msg>,
    pub displays: Vec<DisplayInfo>,
    pub settings: Settings,
    pub login: bool,
    /// Keys can't be taken from the desktop (no uinput): shown so it isn't a mystery.
    pub passive: bool,
}

fn send(c: MenuCmd) -> Box<dyn Fn(&mut GlintTray) + Send> {
    Box::new(move |t: &mut GlintTray| {
        let _ = t.tx.send(Msg::Menu(c.clone()));
    })
}

fn item(label: impl Into<String>, c: MenuCmd) -> MenuItem<GlintTray> {
    StandardItem { label: label.into(), activate: send(c), ..Default::default() }.into()
}

fn check(label: impl Into<String>, checked: bool, enabled: bool, c: MenuCmd) -> MenuItem<GlintTray> {
    CheckmarkItem { label: label.into(), checked, enabled, activate: send(c), ..Default::default() }.into()
}

fn info(label: impl Into<String>) -> MenuItem<GlintTray> {
    StandardItem { label: label.into(), enabled: false, ..Default::default() }.into()
}

fn submenu(label: impl Into<String>, enabled: bool, items: Vec<MenuItem<GlintTray>>) -> MenuItem<GlintTray> {
    SubMenu { label: label.into(), enabled, submenu: items, ..Default::default() }.into()
}

fn radio(selected: usize, labels: Vec<String>, f: fn(usize) -> MenuCmd) -> MenuItem<GlintTray> {
    RadioGroup {
        selected,
        select: Box::new(move |t: &mut GlintTray, i| {
            let _ = t.tx.send(Msg::Menu(f(i)));
        }),
        options: labels.into_iter().map(|label| RadioItem { label, ..Default::default() }).collect(),
    }
    .into()
}

fn step_label(step: f64) -> String {
    if step.fract() == 0.0 {
        format!("{}%", step as i64)
    } else {
        format!("{step}%")
    }
}

/// Indent for options that depend on the one above (as in the Windows menu).
fn sub(label: &str) -> String {
    format!("    {label}")
}

fn levels(index: usize, volume: bool, current: f64) -> MenuItem<GlintTray> {
    // Ten-percent steps, highest first.
    let selected = 10 - ((current / 10.0).round() as usize).min(10);
    RadioGroup {
        selected,
        select: Box::new(move |t: &mut GlintTray, i| {
            let _ = t.tx.send(Msg::Menu(MenuCmd::Level { index, volume, percent: (10 - i) as f64 * 10.0 }));
        }),
        options: (0..=10).rev().map(|l| RadioItem { label: format!("{}%", l * 10), ..Default::default() }).collect(),
    }
    .into()
}

impl ksni::Tray for GlintTray {
    fn id(&self) -> String {
        "glint".into()
    }

    fn title(&self) -> String {
        "Glint".into()
    }

    fn icon_name(&self) -> String {
        "glint".into()
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        let icon = |n: i32, data: &[u8]| Icon { width: n, height: n, data: data.to_vec() };
        vec![
            icon(22, include_bytes!("../res/icon-22.argb")),
            icon(32, include_bytes!("../res/icon-32.argb")),
            icon(48, include_bytes!("../res/icon-48.argb")),
            icon(64, include_bytes!("../res/icon-64.argb")),
        ]
    }

    fn tool_tip(&self) -> ToolTip {
        let description = self
            .displays
            .iter()
            .filter_map(|d| d.brightness.map(|b| format!("{} {}", d.name, percent_label(b))))
            .collect::<Vec<_>>()
            .join("\n");
        ToolTip { title: "Glint".into(), description, ..Default::default() }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let s = &self.settings;
        let mut m: Vec<MenuItem<Self>> = vec![info(format!("Glint {}", crate::VERSION)), MenuItem::Separator];

        let controllable: Vec<_> =
            self.displays.iter().enumerate().filter(|(_, d)| d.brightness.is_some() || d.volume.is_some()).collect();
        if controllable.is_empty() {
            m.push(info(t("No display answered DDC/CI")));
        }
        for (i, d) in controllable {
            let mut sub_items = Vec::new();
            if let Some(b) = d.brightness {
                sub_items.push(submenu(
                    format!("{}: {}", t("Brightness"), percent_label(b)),
                    true,
                    vec![levels(i, false, b)],
                ));
            }
            if let Some(v) = d.volume {
                sub_items.push(submenu(
                    format!("{}: {}", t("Volume"), percent_label(v)),
                    true,
                    vec![levels(i, true, v)],
                ));
            }
            let mut label = if d.internal && d.name != t("Built-in display") {
                format!("{} {}", d.name, t("(built-in)"))
            } else {
                d.name.clone()
            };
            if let Some(b) = d.brightness {
                label.push_str(&format!(" \u{2014} {}", percent_label(b)));
            }
            m.push(submenu(label, true, sub_items));
        }
        m.push(MenuItem::Separator);

        let hotkey_index = HotkeyScheme::ALL.iter().position(|h| *h == s.hotkeys).unwrap_or(0);
        let step_index = |v: f64| STEP_OPTIONS.iter().position(|x| *x == v).unwrap_or(5);
        let mut keyboard = vec![
            check(t("Intercept brightness keys"), s.intercept_brightness, true, MenuCmd::InterceptBrightness),
            check(
                sub(t("Always intercept brightness")),
                s.always_brightness,
                s.intercept_brightness,
                MenuCmd::AlwaysBrightness,
            ),
            submenu(
                sub(&format!("{}: {}", t("Brightness hotkeys"), s.hotkeys.label())),
                s.intercept_brightness,
                vec![radio(hotkey_index, HotkeyScheme::ALL.iter().map(|h| h.label()).collect(), MenuCmd::Hotkeys)],
            ),
            MenuItem::Separator,
            check(t("Intercept volume keys"), s.route_volume, true, MenuCmd::InterceptVolume),
            check(sub(t("Always intercept volume")), s.always_volume, s.route_volume, MenuCmd::AlwaysVolume),
            check(sub(t("Write-only volume")), s.write_only_volume, s.route_volume, MenuCmd::WriteOnlyVolume),
            MenuItem::Separator,
            submenu(
                format!("{}: {}", t("Brightness step"), step_label(s.brightness_step)),
                true,
                vec![radio(
                    step_index(s.brightness_step),
                    STEP_OPTIONS.iter().map(|v| step_label(*v)).collect(),
                    MenuCmd::BrightnessStep,
                )],
            ),
            submenu(
                format!("{}: {}", t("Volume step"), step_label(s.volume_step)),
                true,
                vec![radio(
                    step_index(s.volume_step),
                    STEP_OPTIONS.iter().map(|v| step_label(*v)).collect(),
                    MenuCmd::VolumeStep,
                )],
            ),
            MenuItem::Separator,
            check(t("Sync all displays and system volume"), s.sync, true, MenuCmd::Sync),
        ];
        if self.passive {
            keyboard.push(MenuItem::Separator);
            keyboard.push(info(t("Keys can't be taken from the desktop. Run sudo glint setup once.")));
        }
        m.push(submenu(t("Keyboard Controls"), true, keyboard));
        m.push(check(t("Show on-screen indicator"), s.show_osd, true, MenuCmd::Osd));
        m.push(check(t("Launch at login"), self.login, true, MenuCmd::LaunchAtLogin));
        m.push(item(t("Hide tray icon…"), MenuCmd::HideTray));
        m.push(item(t("Rescan displays"), MenuCmd::Rescan));
        m.push(MenuItem::Separator);
        m.push(submenu(
            t("Diagnostics"),
            true,
            vec![
                check(t("Debug logging"), s.debug_logging, true, MenuCmd::DebugLogging),
                item(t("Open log folder"), MenuCmd::OpenLog),
            ],
        ));
        m.push(item(t("Glint website"), MenuCmd::Website));
        m.push(item(t("Support future development"), MenuCmd::Support));
        m.push(MenuItem::Separator);
        m.push(item(t("Quit Glint"), MenuCmd::Quit));
        m
    }
}
