//! O que o Luau não alcança: o manifesto do `app(...)` (título, tamanho e fontes
//! das janelas), a estrutura dos arquivos `.gvb`, o escopo da avaliação e a
//! construção dos widgets do iced.
//!
//! O resto do que antes morava aqui — as telas sobem, mostram o texto e o botão
//! certos, o estilo na largura da janela — migrou para `tests/tela/render.test.luau`
//! (`glacier test`).

use glacier_ui::GlacierUI;

/// Boots the engine the way `main.rs` does, but from the workspace root so the
/// workspace-relative template paths resolve.
fn boot() -> GlacierUI {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    let ws_root = std::path::Path::new(crate_dir);
    std::env::set_current_dir(ws_root).expect("cd workspace root");

    let mut m = GlacierUI::new();
    m.register_app("views/app.gvb")
        .expect("app.gvb + imports must register (includes app.gss parsing — an unknown property drops the whole sheet)");
    m.set_initial_screen("app");
    m
}

/// Cd's to the workspace root (idempotent — safe alongside `boot`).
fn cd_ws_root() {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    let ws_root = std::path::Path::new(crate_dir);
    std::env::set_current_dir(ws_root).expect("cd workspace root");
}

/// A janela "Novo projeto" (`new_project_form.gvb` + `new_project_window.luau`) é um motor à parte, aberto por `open_window`.
#[test]
fn new_project_form_window_renders() {
    cd_ws_root();
    let mut m = GlacierUI::new();
    m.define_data("api_url", "http://localhost");
    m.define_data("api_token", "t");
    m.register_app_screen("views/app.gvb", "new_project")
        .expect("new_project_form.gvb must register");
    m.set_initial_screen("new_project");
    m.reevaluate_all().expect("eval new_project_form");
    assert!(m.render("new_project").is_ok(), "render new_project_form");

    fn find_control<'a>(
        node: &'a glacier_ui::parser::UiNode,
        name: &str,
    ) -> Option<&'a glacier_ui::parser::UiNode> {
        if node.form_control() == Some(name) {
            return Some(node);
        }
        node.children.iter().find_map(|c| find_control(c, name))
    }
    let ast = m.evaluated("new_project").expect("evaluated");
    let new_project_name = find_control(ast, "new_project_name")
        .expect("o form_control \"new_project_name\" deve existir na árvore avaliada");
    assert!(
        new_project_name
            .rules()
            .is_some_and(|r| r.contains("required")),
        "new_project_name deve carregar rules=\"required\", achei {:?}",
        new_project_name.rules()
    );
    assert_eq!(
        new_project_name
            .form
            .as_ref()
            .and_then(|f| f.form_error_action.as_deref()),
        Some("new_project_show_validation_errors"),
        "o on_validation_error do <form> deve chegar no campo (form_error_action)"
    );
}

/// A sidebar é uma `<drawer>` ligada à chave `menu`: o `<Reveal axis="x">` dela
/// abre com `menu=true` e fecha com `menu=""`. O texto e o botão da gaveta são
/// conferidos em `tests/tela/render.test.luau`; o atributo `open` do `Reveal` é
/// que o Luau ainda não expõe.
#[test]
fn sidebar_drawer_reveal_follows_the_menu_key() {
    use glacier_ui::parser::{NodeType, UiNode};
    use glacier_ui::widget::EngineMessage;

    fn reveal_open(node: &UiNode) -> Option<String> {
        if let NodeType::Reveal {
            horizontal: true,
            open,
            ..
        } = &node.kind
        {
            return Some(open.clone());
        }
        node.children.iter().find_map(reveal_open)
    }

    let mut m = boot();
    m.define_data("screen", "shell");
    m.define_data("view", "deployments");
    m.define_data("menu", "true");
    m.reevaluate_all().expect("eval shell");
    let _ = m.dispatch(&EngineMessage::Viewport {
        width: 731.0,
        height: 680.0,
    });
    assert_eq!(
        reveal_open(m.evaluated("app").expect("app evaluated")).as_deref(),
        Some("true"),
        "esperava o <Reveal axis=\"x\"> da <drawer> com open=\"true\" quando menu=true"
    );

    m.define_data("menu", "");
    m.reevaluate_all().expect("eval shell menu fechado");
    assert_eq!(
        reveal_open(m.evaluated("app").expect("app evaluated")).as_deref(),
        Some(""),
        "esperava o <Reveal axis=\"x\"> da <drawer> com open vazio quando menu=\"\""
    );
}

/// Cada visão do shell e cada janela auxiliar constrói os widgets do iced. O
/// `glacier test` avalia o markup mas não desenha, então um widget que o iced
/// recusa na construção só apareceria no `make run`.
#[test]
fn every_screen_builds_iced_elements() {
    let mut m = boot();
    m.reevaluate_all().expect("eval login");
    assert!(m.render("app").is_ok(), "login render");
    for view in [
        "deployments",
        "projects",
        "service",
        "monitoring",
        "ingress",
        "docker",
        "settings",
        "schedules",
        "support",
    ] {
        m.define_data("screen", "shell");
        m.define_data("view", view);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval view {view}: {e}"));
        assert!(m.render("app").is_ok(), "render view {view}");
    }

    cd_ws_root();
    for tela in [
        "new_project",
        "new_job",
        "log",
        "new_service",
        "new_registry_token",
        "service_export",
    ] {
        let mut c = GlacierUI::new();
        c.define_data("api_url", "http://localhost");
        c.define_data("api_token", "t");
        c.register_app_screen("views/app.gvb", tela)
            .unwrap_or_else(|e| panic!("a tela {tela} deve registrar: {e}"));
        c.set_initial_screen(tela);
        c.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval {tela}: {e}"));
        assert!(c.render(tela).is_ok(), "render {tela}");
    }
}

/// A avaliação do glacier é **escopada** (0.38+): só a tela ativa é construída,
/// não todo template registrado.
#[test]
fn only_the_active_screen_is_evaluated() {
    let m = boot();

    for importado in ["Login", "Shell"] {
        assert!(
            m.is_registered(importado),
            "{importado} deveria ter sido importado por app.gvb"
        );
    }
    assert!(m.render("app").is_ok(), "a tela ativa renderiza");
    assert!(
        matches!(
            m.render("Login"),
            Err(glacier_ui::GlacierError::NotEvaluated(_))
        ),
        "uma view importada não deve ficar avaliada como raiz por conta própria"
    );
}

/// Janela, título e tamanho (glacier-ui 0.117): a janela PRINCIPAL é do `app(...)`
/// de `views/app.gvb` (tamanho, mínimo, moldura, ícone); o título é da `screen`
/// (acompanha a navegação); e o tamanho de cada janela FILHA vai na chamada
/// `open_window{ component = "…", size = "…" }` dos handlers, porque a `screen` é
/// só conteúdo.
#[test]
fn windows_declare_title_and_size() {
    cd_ws_root();

    let mut m = GlacierUI::new();
    m.register_app("views/app.gvb")
        .expect("app.gvb deve registrar");
    let janela = m
        .main_window_meta()
        .expect("o app declara a janela principal");
    assert_eq!(
        janela.title.as_deref(),
        Some("Rustploy"),
        "título da principal"
    );
    assert_eq!(janela.size, Some((1280.0, 820.0)), "tamanho da principal");
    assert_eq!(
        janela.min_size,
        Some((640.0, 680.0)),
        "o min_size da principal"
    );
    assert_eq!(janela.decorations, Some(false), "a principal é borderless");
    assert!(janela.icon.is_some(), "o app declara o ícone");

    let filhas = [
        (
            "new_project",
            Some("Novo projeto — Rustploy"),
            "460 340",
            "handlers/projects.luau",
        ),
        (
            "new_job",
            Some("Novo job — Rustploy"),
            "560 700",
            "handlers/jobs.luau",
        ),
        (
            "new_service",
            Some("Novo serviço — Rustploy"),
            "560 700",
            "handlers/wizard.luau",
        ),
        (
            "new_registry_token",
            Some("Novo token — Rustploy"),
            "480 420",
            "handlers/registry.luau",
        ),
        (
            "service_export",
            Some("Exportar serviço — Rustploy"),
            "620 720",
            "handlers/bundle.luau",
        ),
        ("log", None, "900 560", "handlers/services.luau"),
    ];
    for (tela, titulo, tamanho, handler) in filhas {
        let mut c = GlacierUI::new();
        c.register_app_screen("views/app.gvb", tela)
            .unwrap_or_else(|e| panic!("a tela {tela} deve registrar: {e}"));
        let meta = c.current_screen_meta().cloned().unwrap_or_default();
        assert_eq!(meta.title.as_deref(), titulo, "título de {tela}");
        assert!(meta.size.is_none(), "{tela}: o tamanho não mora na screen");

        let src = std::fs::read_to_string(format!("views/scripts/{handler}"))
            .unwrap_or_else(|e| panic!("ler {handler}: {e}"));
        let chamada = format!("component = \"{tela}\", size = \"{tamanho}\", decorations = false");
        assert!(
            src.contains(&chamada),
            "{handler} deve abrir `{tela}` com `{chamada}`"
        );
    }
}

/// O `app(...)` declara os ajustes do daemon que saíram de `app/mod.rs`
/// (glacier-ui 0.119): fontes, fonte padrão, antialiasing, período dos toasts e
/// `application_id`.
#[test]
fn app_declares_fonts_and_daemon_settings() {
    cd_ws_root();
    let src = std::fs::read_to_string("views/app.gvb").expect("ler app.gvb");
    let xml = glacier_ui::gvb::desugar(&src).expect("desugar app.gvb");
    let m = glacier_ui::parse_app_manifest(&xml, Some("views/app.gvb"))
        .expect("app.gvb parseia")
        .expect("app.gvb tem raiz app");
    assert_eq!(m.app.font.as_deref(), Some("JetBrains Mono"));
    assert_eq!(m.app.antialiasing, Some(false));
    assert_eq!(m.app.toast_period, Some(250));
    assert_eq!(m.app.application_id.as_deref(), Some("rustploy-gui"));
    assert_eq!(m.app.fonts.len(), 2, "regular + bold");
    for f in &m.app.fonts {
        assert!(
            std::path::Path::new(&f.src).is_file(),
            "a fonte {} deve existir",
            f.src
        );
    }
}

/// Remove os comentários (`//` e `/* … */`) para que "a primeira tag" seja a
/// primeira tag de verdade: todo template daqui abre com um comentário de
/// cabeçalho.
fn comments_outside(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut resto = src;
    while let Some(i) = resto.find("/*") {
        out.push_str(&resto[..i]);
        resto = match resto[i..].find("*/") {
            Some(j) => &resto[i + j + 2..],
            None => "",
        };
    }
    out.push_str(resto);
    out.lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Todo `.gvb` abre com a casca certa: `app` no manifesto (`views/app.gvb`),
/// `screen` nas telas abertas em outra janela e `component` no resto.
#[test]
fn every_template_starts_with_a_header() {
    cd_ws_root();

    let raiz = std::path::Path::new("views");
    let mut vistos = 0;

    for (dir, so_component) in [(raiz.to_path_buf(), false), (raiz.join("components"), true)] {
        let mut arquivos: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("ler {}: {e}", dir.display()))
            .map(|e| e.expect("entry").path())
            .filter(|p| p.extension().is_some_and(|e| e == "gvb"))
            .collect();
        arquivos.sort();

        for caminho in arquivos {
            let src = std::fs::read_to_string(&caminho)
                .unwrap_or_else(|e| panic!("ler {}: {e}", caminho.display()));
            let without_comments = comments_outside(&src);
            let primeira: String = without_comments
                .trim_start()
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();

            let e_app = primeira == "app";
            let e_screen = primeira == "screen";
            let e_component = primeira == "component";
            assert!(
                e_app || e_screen || e_component,
                "{}: todo .gvb começa com app (o manifesto), screen (uma tela) ou component \
                 (o resto) — o motor aceita a forma sem cabeçalho, então ninguém além deste \
                 teste avisaria",
                caminho.display()
            );
            assert!(
                !so_component || e_component,
                "{}: um arquivo em views/components/ não é tela — component",
                caminho.display()
            );
            assert!(
                !e_app || caminho.file_name().is_some_and(|n| n == "app.gvb"),
                "{}: só views/app.gvb é o manifesto (raiz app)",
                caminho.display()
            );
            vistos += 1;
        }
    }

    assert!(
        vistos >= 21,
        "o teste não achou os templates: {vistos} arquivos varridos"
    );
}

