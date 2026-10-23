//! Assets embutidos no binário — modo standalone (só em builds de release).

use glacier_ui::{EmbeddedDirs, embed_dirs};

/// Cada pasta sob o prefixo lógico que o markup usa: `views/` (templates `.gvb`,
/// estilos e scripts Luau), `assets/icons/` (`<svg src=…>`), `assets/fonts/`
/// (`font(src = …)`), os logos dos blueprints (preparados pelo `build.rs` em
/// `$OUT_DIR`, via o `{logo}` do catálogo do daemon) e `packaging/` (`.desktop` e
/// ícones do `--install-desktop`).
pub fn assets() -> EmbeddedDirs {
    embed_dirs! {
        "views/" => "$CARGO_MANIFEST_DIR/views",
        "assets/icons/" => "$CARGO_MANIFEST_DIR/assets/icons",
        "assets/fonts/" => "$CARGO_MANIFEST_DIR/assets/fonts",
        "assets/blueprint-logos/" => "$OUT_DIR/blueprint_logos",
        "packaging/" => "$CARGO_MANIFEST_DIR/packaging",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glacier_ui::AssetSource;

    /// Cada caminho realmente referenciado em runtime resolve na árvore
    /// embutida — as três convenções de prefixo (views/icons/blueprints), texto
    /// e binário.
    #[test]
    fn resolve_os_assets_referenciados() {
        let a = assets();
        for p in [
            "views/app.gvb",
            "views/styles/app.gss",
            "views/styles/theme.json",
            "views/scripts/app.luau",
            "views/scripts/handlers/connection.luau",
        ] { assert!(a.exists(p), "faltou embutir (texto): {p}");
            assert!(a.read_to_string(p).is_ok(), "não leu (texto): {p}"); }
        for p in [
            "assets/icons/terminal.svg",
            "assets/fonts/JetBrainsMono-Regular.ttf",
            "assets/blueprint-logos/ackee/logo.png",
        ] { assert!(a.exists(p), "faltou embutir (binário): {p}");
            assert!(!a.read_bytes(p).unwrap().is_empty(), "vazio: {p}"); }
        assert!(!a.exists("views/nao_existe.gvb"));
        assert!(a.read_to_string("views/nao_existe.gvb").is_err());
    }

    /// Prova de ponta a ponta, headless (sem janela e **sem `chdir`**): o motor
    /// carrega o app inteiro só da árvore embutida — template + `<link>`
    /// (estilo/tema) + `<script src>` Luau + a cadeia de `require` dos handlers
    /// + render.
    #[test]
    fn motor_sobe_o_app_so_do_binario() {
        use std::sync::Arc;
        let mut motor = glacier_ui::GlacierUI::new().with_asset_source(Arc::new(assets()));
        motor
            .register_app("views/app.gvb")
            .expect("registrar o app a partir dos assets embutidos");
        assert!(
            motor.render_current().is_ok(),
            "render do app embutido falhou"
        );
    }
}
