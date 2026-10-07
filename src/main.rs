//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod agent;
mod app;
mod desktop;
mod manifest_zip;
#[cfg(debug_assertions)]
mod assets;
#[cfg(not(debug_assertions))]
mod embedded;

fn main() -> iced::Result {
    if let Some(code) = desktop::handle_args() {
        std::process::exit(code);
    }

    #[cfg(debug_assertions)]
    assets::locate_and_chdir();

    app::run()
}
