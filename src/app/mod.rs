//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine. Toda a lógica de
//! rede vive em Luau (`views/scripts/app.luau`), falando HTTP/JSON + SSE com o
//! daemon; este módulo Rust é só a casca da janela.
//!
//! A configuração de janela, de aplicativo e as telas moram no **markup** de
//! `views/app.gvb`, cuja raiz é o `app(...)` (glacier-ui 0.117+): `id`,
//! `single_instance`, `remember_geometry` (instância única, geometria lembrada e
//! diretório de dados do `storage` do Luau), a janela principal (`size`,
//! `min_size`, `decorations`, `icon`), a `tray` (menu da bandeja) e as `screen`s —
//! a principal e as cinco janelas auxiliares, abertas por
//! `open_window{ component = "…", size = "…" }`. O runner [`GlacierDaemon`] lê isso
//! antes de abrir qualquer janela.
//!
//! Também no `app(...)` (glacier-ui 0.119+): as fontes (`font(src, family)` e
//! `font = …`), o `antialiasing`, o `toast_period` e o `application_id` do Linux.
//!
//! Sobra aqui só o que o markup não expressa: a extensão Luau do `.zip`, o
//! espelho da sessão para a API de agente e a fonte de assets embutida em release.
//!
//! O `.main_template(…)` carrega o manifesto; um `.main(|motor| …)` só serviria
//! para registrar um `impl Component` em Rust, que este app não tem.

use glacier_ui::GlacierDaemon;

/// Sobe o daemon multi-janela e roda o loop do iced até a última janela fechar.
/// Chamado por `main` depois de `assets::locate_and_chdir()`.
pub(crate) fn run() -> iced::Result {
    // API de agente: servidor HTTP local (hyper) que empresta a sessão desta
    // janela para um agente rodando na mesma máquina operar o rustploy REMOTO.
    // Ver `src/agent/mod.rs` e `docs/api-agente-no-gui.md`.
    let sessao_agente = crate::agent::SharedSession::default();
    // Canal de mão contrária (glacier-ui 0.58.6+): deixa a thread do servidor
    // injetar ações no motor desta janela — é o que torna login, navegação e
    // qualquer botão alcançáveis por HTTP. Criado ANTES de `run()`, que é
    // quando o daemon decide registrar a subscription que o drena.
    let ui_agente = glacier_ui::external::sender();

    let daemon = GlacierDaemon::new()
        // Título, tamanho, decorations e ícone da principal, instância única,
        // geometria, diretório de dados, bandeja e as telas: o `app(...)` de
        // `views/app.gvb`. O caminho é relativo ao workspace, onde
        // `assets::locate_and_chdir` deixa o CWD.
        .main_template("views/app.gvb")
        // Extensão da camada Luau: `manifest_zip_read` / `manifest_zip_write`,
        // usadas pelo Infra as Code (Settings). O motor tem `zip_dir` mas não o
        // inverso, e a camada Lua não abre um `.zip` — ver `src/manifest_zip.rs`.
        .lua_extension(crate::manifest_zip::install)
        // Espelha a sessão da GUI (api_url/api_token/connected, escritos no
        // contexto por `handlers/connection.luau`) para a API de agente. O
        // gancho roda depois de CADA dispatch da janela principal, então cobre
        // login, logout e troca de servidor sem precisar conhecer nenhum dos
        // três — e a escrita só acontece quando algo de fato mudou.
        //
        // É também aqui que a API de agente sobe: o `.main()` que a subia saiu
        // (ver o aviso no topo do arquivo). Este gancho só roda na instância
        // PRIMÁRIA — a instância única encerra a segunda antes de qualquer
        // dispatch, então um segundo lançamento não reescreve o handoff da
        // viva — e `spawn` é idempotente (um `AtomicBool`), então chamá-lo a
        // cada dispatch custa uma troca atômica.
        .on_message({
            let sessao = sessao_agente.clone();
            let ui = ui_agente.clone();
            move |_msg, motor| {
                crate::agent::spawn(sessao.clone(), ui.clone());
                sessao.sync_from_context(motor.context());
            }
        });

    // Release: injeta a fonte de assets embutida — o motor passa a ler
    // templates/estilos/scripts/binários de dentro do binário, e nada do disco.
    // Em dev, o `daemon` fica com o `DiskAssets` default (disco + hot-reload).
    #[cfg(not(debug_assertions))]
    let daemon = daemon.assets(std::sync::Arc::new(crate::embedded::EmbeddedAssets));

    // `run` só volta quando o app encerra de verdade (fechar a janela apenas
    // recolhe para a bandeja). É aqui que o handoff da API de agente deixa de
    // valer: o token morre com o processo, então um arquivo sobrevivente só
    // confundiria quem o lesse depois.
    let resultado = daemon.run();
    crate::agent::cleanup();
    resultado
}
