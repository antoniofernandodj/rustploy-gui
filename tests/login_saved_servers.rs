//! Tela de login com servidores lembrados: o `<select>` mostra `host:porta`, o
//! campo recebe o token de conexão, e "Esquecer" remove até o par salvo sem
//! token (daemon sem `[api].token`), que antes voltava sempre.
//!
//! Binário de teste próprio porque a raiz do `storage` é global do processo
//! (`set_storage_root` só vale uma vez): aqui ela aponta para um diretório
//! temporário, nunca para o storage de verdade do usuário.

use glacier_ui::GlacierUI;

const SAVED: &str = r#"{"saved_servers":[
    {"url":"https://rp.exemplo.com:9797","token":"tok-falso-AAAA"},
    {"url":"http://localhost:9797","token":""}
]}"#;

#[test]
fn saved_servers_show_the_address_and_forget_clears_even_without_token() {
    let storage_root = std::env::temp_dir().join(format!(
        "rustploy-gui-login-test-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(storage_root.join(".glacier-storage")).unwrap();
    std::fs::write(storage_root.join(".glacier-storage/app.json"), SAVED).unwrap();
    glacier_ui::luau::set_storage_root(storage_root.clone());

    std::env::set_current_dir(env!("CARGO_MANIFEST_DIR")).expect("cd workspace root");
    let mut m = GlacierUI::new();
    m.register_app("views/app.gvb").expect("app.gvb");
    m.set_initial_screen("app");
    m.reevaluate_all().expect("eval inicial");
    let g = |m: &GlacierUI, k: &str| m.context().get(k).cloned().unwrap_or_default();

    // A lista mostra o endereço; o valor é o token de conexão.
    let options: serde_json::Value = serde_json::from_str(&g(&m, "saved_servers")).unwrap();
    assert_eq!(options[0]["label"], "rp.exemplo.com:9797");
    assert_eq!(options[1]["label"], "localhost:9797");
    // base64("rp.exemplo.com:9797::tok-falso-AAAA")
    assert_eq!(
        options[0]["value"],
        "cnAuZXhlbXBsby5jb206OTc5Nzo6dG9rLWZhbHNvLUFBQUE="
    );

    // O mais recente vem pré-preenchido, com o destino visível sob o campo.
    assert_eq!(g(&m, "access_key"), options[0]["value"].as_str().unwrap());
    assert_eq!(g(&m, "saved_server_choice"), g(&m, "access_key"));
    assert_eq!(g(&m, "access_key_target"), "conecta em rp.exemplo.com:9797");

    // O par sem token (base64("localhost:9797::")) também é esquecível.
    m.define_data("access_key", "bG9jYWxob3N0Ojk3OTc6Og==");
    let _ = m.dispatch(&glacier_ui::EngineMessage::UiClick("forget_server".into()));
    let options: serde_json::Value = serde_json::from_str(&g(&m, "saved_servers")).unwrap();
    assert_eq!(options.as_array().unwrap().len(), 1, "{options}");
    assert_eq!(options[0]["label"], "rp.exemplo.com:9797");
    assert_eq!(g(&m, "access_key"), "");
    assert_eq!(g(&m, "access_key_target"), "");
    let stored = std::fs::read_to_string(storage_root.join(".glacier-storage/app.json")).unwrap();
    assert!(!stored.contains("localhost"), "{stored}");

    let _ = std::fs::remove_dir_all(&storage_root);
}
