//! Finds connected monitors through `/sys/class/drm`: each connector directory
//! (`card1-HDMI-A-1`) has its status, EDID and, for most drivers (amdgpu, i915, nouveau,
//! vc4 on the Raspberry Pi), a link to the I²C bus that carries its DDC channel. Built-in
//! panels (eDP/LVDS/DSI) have no DDC; their brightness is a `/sys/class/backlight` device.
//!
//! Everything takes a sysfs root so tests can run against a fake tree.

use std::fs;
use std::path::{Path, PathBuf};

use crate::edid;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Connector {
    /// DRM connector name without the card prefix, e.g. "HDMI-A-1", "DP-2", "eDP-1".
    pub connector: String,
    /// Display name: EDID product name, else manufacturer + product, else the connector.
    pub name: String,
    pub internal: bool,
    pub edid: Vec<u8>,
    /// `/dev/i2c-N` for the DDC channel, when the driver links it.
    pub i2c_bus: Option<u32>,
}

/// Built-in panel connector types.
fn is_internal(connector: &str) -> bool {
    ["eDP", "LVDS", "DSI", "DPI"].iter().any(|p| connector.starts_with(p))
}

fn bus_number(name: &str) -> Option<u32> {
    name.strip_prefix("i2c-")?.parse().ok()
}

/// The connector's DDC bus: the `ddc` symlink (i915, vc4, nouveau) or an `i2c-N`
/// directory inside the connector (amdgpu).
fn ddc_bus(dir: &Path) -> Option<u32> {
    if let Ok(target) = fs::read_link(dir.join("ddc")) {
        if let Some(n) = target.file_name().and_then(|f| f.to_str()).and_then(bus_number) {
            return Some(n);
        }
    }
    fs::read_dir(dir).ok()?.flatten().find_map(|e| e.file_name().to_str().and_then(bus_number))
}

/// Connected monitors, internal panels included, in a stable order.
pub fn scan(sys_root: &Path) -> Vec<Connector> {
    let Ok(entries) = fs::read_dir(sys_root.join("class/drm")) else { return Vec::new() };
    let mut out: Vec<(String, Connector)> = Vec::new();
    for e in entries.flatten() {
        let file = e.file_name().to_string_lossy().to_string();
        // "card1-HDMI-A-1" → "HDMI-A-1"; skip "card1", "renderD128", "version".
        let Some(rest) = file.strip_prefix("card") else { continue };
        let Some((_, connector)) = rest.split_once('-') else { continue };
        let dir = e.path();
        let status = fs::read_to_string(dir.join("status")).unwrap_or_default();
        if status.trim() != "connected" {
            continue;
        }
        let edid = fs::read(dir.join("edid")).unwrap_or_default();
        let internal = is_internal(connector);
        let name = edid::monitor_name(&edid).unwrap_or_else(|| connector.to_string());
        let i2c_bus = if internal { None } else { ddc_bus(&dir) };
        out.push((file.clone(), Connector { connector: connector.to_string(), name, internal, edid, i2c_bus }));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out.into_iter().map(|(_, c)| c).collect()
}

/// I²C buses that might carry DDC for a monitor whose driver doesn't link one (NVIDIA's
/// proprietary driver): every adapter except the motherboard's SMBus controllers.
pub fn candidate_buses(sys_root: &Path) -> Vec<u32> {
    let Ok(entries) = fs::read_dir(sys_root.join("bus/i2c/devices")) else { return Vec::new() };
    let mut buses: Vec<u32> = entries
        .flatten()
        .filter_map(|e| {
            let n = bus_number(&e.file_name().to_string_lossy())?;
            let name = fs::read_to_string(e.path().join("name")).unwrap_or_default().to_lowercase();
            let smbus = ["smbus", "i801", "piix4", "designware", "sbus", "ec "].iter().any(|s| name.contains(s));
            (!smbus).then_some(n)
        })
        .collect();
    buses.sort_unstable();
    buses
}

/// The laptop/Steam Deck panel's backlight device, preferring what logind and desktops
/// prefer: "raw" (the GPU's own, e.g. amdgpu_bl0, intel_backlight), then "platform", then
/// "firmware" (ACPI).
pub fn backlight(sys_root: &Path) -> Option<String> {
    let entries = fs::read_dir(sys_root.join("class/backlight")).ok()?;
    let mut found: Vec<(usize, String)> = entries
        .flatten()
        .map(|e| {
            let kind = fs::read_to_string(e.path().join("type")).unwrap_or_default();
            let rank = match kind.trim() {
                "raw" => 0,
                "platform" => 1,
                _ => 2,
            };
            (rank, e.file_name().to_string_lossy().to_string())
        })
        .collect();
    found.sort();
    found.into_iter().next().map(|(_, n)| n)
}

/// Current and maximum raw backlight level.
pub fn backlight_level(sys_root: &Path, name: &str) -> Option<(u32, u32)> {
    let dir: PathBuf = sys_root.join("class/backlight").join(name);
    let read = |f: &str| fs::read_to_string(dir.join(f)).ok()?.trim().parse::<u32>().ok();
    let max = read("max_brightness")?;
    let cur = read("brightness")?;
    (max > 0).then_some((cur.min(max), max))
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::edid::tests::fake_edid;
    use std::os::unix::fs::symlink;

    pub struct FakeSys(pub PathBuf);

    impl FakeSys {
        pub fn new(tag: &str) -> FakeSys {
            let root = std::env::temp_dir().join(format!("glint-sys-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("class/drm")).unwrap();
            fs::create_dir_all(root.join("class/backlight")).unwrap();
            fs::create_dir_all(root.join("bus/i2c/devices")).unwrap();
            FakeSys(root)
        }

        pub fn connector(&self, dir: &str, status: &str, edid: &[u8]) -> PathBuf {
            let d = self.0.join("class/drm").join(dir);
            fs::create_dir_all(&d).unwrap();
            fs::write(d.join("status"), format!("{status}\n")).unwrap();
            fs::write(d.join("edid"), edid).unwrap();
            d
        }

        pub fn adapter(&self, n: u32, name: &str) {
            let d = self.0.join(format!("bus/i2c/devices/i2c-{n}"));
            fs::create_dir_all(&d).unwrap();
            fs::write(d.join("name"), format!("{name}\n")).unwrap();
        }

        pub fn backlight(&self, name: &str, kind: &str, cur: u32, max: u32) {
            let d = self.0.join("class/backlight").join(name);
            fs::create_dir_all(&d).unwrap();
            fs::write(d.join("type"), format!("{kind}\n")).unwrap();
            fs::write(d.join("brightness"), format!("{cur}\n")).unwrap();
            fs::write(d.join("max_brightness"), format!("{max}\n")).unwrap();
        }
    }

    impl Drop for FakeSys {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn finds_connected_monitors_and_their_buses() {
        let sys = FakeSys::new("scan");
        // i915/vc4 style: a `ddc` symlink to the adapter.
        let hdmi = sys.connector("card1-HDMI-A-1", "connected", &fake_edid("DEL", 0xA0B5, Some("DELL U2720Q")));
        symlink("../../i2c-7", hdmi.join("ddc")).unwrap();
        // amdgpu style: an i2c-N directory inside the connector.
        let dp = sys.connector("card1-DP-2", "connected", &fake_edid("GSM", 1, None));
        fs::create_dir_all(dp.join("i2c-12")).unwrap();
        // Laptop panel, disconnected port, and non-connector entries.
        sys.connector("card1-eDP-1", "connected", &fake_edid("BOE", 2, Some("Panel")));
        sys.connector("card1-HDMI-A-2", "disconnected", &[]);
        fs::create_dir_all(sys.0.join("class/drm/card1")).unwrap();
        fs::create_dir_all(sys.0.join("class/drm/renderD128")).unwrap();

        let found = scan(&sys.0);
        let summary: Vec<_> =
            found.iter().map(|c| (c.connector.as_str(), c.name.as_str(), c.internal, c.i2c_bus)).collect();
        assert_eq!(
            summary,
            vec![
                ("DP-2", "GSM 0001", false, Some(12)),
                ("HDMI-A-1", "DELL U2720Q", false, Some(7)),
                ("eDP-1", "Panel", true, None),
            ]
        );
    }

    #[test]
    fn names_fall_back_to_the_connector() {
        let sys = FakeSys::new("noedid");
        sys.connector("card0-HDMI-A-1", "connected", &[]);
        assert_eq!(scan(&sys.0)[0].name, "HDMI-A-1");
    }

    #[test]
    fn candidate_buses_skip_smbus() {
        let sys = FakeSys::new("buses");
        sys.adapter(0, "SMBus I801 adapter at efa0");
        sys.adapter(3, "NVIDIA i2c adapter 1 at 1:00.0");
        sys.adapter(4, "NVIDIA i2c adapter 3 at 1:00.0");
        sys.adapter(9, "Synopsys DesignWare I2C adapter");
        assert_eq!(candidate_buses(&sys.0), vec![3, 4]);
    }

    #[test]
    fn picks_the_raw_backlight() {
        let sys = FakeSys::new("bl");
        sys.backlight("acpi_video0", "firmware", 5, 10);
        sys.backlight("amdgpu_bl0", "raw", 128, 255);
        assert_eq!(backlight(&sys.0).as_deref(), Some("amdgpu_bl0"));
        assert_eq!(backlight_level(&sys.0, "amdgpu_bl0"), Some((128, 255)));
        assert_eq!(backlight_level(&sys.0, "missing"), None);
    }
}
