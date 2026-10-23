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
    {
        let (view_file, assets_env_var, installed_assets_dir) =
            ("views/app.gvb", "RUSTPLOY_UI_ASSETS", "/usr/share/rustploy");
        glacier_ui::locate_assets_and_chdir(view_file, assets_env_var, Some(installed_assets_dir));
    }
    app::run()
}
