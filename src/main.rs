//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod app;
#[cfg(not(debug_assertions))]
mod embedded;

fn main() -> iced::Result {
    #[cfg(debug_assertions)]
    glacier_ui::locate_assets_and_chdir(
        "views/app.gvb",
        "RUSTPLOY_UI_ASSETS",
        Some("/usr/share/rustploy"),
    );

    app::run()
}
