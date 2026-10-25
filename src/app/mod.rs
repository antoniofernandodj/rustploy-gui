//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

use glacier_ui::GlacierDaemon;

mod updater;

/// Sobe o daemon multi-janela e roda o loop do iced até a última janela fechar.
pub(crate) fn run() -> iced::Result {
    let daemon = GlacierDaemon::new()
        .main_template("views/app.gvb")
        // `app_update`: a ponte nativa do "Atualizar app" (ver updater.rs).
        .lua_extension(updater::install_lua)
        .install_desktop("packaging/", "rustploy-gui");
    #[cfg(not(debug_assertions))]
    let daemon = daemon.assets(std::sync::Arc::new(crate::embedded::assets()));
    daemon.run()
}
