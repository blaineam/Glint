// Embeds the icon, the application manifest (per-monitor DPI awareness, asInvoker so
// Windows never asks for admin) and version info into Glint.exe.
//
// Resources need a Windows resource compiler, so they are only embedded when building on
// Windows. A cross-platform `cargo check`/`cargo test` on macOS or Linux skips this step.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=res/glint.ico");
    println!("cargo:rerun-if-changed=res/glint.manifest");
    println!("cargo:rerun-if-env-changed=GLINT_VERSION");
    #[cfg(windows)]
    embed();
}

#[cfg(windows)]
fn embed() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let version = std::env::var("GLINT_VERSION")
        .unwrap_or_else(|_| std::env::var("CARGO_PKG_VERSION").expect("cargo sets the package version"));
    let mut res = winresource::WindowsResource::new();
    // Resource id 1 is the app icon; the tray loads it by that id.
    res.set_icon_with_id("res/glint.ico", "1");
    res.set_manifest_file("res/glint.manifest");
    res.set("ProductName", "Glint");
    res.set("FileDescription", "Glint: DDC display control");
    res.set("CompanyName", "Blaine Miller");
    res.set("LegalCopyright", "MIT License");
    res.set("ProductVersion", &version);
    res.set("FileVersion", &version);
    res.compile().expect("embedding Windows resources failed");
}
