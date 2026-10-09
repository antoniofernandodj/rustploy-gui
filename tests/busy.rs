//! busy.luau no motor de verdade: o botão libera no toast da própria ação, não
//! só quando o handler inteiro (inclusive o refresh depois do toast) termina.

use glacier_ui::{EngineMessage, GlacierUI};

#[test]
fn botao_libera_no_toast_e_nao_no_fim_do_handler() {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    std::env::set_current_dir(std::path::Path::new(crate_dir)).expect("cd workspace root");
    unsafe {
        std::env::set_var("GLACIER_LUAU_PATH", "views/scripts");
    }

    let mut m = GlacierUI::new();
    m.register_component("acao_salva", "tests/fixtures/acao_salva.gvb")
        .expect("registrar a fixture");
    m.set_initial_screen("acao_salva");

    let flag = |m: &GlacierUI| m.context().get("busy_salvar").cloned();
    assert_eq!(flag(&m).as_deref(), Some("false"), "init() semeia o flag");

    // O handler toasta e fica suspenso no 2º fetch: já respondeu ao usuário.
    let _ = m.dispatch(&EngineMessage::UiClick("salvar".into()));
    assert_eq!(
        flag(&m).as_deref(),
        Some("false"),
        "depois do toast o botão tem de estar livre, mesmo com o refresh pendente"
    );
}
