//! UI strings in the Mac app's languages (de, es, fr, it, ja, ko, pt-BR, zh-Hans). English
//! is the key; anything else falls back to it. Each app picks the language at startup with
//! `init` (Windows from its display-language LANGID, Linux from the POSIX locale).

use std::sync::OnceLock;

use crate::strings::TABLE;

static LANG: OnceLock<Option<usize>> = OnceLock::new();

/// Sets the UI language column once, before any `t()`. Later calls are ignored.
pub fn init(lang: Option<usize>) {
    let _ = LANG.set(lang);
}

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

/// Maps a POSIX locale ("de_DE.UTF-8", "pt_BR", "zh_CN.utf8", "C") to a column.
pub fn lang_index_from_locale(locale: &str) -> Option<usize> {
    let base = locale.split(['.', '@']).next().unwrap_or("");
    let mut parts = base.split(['_', '-']);
    let lang = parts.next().unwrap_or("").to_ascii_lowercase();
    let region = parts.next().unwrap_or("").to_ascii_uppercase();
    match lang.as_str() {
        "de" => Some(0),
        "es" => Some(1),
        "fr" => Some(2),
        "it" => Some(3),
        "ja" => Some(4),
        "ko" => Some(5),
        "pt" => Some(6),
        "zh" if matches!(region.as_str(), "CN" | "SG" | "HANS") => Some(7),
        _ => None,
    }
}

/// The POSIX locale the user's messages should use: LC_ALL, then LC_MESSAGES, then LANG,
/// the first that is set and not empty (as gettext resolves it).
pub fn posix_locale(get: impl Fn(&str) -> Option<String>) -> Option<String> {
    ["LC_ALL", "LC_MESSAGES", "LANG"].iter().filter_map(|k| get(k)).find(|v| !v.is_empty())
}

fn lookup(key: &str, lang: Option<usize>) -> Option<&'static str> {
    let i = TABLE.binary_search_by(|(k, _)| (*k).cmp(key)).ok()?;
    Some(match lang {
        Some(col) => TABLE[i].1[col],
        None => TABLE[i].0,
    })
}

/// Whether `key` has translations (used by each app's "every UI string is translated" test).
pub fn has_key(key: &str) -> bool {
    lookup(key, None).is_some()
}

/// The UI string for `key` (its English text) in the user's language.
pub fn t(key: &'static str) -> &'static str {
    lookup(key, LANG.get().copied().flatten()).unwrap_or(key)
}

/// Every `t("...")` key in a source file, for the per-app translation tests.
pub fn keys_in_source(src: &str) -> Vec<&str> {
    src.split("t(\"").skip(1).filter_map(|part| part.find("\")").map(|end| &part[..end])).collect()
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
    fn posix_locales_map_to_columns() {
        assert_eq!(lang_index_from_locale("de_DE.UTF-8"), Some(0));
        assert_eq!(lang_index_from_locale("fr_CA.utf8"), Some(2));
        assert_eq!(lang_index_from_locale("pt_BR"), Some(6));
        assert_eq!(lang_index_from_locale("zh_CN.UTF-8"), Some(7));
        assert_eq!(lang_index_from_locale("zh_TW.UTF-8"), None);
        assert_eq!(lang_index_from_locale("ja_JP.eucJP@euro"), Some(4));
        assert_eq!(lang_index_from_locale("C"), None);
        assert_eq!(lang_index_from_locale("C.UTF-8"), None);
        assert_eq!(lang_index_from_locale("en_US.UTF-8"), None);
    }

    #[test]
    fn locale_resolution_order() {
        let env = |vars: &'static [(&'static str, &'static str)]| {
            move |k: &str| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
        };
        assert_eq!(posix_locale(env(&[("LANG", "de_DE.UTF-8")])), Some("de_DE.UTF-8".into()));
        assert_eq!(posix_locale(env(&[("LANG", "de_DE"), ("LC_MESSAGES", "fr_FR")])), Some("fr_FR".into()));
        assert_eq!(posix_locale(env(&[("LANG", "de_DE"), ("LC_ALL", "")])), Some("de_DE".into()));
        assert_eq!(posix_locale(env(&[])), None);
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
        assert_eq!(lookup("Volume step", None), Some("Volume step"));
        assert_eq!(lookup("Volume step", Some(0)), Some("Lautstärkeschritt"));
        assert_eq!(lookup("not a key", Some(0)), None);
        assert!(has_key("Volume step"));
        // Hotkey key names follow local keyboards.
        assert_eq!(lookup("Ctrl", Some(0)), Some("Strg"));
        assert_eq!(lookup("Page Up", Some(0)), Some("Bild auf"));
        assert_eq!(lookup("Page Down", Some(2)), Some("Page suiv."));
        assert!(!has_key("not a key"));
    }

    #[test]
    fn finds_keys_in_source() {
        let src = r#"let a = t("One"); foo(t("Two")); not_t("x")"#;
        assert_eq!(keys_in_source(src), vec!["One", "Two", "x"]);
    }

    #[test]
    fn core_strings_are_translated() {
        let missing: Vec<_> = keys_in_source(include_str!("logic.rs")).into_iter().filter(|k| !has_key(k)).collect();
        assert!(missing.is_empty(), "untranslated: {missing:?}");
    }
}
