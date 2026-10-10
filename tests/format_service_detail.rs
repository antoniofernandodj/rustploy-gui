//! O `format/service_detail.luau` (`compose_host` e `internal_url`) rodando no
//! motor de verdade.

use glacier_ui::GlacierUI;

fn boot() -> GlacierUI {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    let ws_root = std::path::Path::new(crate_dir);
    std::env::set_current_dir(ws_root).expect("cd workspace root");

    unsafe {
        std::env::set_var("GLACIER_LUAU_PATH", "views/scripts");
    }

    let mut m = GlacierUI::new();
    m.register_component(
        "compose_host",
        "tests/fixtures/compose_host.gvb",
    )
    .expect("registrar a fixture");
    m.set_initial_screen("compose_host");
    m
}

#[test]
fn compose_host_finds_the_service_key_in_yaml() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(g("host_primeira"), "rp_banco", "1ª chave, pulando comentário e linha em branco");
    assert_eq!(g("host_ingress"), "kong", "ingress_service ganha da 1ª chave");
    assert_eq!(g("host_without_services"), "nil");
    assert_eq!(g("host_empty_block"), "nil");
    assert_eq!(g("host_nil"), "nil");
}

#[test]
fn internal_url_uses_compose_host_or_rp_name() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(g("url_compose"), "postgresql://rp_banco:5432");
    assert_eq!(g("url_app"), "http://rp_api:80");
    assert_eq!(g("url_app_db"), "redis://rp_cache:6379");
}
