//! Audio through `pactl`, which talks to PulseAudio and to PipeWire (pipewire-pulse) alike,
//! from Rocky 8's PulseAudio 14 to current PipeWire. Run with `LC_ALL=C` so the output is
//! always English. The parsing is pure and tested; `run` shells out.

use std::process::Command;

/// The playing sink, as far as Glint cares.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sink {
    pub name: String,
    /// Active port description first (for HDMI/DP this is the monitor's ELD name, e.g.
    /// "DELL U2720Q"), then the sink description.
    pub names: Vec<String>,
    pub is_display: bool,
    pub volume: Option<f64>,
    pub muted: bool,
}

fn run(args: &[&str]) -> Option<String> {
    let out = Command::new("pactl").args(args).env("LC_ALL", "C").output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The default sink's name from `pactl info`.
pub fn parse_default_sink(info: &str) -> Option<String> {
    info.lines().find_map(|l| l.strip_prefix("Default Sink: ")).map(|s| s.trim().to_string())
}

/// The named sink from `pactl list sinks`.
pub fn parse_sink(list: &str, wanted: &str) -> Option<Sink> {
    let mut blocks: Vec<Vec<&str>> = Vec::new();
    for line in list.lines() {
        if line.starts_with("Sink #") {
            blocks.push(Vec::new());
        } else if let Some(b) = blocks.last_mut() {
            b.push(line);
        }
    }
    for block in blocks {
        let field =
            |key: &str| block.iter().find_map(|l| l.trim_start().strip_prefix(key)).map(|v| v.trim().to_string());
        if field("Name: ").as_deref() != Some(wanted) {
            continue;
        }
        let description = field("Description: ").unwrap_or_default();
        let active = field("Active Port: ").unwrap_or_default();
        // "\t\thdmi-output-0: DELL U2720Q (type: HDMI, priority: 5900, available)"
        let port_description = block.iter().find_map(|l| {
            let (port, rest) = l.trim_start().split_once(": ")?;
            (port == active && !active.is_empty()).then(|| rest.split(" (").next().unwrap_or(rest).trim().to_string())
        });
        let volume = field("Volume: ")
            .and_then(|v| v.split('/').find_map(|part| part.trim().strip_suffix('%')?.trim().parse::<f64>().ok()));
        let muted = field("Mute: ").as_deref() == Some("yes");
        let text = format!("{wanted} {active} {description}").to_lowercase();
        let is_display = text.contains("hdmi") || text.contains("displayport") || text.contains("dp-");
        let mut names = Vec::new();
        if let Some(p) = port_description.filter(|p| !p.is_empty() && !p.eq_ignore_ascii_case("HDMI / DisplayPort")) {
            names.push(p);
        }
        if !description.is_empty() {
            names.push(description);
        }
        return Some(Sink { name: wanted.to_string(), names, is_display, volume, muted });
    }
    None
}

/// The playing sink, or None when no sound server is reachable.
pub fn default_sink() -> Option<Sink> {
    let name = parse_default_sink(&run(&["info"])?)?;
    parse_sink(&run(&["list", "sinks"])?, &name)
}

pub fn set_volume(percent: f64) -> bool {
    run(&["set-sink-volume", "@DEFAULT_SINK@", &format!("{}%", percent.clamp(0.0, 100.0).round())]).is_some()
}

pub fn set_mute(muted: bool) -> bool {
    run(&["set-sink-mute", "@DEFAULT_SINK@", if muted { "1" } else { "0" }]).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = "Server String: /run/user/1000/pulse/native\nServer Name: PulseAudio (on PipeWire 1.0.5)\nDefault Sink: alsa_output.pci-0000_01_00.1.hdmi-stereo\nDefault Source: x\n";

    const SINKS: &str = "Sink #50
\tState: RUNNING
\tName: alsa_output.pci-0000_00_1f.3.analog-stereo
\tDescription: Built-in Audio Analog Stereo
\tMute: no
\tVolume: front-left: 32768 /  50% / -18.06 dB,   front-right: 32768 /  50% / -18.06 dB
\tActive Port: analog-output-speaker
\tPorts:
\t\tanalog-output-speaker: Speakers (type: Speaker, priority: 10000, availability unknown)

Sink #61
\tState: RUNNING
\tName: alsa_output.pci-0000_01_00.1.hdmi-stereo
\tDescription: GA104 High Definition Audio Controller Digital Stereo (HDMI)
\tMute: yes
\tVolume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB
\tActive Port: hdmi-output-0
\tPorts:
\t\thdmi-output-0: DELL U2720Q (type: HDMI, priority: 5900, available)
\t\thdmi-output-1: HDMI / DisplayPort 2 (type: HDMI, priority: 5800, not available)
";

    #[test]
    fn reads_the_default_sink() {
        assert_eq!(parse_default_sink(INFO).as_deref(), Some("alsa_output.pci-0000_01_00.1.hdmi-stereo"));
        assert_eq!(parse_default_sink("nothing"), None);
    }

    #[test]
    fn hdmi_sink_names_the_monitor() {
        let s = parse_sink(SINKS, "alsa_output.pci-0000_01_00.1.hdmi-stereo").unwrap();
        assert!(s.is_display);
        assert_eq!(s.names[0], "DELL U2720Q");
        assert_eq!(s.volume, Some(40.0));
        assert!(s.muted);
    }

    #[test]
    fn analog_sink_is_not_a_display() {
        let s = parse_sink(SINKS, "alsa_output.pci-0000_00_1f.3.analog-stereo").unwrap();
        assert!(!s.is_display);
        assert_eq!(s.names, vec!["Speakers".to_string(), "Built-in Audio Analog Stereo".to_string()]);
        assert_eq!(s.volume, Some(50.0));
        assert!(!s.muted);
    }

    #[test]
    fn unknown_sink() {
        assert_eq!(parse_sink(SINKS, "nope"), None);
    }

    #[test]
    fn generic_port_names_are_skipped() {
        let list = "Sink #1\n\tName: hdmi\n\tDescription: HDA NVidia Digital\n\tMute: no\n\tVolume: mono: 65536 / 100% / 0.00 dB\n\tActive Port: hdmi-output-0\n\tPorts:\n\t\thdmi-output-0: HDMI / DisplayPort (type: HDMI, priority: 5900, available)\n";
        let s = parse_sink(list, "hdmi").unwrap();
        assert_eq!(s.names, vec!["HDA NVidia Digital".to_string()]);
        assert_eq!(s.volume, Some(100.0));
    }
}
