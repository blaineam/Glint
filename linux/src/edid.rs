//! Just enough EDID to name a monitor ("DELL U2720Q") and tell two apart.

/// The monitor's name: the EDID "display product name" descriptor (0xFC), else the
/// manufacturer ID and product code ("DEL A0B5").
pub fn monitor_name(edid: &[u8]) -> Option<String> {
    if edid.len() < 128 || edid[..8] != [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] {
        return None;
    }
    for start in [54, 72, 90, 108] {
        let d = &edid[start..start + 18];
        if d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 0xFC {
            let text: String = d[5..18]
                .iter()
                .take_while(|&&b| b != 0x0A && b != 0)
                .map(|&b| if b.is_ascii_graphic() || b == b' ' { b as char } else { ' ' })
                .collect();
            let text = text.trim();
            if !text.is_empty() {
                return Some(text.to_string());
            }
        }
    }
    let (mfg, product) = ids(edid)?;
    Some(format!("{mfg} {product:04X}"))
}

/// Manufacturer PNP ID (three letters) and product code.
pub fn ids(edid: &[u8]) -> Option<(String, u16)> {
    if edid.len() < 12 {
        return None;
    }
    let v = u16::from_be_bytes([edid[8], edid[9]]);
    let letter = |shift: u16| (b'A' - 1 + ((v >> shift) & 0x1F) as u8) as char;
    let mfg: String = [letter(10), letter(5), letter(0)].into_iter().collect();
    if !mfg.chars().all(|c| c.is_ascii_uppercase()) {
        return None;
    }
    Some((mfg, u16::from_le_bytes([edid[10], edid[11]])))
}

/// Whether two EDID blobs describe the same monitor (first 128 bytes, the base block).
pub fn same_monitor(a: &[u8], b: &[u8]) -> bool {
    a.len() >= 128 && b.len() >= 128 && a[..128] == b[..128]
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A minimal valid base EDID block for tests: manufacturer, product and a name.
    pub fn fake_edid(mfg: &str, product: u16, name: Option<&str>) -> Vec<u8> {
        let mut e = vec![0u8; 128];
        e[..8].copy_from_slice(&[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
        let b = mfg.as_bytes();
        let v = ((b[0] - b'A' + 1) as u16) << 10 | ((b[1] - b'A' + 1) as u16) << 5 | (b[2] - b'A' + 1) as u16;
        e[8..10].copy_from_slice(&v.to_be_bytes());
        e[10..12].copy_from_slice(&product.to_le_bytes());
        if let Some(n) = name {
            let d = &mut e[72..90];
            d[3] = 0xFC;
            for (i, c) in n.bytes().take(13).enumerate() {
                d[5 + i] = c;
            }
            if n.len() < 13 {
                d[5 + n.len()] = 0x0A;
                for x in d.iter_mut().skip(6 + n.len()) {
                    *x = 0x20;
                }
            }
        }
        e
    }

    #[test]
    fn reads_the_product_name() {
        assert_eq!(monitor_name(&fake_edid("DEL", 0xA0B5, Some("DELL U2720Q"))), Some("DELL U2720Q".into()));
        assert_eq!(monitor_name(&fake_edid("GSM", 0x5B7F, Some("LG HDR 4K"))), Some("LG HDR 4K".into()));
    }

    #[test]
    fn falls_back_to_ids() {
        assert_eq!(monitor_name(&fake_edid("DEL", 0xA0B5, None)), Some("DEL A0B5".into()));
        assert_eq!(ids(&fake_edid("SAM", 0x1234, None)), Some(("SAM".into(), 0x1234)));
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(monitor_name(&[0u8; 128]), None);
        assert_eq!(monitor_name(&[]), None);
    }

    #[test]
    fn compares_base_blocks() {
        let a = fake_edid("DEL", 1, Some("A"));
        let mut a_ext = a.clone();
        a_ext.extend_from_slice(&[1u8; 128]);
        assert!(same_monitor(&a, &a_ext));
        assert!(!same_monitor(&a, &fake_edid("DEL", 2, Some("A"))));
        assert!(!same_monitor(&a, &[]));
    }
}
