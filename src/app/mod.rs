//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

use glacier_ui::GlacierDaemon;

/// Sobe o daemon multi-janela e roda o loop do iced até a última janela fechar.
pub(crate) fn run() -> iced::Result {
    let daemon = GlacierDaemon::new()
        .main_template("views/app.gvb");

    #[cfg(not(debug_assertions))]
    let daemon = daemon.assets(std::sync::Arc::new(crate::embedded::EmbeddedAssets));

    daemon.run()
}
