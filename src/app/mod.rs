//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

use glacier_ui::GlacierDaemon;

/// Sobe o daemon multi-janela e roda o loop do iced até a última janela fechar.
pub(crate) fn run() -> iced::Result {
    let sessao_agente = crate::agent::SharedSession::default();
    let ui_agente = glacier_ui::external::sender();

    let daemon = GlacierDaemon::new()
        .main_template("views/app.gvb")
        .lua_extension(crate::manifest_zip::install)
        .on_message({
            let sessao = sessao_agente.clone();
            let ui = ui_agente.clone();
            move |_msg, motor| {
                crate::agent::spawn(sessao.clone(), ui.clone());
                sessao.sync_from_context(motor.context());
            }
        });

    #[cfg(not(debug_assertions))]
    let daemon = daemon.assets(std::sync::Arc::new(crate::embedded::EmbeddedAssets));

    let resultado = daemon.run();
    crate::agent::cleanup();
    resultado
}
