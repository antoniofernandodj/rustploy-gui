//! O `access_key.luau` (token de conexão do login) rodando no motor de verdade.

use glacier_ui::GlacierUI;

fn boot() -> GlacierUI {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    std::env::set_current_dir(crate_dir).expect("cd workspace root");

    unsafe {
        std::env::set_var("GLACIER_LUAU_PATH", "views/scripts");
    }

    let mut m = GlacierUI::new();
    m.register_component("access_key", "tests/fixtures/access_key_fixture.gvb")
        .expect("registrar a fixture");
    m.set_initial_screen("access_key");
    m
}

/// Byte a byte igual à do daemon (`api/agent/access_key.rs`), da webui
/// (`encodeAccessKey`) e do `base64.b64encode(b"host:porta::token")` do Python.
#[test]
fn encode_matches_the_daemon_the_webui_and_python() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    // base64("127.0.0.1:9::x")
    assert_eq!(g("key_encoded"), "MTI3LjAuMC4xOjk6Ong=");
    // base64("a.b:443::x") — a porta padrão vai mesmo sem estar na URL.
    assert_eq!(g("key_encoded_default_port"), "YS5iOjQ0Mzo6eA==");
}

#[test]
fn decode_round_trips_and_explains_bad_keys() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(
        g("key_round_trip"),
        "a.b:9797|tok-123_ABC rustploy-ms.itemize.com.br:9797|tok-123_ABC [::1]:9797|tok-123_ABC"
    );
    assert_eq!(g("key_from_python"), "a.b:9797|~?");
    assert_eq!(g("key_url_safe"), "a.b:9797|~?");
    assert!(g("key_missing_prefix").contains("só o token"), "{}", g("key_missing_prefix"));
    assert!(g("key_corrupted").contains("corrompido"), "{}", g("key_corrupted"));
    assert!(g("key_hint").starts_with("a.b:9797 · "), "{}", g("key_hint"));
}
