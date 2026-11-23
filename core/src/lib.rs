//! Glint's platform-independent core, shared by the Windows (`../windows`) and Linux
//! (`../linux`) apps: step math, the settings model, mute and volume-routing rules, and the
//! UI strings in the Mac app's languages. No OS APIs here, so `cargo test` runs anywhere.

pub mod i18n;
pub mod logic;
mod strings;
