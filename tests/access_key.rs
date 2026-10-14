//! O `access_key.luau` (chave `rpk1_…` do login) rodando no motor de verdade.

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

/// Byte a byte igual à do daemon (`api/agent/access_key.rs`) e da webui
/// (`encodeAccessKey`): `{"u":…,"t":…}` nessa ordem, base64url sem padding.
#[test]
fn encode_matches_the_daemon_and_the_webui() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(
        g("key_encoded"),
        "rpk1_eyJ1IjoiaHR0cDovLzEyNy4wLjAuMTo5IiwidCI6IngifQ"
    );
}

#[test]
fn decode_round_trips_and_explains_bad_keys() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(g("key_round_trip"), "https://a.b:9797|tok-123_ABC");
    assert!(g("key_missing_prefix").contains("rpk1_"), "{}", g("key_missing_prefix"));
    assert!(g("key_corrupted").contains("corrompida"), "{}", g("key_corrupted"));
    assert!(g("key_hint").starts_with("a.b:9797   rpk1_"), "{}", g("key_hint"));
}
