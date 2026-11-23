//! UI strings in the Mac app's languages (de, es, fr, it, ja, ko, pt-BR, zh-Hans), picked
//! from the Windows display language. English is the key; anything else falls back to it.

use std::sync::OnceLock;

use crate::strings::TABLE;

static LANG: OnceLock<Option<usize>> = OnceLock::new();

/// Maps a Windows LANGID to a column of the string table.
pub fn lang_index(langid: u16) -> Option<usize> {
    let primary = langid & 0x3FF;
    let sub = langid >> 10;
    match primary {
        0x07 => Some(0), // German
        0x0A => Some(1), // Spanish
        0x0C => Some(2), // French
        0x10 => Some(3), // Italian
        0x11 => Some(4), // Japanese
        0x12 => Some(5), // Korean
        0x16 => Some(6), // Portuguese (pt-BR strings)
        // Simplified Chinese only (PRC, Singapore); Traditional stays English.
        0x04 if sub == 0x02 || sub == 0x04 => Some(7),
        _ => None,
    }
}

fn lookup(key: &'static str, lang: Option<usize>) -> &'static str {
    let Some(col) = lang else { return key };
    match TABLE.binary_search_by(|(k, _)| (*k).cmp(key)) {
        Ok(i) => TABLE[i].1[col],
        Err(_) => key,
    }
}

#[cfg(windows)]
fn detect() -> Option<usize> {
    // SAFETY: no arguments.
    lang_index(unsafe { windows::Win32::Globalization::GetUserDefaultUILanguage() })
}

#[cfg(not(windows))]
fn detect() -> Option<usize> {
    None
}

/// The UI string for `key` (its English text) in the user's language.
pub fn t(key: &'static str) -> &'static str {
    lookup(key, *LANG.get_or_init(detect))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn languages_map_to_columns() {
        assert_eq!(lang_index(0x0407), Some(0)); // de-DE
        assert_eq!(lang_index(0x0807), Some(0)); // de-CH
        assert_eq!(lang_index(0x0416), Some(6)); // pt-BR
        assert_eq!(lang_index(0x0816), Some(6)); // pt-PT gets pt-BR
        assert_eq!(lang_index(0x0804), Some(7)); // zh-CN
        assert_eq!(lang_index(0x0404), None); // zh-TW stays English
        assert_eq!(lang_index(0x0409), None); // en-US
        assert_eq!(lang_index(0x0411), Some(4)); // ja-JP
    }

    #[test]
    fn table_is_sorted_and_complete() {
        for pair in TABLE.windows(2) {
            assert!(pair[0].0 < pair[1].0, "TABLE must be sorted: {:?}", pair[1].0);
        }
        for (k, v) in TABLE.iter() {
            assert!(v.iter().all(|s| !s.is_empty()), "missing translation for {k:?}");
        }
    }

    #[test]
    fn lookup_falls_back_to_english() {
        assert_eq!(lookup("Volume step", None), "Volume step");
        assert_eq!(lookup("Volume step", Some(0)), "Lautstärkeschritt");
        assert_eq!(lookup("not a key", Some(0)), "not a key");
    }

    /// Every `t("...")` in the source must have translations.
    #[test]
    fn every_ui_string_is_translated() {
        let sources = [
            include_str!("app.rs"),
            include_str!("flyout.rs"),
            include_str!("osd.rs"),
            include_str!("ddc.rs"),
            include_str!("logic.rs"),
        ];
        let mut missing = Vec::new();
        let mut found = 0;
        for src in sources {
            for part in src.split("t(\"").skip(1) {
                let key = &part[..part.find("\")").expect("closing quote")];
                found += 1;
                if TABLE.binary_search_by(|(k, _)| (*k).cmp(key)).is_err() {
                    missing.push(key.to_string());
                }
            }
        }
        assert!(found > 20, "expected the UI to use t(), found {found}");
        assert!(missing.is_empty(), "untranslated: {missing:?}");
    }
}
