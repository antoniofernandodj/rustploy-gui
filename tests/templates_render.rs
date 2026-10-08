//! Headless validation: every template parses, every screen/tab evaluates and
//! builds an iced element tree without error.

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

/// Todo texto de uma árvore avaliada, em ordem.
fn textos_avaliados(n: &glacier_ui::UiNode) -> Vec<String> {
    let mut out = Vec::new();
    if let glacier_ui::parser::NodeType::Text { content, .. } = &n.kind {
        out.push(content.clone());
    }
    for f in n.children.iter() {
        out.extend(textos_avaliados(f));
    }
    out
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
    assert!(
        m.render("new_project").is_ok(),
        "render new_project_form"
    );

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
    let np_name = find_control(ast, "np_name")
        .expect("o form_control \"np_name\" deve existir na árvore avaliada");
    assert!(
        np_name.rules().is_some_and(|r| r.contains("required")),
        "np_name deve carregar rules=\"required\", achei {:?}",
        np_name.rules()
    );
    assert_eq!(
        np_name
            .form
            .as_ref()
            .and_then(|f| f.form_error_action.as_deref()),
        Some("np_apontar"),
        "o on_validation_error do <form> deve chegar no campo (form_error_action)"
    );
}

/// A janela "Novo job" (`new_job_window.gvb` + `new_job_window.luau`) é um
/// motor à parte, aberto por `open_new_job_window` (handlers/jobs.luau).
#[test]
fn new_job_window_renders() {
    cd_ws_root();
    let mut m = GlacierUI::new();
    m.define_data("api_url", "http://localhost");
    m.define_data("api_token", "t");
    m.define_data("njob_projects", r#"[{"id":"prj_1","name":"acme"}]"#);
    m.define_data(
        "njob_services",
        r#"[{"id":"svc_1","name":"web","project_id":"prj_1"}]"#,
    );
    m.register_app_screen("views/app.gvb", "new_job")
    .expect("new_job_window.gvb must register");
    m.set_initial_screen("new_job");

    m.define_data("njob_step", "pick_project");
    m.reevaluate_all()
        .expect("eval new_job_window/pick_project");
    assert!(
        m.render("new_job").is_ok(),
        "render new_job_window/pick_project"
    );

    m.define_data("njob_step", "pick_service");
    m.define_data("njob_project_name", "acme");
    m.define_data(
        "njob_services_filtered",
        r#"[{"id":"svc_1","name":"web","project_id":"prj_1"}]"#,
    );
    m.reevaluate_all()
        .expect("eval new_job_window/pick_service");
    assert!(
        m.render("new_job").is_ok(),
        "render new_job_window/pick_service"
    );

    m.define_data("njob_step", "form");
    m.define_data("njob_service_name", "web");
    m.define_data("njob_time", "03:00");
    m.define_data(
        "weekdays",
        r#"[{"id":"0","label":"Seg"},{"id":"1","label":"Ter"},{"id":"2","label":"Qua"},{"id":"3","label":"Qui"},{"id":"4","label":"Sex"},{"id":"5","label":"Sáb"},{"id":"6","label":"Dom"}]"#,
    );
    for kind in ["manual", "interval", "daily", "weekly"] {
        m.define_data("njob_kind", kind);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval new_job_window/form {kind}: {e}"));
        assert!(
            m.render("new_job").is_ok(),
            "render new_job_window/form {kind}"
        );
    }
}

/// A janela de logs ao vivo (`log_window.gvb` + `log_window.luau`) é um motor à
/// parte, aberto por `open_logs_window`; validamos que registra e renderiza por
/// conta própria — semeando a conexão + o serviço + o tail como `open_window`.
#[test]
fn log_window_renders() {
    cd_ws_root();
    let mut m = GlacierUI::new();
    m.define_data("api_url", "http://localhost");
    m.define_data("api_token", "t");
    m.define_data("lw_title", "Logs · api");
    m.define_data("lw_stream_url", "/api/services/svc1/logs");
    m.define_data(
        "lw_seed",
        r#"[{"stream":"Stdout","line":"hello","timestamp":"2026-07-10T23:00:00Z"}]"#,
    );
    m.register_app_screen("views/app.gvb", "log")
        .expect("log_window.gvb must register");
    m.set_initial_screen("log");
    m.reevaluate_all().expect("eval log_window");
    assert!(m.render("log").is_ok(), "render log_window");
}

/// O wizard "Novo serviço" (`new_service_window.gvb`, que importa `new_service.gvb`
/// + `new_service_window.luau`) também é uma janela à parte, aberta por
/// `open_new_service_window`.
#[test]
fn new_service_wizard_window_renders() {
    cd_ws_root();
    let mut m = GlacierUI::new();
    m.define_data("api_url", "http://localhost");
    m.define_data("api_token", "t");
    m.define_data("selected_project_id", "p1");
    m.define_data("proj_name", "demo");
    m.register_app_screen("views/app.gvb", "new_service")
    .expect("new_service_window.gvb must register");
    m.set_initial_screen("new_service");

    m.define_data("ns_db_has_dbname", "true");
    m.define_data("ns_db_has_user", "true");
    m.define_data("ns_db_has_rootpw", "true");
    m.define_data("ns_db_has_replica", "true");
    m.define_data(
        "ns_dbs",
        r#"[{"id":"postgres","label":"PostgreSQL","image":"postgres:18"}]"#,
    );
    m.define_data(
        "ns_templates",
        r#"[{"id":"forgejo","name":"Forgejo","description":"git","logo":"assets/blueprint-logos/forgejo/forgejo.svg","logo_kind":"svg"},{"id":"wordpress","name":"WordPress","description":"cms","logo":"assets/blueprint-logos/wordpress/wordpress.png","logo_kind":"img"}]"#,
    );
    m.define_data(
        "ns_template_vars",
        r#"[{"idx":"0","label":"Domínio","placeholder":"x"}]"#,
    );

    for step in [
        "pick_type",
        "pick_db",
        "app_form",
        "db_form",
        "compose_form",
        "pick_template",
        "template_form",
    ] {
        m.define_data("ns_step", step);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval new_service/{step}: {e}"));
        assert!(
            m.render("new_service").is_ok(),
            "render new_service/{step}"
        );
    }
}

#[test]
fn all_screens_and_service_tabs_render() {
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

    m.define_data("view", "deploy_engine");
    m.define_data("eng_tab", "fila");
    m.define_data("eng_queued_count", "2");
    m.define_data("eng_paused", "true");
    m.define_data(
        "eng_queued",
        r#"[{"deployment_id":"dep_1","pos":"1","service":"api","project":"acme"},{"deployment_id":"dep_2","pos":"2","service":"worker","project":"acme"}]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval deploy_engine: {e}"));
    assert!(m.render("app").is_ok(), "render deploy_engine com fila");

    m.define_data("eng_tab", "executando");
    m.define_data("eng_active_count", "1");
    m.define_data(
        "eng_active",
        r#"[{"service":"api","project":"acme","state_label":"BUILDING","state_kind":"info","steps":[{"text":"✓ Fila","status":"done"},{"text":"● Obter","status":"current"},{"text":"○ Live","status":"pending"}],"total":"10s","phase":"4s","service_id":"svc_1"}]"#,
    );
    m.define_data("eng_detail_open", "true");
    m.define_data("eng_detail_title", "api");
    m.define_data(
        "eng_detail_steps",
        r#"[{"text":"✓ Fila","status":"done"},{"text":"✕ Obter","status":"failed"}]"#,
    );
    m.define_data(
        "eng_detail_rows",
        r#"[{"label":"Pending","kind":"ok","dur":"2s","msg":""},{"label":"Failed","kind":"bad","dur":"—","msg":"build quebrou"}]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval deploy_engine ativo+detalhe: {e}"));
    assert!(m.render("app").is_ok(), "render deploy_engine com stepper e popup");

    m.define_data("eng_tab", "historico");
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval deploy_engine histórico: {e}"));
    assert!(m.render("app").is_ok(), "render deploy_engine histórico");

    m.define_data("view", "ingress");
    m.define_data("host_ports_count", "1");
    m.define_data(
        "host_ports",
        r#"[{"service":"web","project":"acme","host_port":"8081","container_port":"80"}]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval ingress/host_ports: {e}"));
    assert!(m.render("app").is_ok(), "render ingress/host_ports");

    m.define_data("view", "docker");
    m.define_data("docker_containers_count", "1");
    m.define_data(
        "docker_containers",
        r#"[{"id_full":"c1","name":"rp_api_live","image":"acme/api:latest","owner":"acme / api","state_kind":"ok","state_label":"running","can_remove":"0"}]"#,
    );
    m.define_data("docker_images_count", "1");
    m.define_data(
        "docker_images",
        r#"[{"id_full":"i1","tags":"acme/api:latest","owner":"acme / api","size":"120 MB","created":"12/07","in_use_kind":"ok","in_use_label":"EM USO"}]"#,
    );
    m.define_data("docker_volumes_count", "1");
    m.define_data(
        "docker_volumes",
        r#"[{"name":"pgdata","owner":"—","size":"1.2 GB","in_use_kind":"ok","in_use_label":"EM USO"}]"#,
    );
    m.define_data("docker_networks_count", "1");
    m.define_data(
        "docker_networks",
        r#"[{"name":"rp_net_acme","owner":"acme","in_use_kind":"ok","in_use_label":"EM USO"}]"#,
    );
    m.define_data("registry_status_label", "ativo em 127.0.0.1:5100");
    m.define_data("registry_status_enabled", "true");
    m.define_data("registry_storage_human", "340 MB");
    m.define_data("registry_repos_count", "1");
    m.define_data(
        "registry_repos",
        r#"[{"name":"acme/api","tag_count":"3","size":"340 MB"}]"#,
    );
    m.define_data("registry_tokens_count", "1");
    m.define_data(
        "registry_tokens",
        r#"[{"name":"ci","scope":"pull","created":"12/07"}]"#,
    );
    m.define_data("registry_selected_repo", "");
    m.define_data("registry_tags_loading", "false");
    m.define_data("registry_tags_count", "0");
    m.define_data("registry_tags", "[]");
    for tab in ["containers", "images", "volumes", "networks", "registry"] {
        m.define_data("docker_tab", tab);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval docker/{tab}: {e}"));
        assert!(m.render("app").is_ok(), "render docker/{tab}");
    }
    // As tabelas são `tableview` + `tablecolumn`: a célula com corpo sai do
    // eval já avaliada com a linha (`@c.name`), e não só o cabeçalho.
    m.define_data("docker_tab", "containers");
    m.reevaluate_all().expect("eval docker/containers");
    let textos = textos_avaliados(m.evaluated("app").expect("app avaliado"));
    assert!(
        textos.iter().any(|t| t == "rp_api_live"),
        "a célula NOME da linha não foi avaliada: {textos:?}"
    );
    m.define_data("registry_selected_repo", "acme/api");
    m.define_data("registry_tags_count", "1");
    m.define_data(
        "registry_tags",
        r#"[{"tag":"latest","size":"120 MB","created":"12/07","digest_short":"sha256:abcd1234"}]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval docker/registry com repo selecionado: {e}"));
    assert!(
        m.render("app").is_ok(),
        "render docker/registry com repo selecionado"
    );

    m.define_data("view", "schedules");
    m.define_data("jobs_count", "1");
    m.define_data(
        "jobs_summary",
        r#"[{"id":"job_1","name":"backup-db","owner":"acme / postgres","recurrence":"a cada 6h","enabled":true,"enabled_label":"Pausar","last_run_label":"ok","last_run_kind":"ok","last_run_id":"jrun_1","next_run_at":"12/07 03:00"}]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval schedules: {e}"));
    assert!(m.render("app").is_ok(), "render schedules com dados");

    m.define_data(
        "proj_env",
        r##"[{"key":"__c0","value":"# comentário","kind":"comment"},{"key":"A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_THAT_SHOULD_BE_TRUNCATED","key_display":"A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_TH…","value":"x","kind":"plain"}]"##,
    );
    m.define_data("proj_jobs_count", "1");
    m.define_data(
        "proj_jobs",
        r#"[{"id":"job_1","name":"backup-db","recurrence":"a cada 6h","enabled":true,"enabled_label":"Pausar","last_run_label":"ok","last_run_kind":"ok","last_run_id":"jrun_1","next_run_at":"12/07 03:00"}]"#,
    );
    m.define_data("proj_secrets_count", "1");
    m.define_data(
        "proj_secrets",
        r#"[{"name":"GITHUB_TOKEN","name_display":"GITHUB_TOKEN"}]"#,
    );
    for proj_tab in ["services", "env", "secrets", "jobs"] {
        m.define_data("view", "project_services");
        m.define_data("proj_tab", proj_tab);
        m.define_data("proj_loading", "false");
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval project_services/{proj_tab}: {e}"));
        assert!(
            m.render("app").is_ok(),
            "render project_services/{proj_tab}"
        );
    }

    m.define_data("proj_tab", "env");
    m.define_data("penv_new_is_secret", "true");
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval project_services/env secret: {e}"));
    assert!(
        m.render("app").is_ok(),
        "render project_services/env modo secret"
    );
    m.define_data("proj_secrets_count", "0");
    m.define_data("proj_secrets", "[]");
    for proj_tab in ["env", "secrets"] {
        m.define_data("proj_tab", proj_tab);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval {proj_tab} sem secrets: {e}"));
        assert!(m.render("app").is_ok(), "render {proj_tab} sem secrets");
    }
    m.define_data("penv_new_is_secret", "false");

    m.define_data("view", "settings");
    m.define_data("gitea_count", "1");
    for mode in ["oauth", "pat"] {
        m.define_data("settings_tab", "git");
        m.define_data("gp_mode", mode);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval settings/git {mode}: {e}"));
        assert!(m.render("app").is_ok(), "render settings/git {mode}");
    }

    m.define_data("settings_tab", "web");
    m.define_data("ss_public_base", "https://rustploy.meusite.com");
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval settings/web: {e}"));
    assert!(m.render("app").is_ok(), "render settings/web");

    m.define_data("settings_tab", "iac");
    m.define_data("iac_has_export", "true");
    m.define_data("iac_yaml", "apiVersion: rustploy/v1\nprojects: []\n");
    m.define_data("iac_dotenv", "[project.acme.env]\nLOG_LEVEL = \"info\"\n");
    m.define_data("iac_has_missing", "true");
    m.define_data("iac_missing_vars", "DB_PASS, API_TOKEN");
    m.define_data("iac_has_report", "true");
    m.define_data(
        "iac_report_lines",
        r#"["[created] project acme","[updated] service acme/web"]"#,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval settings/iac: {e}"));
    assert!(m.render("app").is_ok(), "render settings/iac");

    m.define_data("settings_tab", "maintenance");
    m.define_data("dc_enabled", "true");
    m.define_data("dc_hours", "6");
    m.define_data("dc_time", "03:00");
    m.define_data("dc_weekday", "0");
    m.define_data(
        "weekdays",
        r#"[{"id":"0","label":"Seg"},{"id":"1","label":"Ter"},{"id":"2","label":"Qua"},{"id":"3","label":"Qui"},{"id":"4","label":"Sex"},{"id":"5","label":"Sáb"},{"id":"6","label":"Dom"}]"#,
    );
    m.define_data("dc_containers", "true");
    m.define_data("dc_images", "true");
    m.define_data("dc_images_all", "false");
    m.define_data("dc_volumes", "false");
    m.define_data("dc_volumes_all", "false");
    m.define_data("dc_networks", "true");
    m.define_data("dc_build_cache", "true");
    m.define_data("dc_next_run_label", "hoje às 03:00");
    m.define_data(
        "dc_last_run_text",
        "12/07 03:00 · 3 removidos · 120 MB liberados",
    );
    m.define_data("dc_running", "false");
    m.define_data("dc_msg", "");
    for kind in ["interval", "daily", "weekly"] {
        m.define_data("dc_kind", kind);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval settings/maintenance {kind}: {e}"));
        assert!(
            m.render("app").is_ok(),
            "render settings/maintenance {kind}"
        );
    }

    for tab in [
        "general",
        "connection",
        "environment",
        "domains",
        "deployments",
        "healthcheck",
        "logs",
        "advanced",
    ] {
        m.define_data("screen", "shell");
        m.define_data("view", "service");
        m.define_data("tab", tab);
        m.define_data("env_text_open", "true");
        m.define_data(
            "svc_env",
            r##"[{"key":"__c0","value":"# comentário","kind":"comment"},{"key":"OLA","key_display":"OLA","value":"mundo","kind":"plain"},{"key":"A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_THAT_SHOULD_BE_TRUNCATED","key_display":"A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_TH…","value":"x","kind":"plain"}]"##,
        );
        m.define_data("dep_selected", "abc123");
        m.define_data("svc_webhook_supported", "true");
        m.define_data(
            "svc_webhook_url",
            "https://rustploy.meusite.com/webhook/svc_01ABC/f4b53d4d9d574a55",
        );
        m.define_data(
            "svc_webhook_url_short",
            "https://rustploy.meusite.com/webhook/svc_01ABC…",
        );
        m.define_data("gitea_count", "1");
        m.define_data("prov_tab", "gitea");
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval tab {tab}: {e}"));
        assert!(m.render("app").is_ok(), "render tab {tab}");
    }

    m.define_data("tab", "general");
    m.define_data("svc_source_kind", "Git");
    m.define_data("erro_f_gen_port", "");
    for prov in ["git", "zip"] {
        m.define_data("prov_tab", prov);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval general/prov_tab={prov}: {e}"));
        assert!(m.render("app").is_ok(), "render general/prov_tab={prov}");
    }
    m.define_data("svc_source_kind", "Compose");
    m.define_data("svc_compose", "services:\n  web:\n    image: nginx\n");
    m.define_data("svc_compose_orig", "services:\n  web:\n    image: nginx\n");
    m.reevaluate_all().expect("eval general/compose");
    assert!(m.render("app").is_ok(), "render general/compose");

    m.define_data("tab", "deployments");
    m.define_data("svc_webhook_url", "");
    m.reevaluate_all()
        .expect("eval deployments/webhook sem token");
    assert!(
        m.render("app").is_ok(),
        "render deployments/webhook sem token"
    );

    m.define_data("svc_webhook_supported", "false");
    m.reevaluate_all()
        .expect("eval deployments/webhook compose");
    assert!(
        m.render("app").is_ok(),
        "render deployments/webhook compose"
    );
}

/// Onda 2 da reforma (docs/plano-reforma-gui-glacier-0.102.md): a sidebar é uma
/// `<drawer>`, não mais um trilho de ícones colapsável por `@media`.
#[test]
fn sidebar_is_a_drawer_bound_to_menu_key() {
    use glacier_ui::widget::EngineMessage;
    let mut m = boot();
    m.define_data("screen", "shell");
    m.define_data("view", "deployments");
    m.define_data("menu", "true");
    m.reevaluate_all().expect("eval shell");
    let _ = m.dispatch(&EngineMessage::Viewport {
        width: 731.0,
        height: 680.0,
    });

    fn find<'a>(
        node: &'a glacier_ui::parser::UiNode,
        pred: &dyn Fn(&glacier_ui::parser::UiNode) -> bool,
        out: &mut Vec<&'a glacier_ui::parser::UiNode>,
    ) {
        if pred(node) {
            out.push(node);
        }
        for child in &node.children {
            find(child, pred, out);
        }
    }

    let ast = m.evaluated("app").expect("app evaluated");
    let mut triggers = Vec::new();
    find(
        ast,
        &|n| {
            matches!(
                &n.kind,
                glacier_ui::parser::NodeType::Button { on_click: Some(a), .. }
                    if a == "drawer::toggle:menu"
            )
        },
        &mut triggers,
    );
    assert_eq!(
        triggers.len(),
        1,
        "esperava um botão on_click=\"drawer::toggle:menu\" (o ☰ da topbar)"
    );

    let mut reveals = Vec::new();
    find(
        ast,
        &|n| {
            matches!(
                &n.kind,
                glacier_ui::parser::NodeType::Reveal { horizontal: true, open, .. }
                    if open == "true"
            )
        },
        &mut reveals,
    );
    assert!(
        !reveals.is_empty(),
        "esperava o <Reveal axis=\"x\"> da <drawer> com open=\"true\" quando menu=true"
    );

    let mut labels = Vec::new();
    find(
        ast,
        &|n| {
            matches!(
                &n.kind,
                glacier_ui::parser::NodeType::Text { content, .. }
                    if content == "Deploy Engine" || content.starts_with("Projects (")
            )
        },
        &mut labels,
    );
    assert_eq!(
        labels.len(),
        2,
        "esperava os rótulos \"Deploy Engine\" e \"Projects (N)\" na gaveta aberta"
    );
    for n in &labels {
        assert_ne!(
            n.hidden,
            Some(true),
            "rótulo {:?} não deve ser forçado a hidden — a gaveta aberta mostra tudo",
            n.kind
        );
    }

    m.define_data("menu", "");
    m.reevaluate_all().expect("eval shell menu fechado");
    let ast = m.evaluated("app").expect("app evaluated");
    let mut closed = Vec::new();
    find(
        ast,
        &|n| {
            matches!(
                &n.kind,
                glacier_ui::parser::NodeType::Reveal { horizontal: true, open, .. }
                    if open.is_empty()
            )
        },
        &mut closed,
    );
    assert!(
        !closed.is_empty(),
        "esperava o <Reveal axis=\"x\"> da <drawer> com open vazio quando menu=\"\""
    );
}

/// Regressão: as ações da tela de serviço (Deploy/Reload/Rebuild/Stop) têm duas
/// fileiras que se alternam por largura.
#[test]
fn service_actions_collapse_to_icons_when_narrow() {
    use glacier_ui::widget::EngineMessage;

    fn count_visible(
        node: &glacier_ui::parser::UiNode,
        full: &mut u32,
        compact: &mut u32,
        ancestor_hidden: bool,
    ) {
        let hidden = ancestor_hidden || node.hidden == Some(true);
        if let glacier_ui::parser::NodeType::Button { text, .. } = &node.kind {
            if !hidden {
                if matches!(text.as_str(), "Deploy" | "Reload" | "Rebuild" | "Stop") {
                    *full += 1;
                }
                if matches!(text.as_str(), "▶" | "⟳" | "⚙" | "■") {
                    *compact += 1;
                }
            }
        }
        for child in &node.children {
            count_visible(child, full, compact, hidden);
        }
    }

    let mut m = boot();
    m.define_data("screen", "shell");
    m.define_data("view", "service");
    m.define_data("tab", "general");
    m.reevaluate_all().expect("eval service");

    let _ = m.dispatch(&EngineMessage::Viewport {
        width: 1400.0,
        height: 820.0,
    });
    let (mut full, mut compact) = (0, 0);
    count_visible(
        m.evaluated("app").expect("app"),
        &mut full,
        &mut compact,
        false,
    );
    assert_eq!(
        (full, compact),
        (4, 0),
        "em 1400px espera 4 botões de texto e 0 ícones"
    );

    let _ = m.dispatch(&EngineMessage::Viewport {
        width: 980.0,
        height: 820.0,
    });
    let (mut full, mut compact) = (0, 0);
    count_visible(
        m.evaluated("app").expect("app"),
        &mut full,
        &mut compact,
        false,
    );
    assert_eq!(
        (full, compact),
        (0, 4),
        "em 980px espera 0 botões de texto e 4 ícones"
    );
}

/// A avaliação do glacier é **escopada** (0.38+): só a tela ativa é construída,
/// não todo template registrado.
#[test]
fn so_a_tela_ativa_e_avaliada() {
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

/// Logout tem que zerar a RAM da sessão: nada do daemon anterior pode continuar
/// no contexto (nomes de projeto, linhas de log, o próprio api_token) — foi um
/// bug real, porque o `disconnect` antigo limpava só quatro chaves à mão.
#[test]
fn disconnect_limpa_o_contexto_da_sessao() {
    let mut m = boot();

    for (k, v) in [
        ("connected", "true"),
        ("screen", "shell"),
        ("api_url", "https://rustploy.example"),
        ("api_token", "token-secreto"),
        ("projects_count", "7"),
        ("proj_name", "acme"),
        (
            "proj_secrets",
            r#"[{"name":"GITHUB_TOKEN","name_display":"GITHUB_TOKEN"}]"#,
        ),
        (
            "svc_env",
            r#"[{"key":"API_KEY","value":"secret:API_KEY","kind":"secret"}]"#,
        ),
        ("selected_project_id", "prj_1"),
    ] {
        m.define_data(k, v);
    }
    m.reevaluate_all().expect("eval sessão conectada");

    let _ = m.dispatch(&glacier_ui::EngineMessage::UiClick("disconnect".into()));

    let ctx = m.context();
    for k in [
        "api_url",
        "api_token",
        "proj_name",
        "proj_secrets",
        "svc_env",
        "selected_project_id",
    ] {
        assert!(
            ctx.get(k).is_none(),
            "ctx.{k} sobreviveu ao logout: {:?}",
            ctx.get(k)
        );
    }
    assert_eq!(ctx.get("connected").map(String::as_str), Some("false"));
    assert_eq!(ctx.get("screen").map(String::as_str), Some("login"));
    assert_eq!(
        ctx.get("projects_count").map(String::as_str),
        Some("…"),
        "contador deve voltar a 'carregando', não a um 0 mentiroso"
    );
}

/// Regressão: o item "Projects" da sidebar apagava (perdia o fundo azul)
/// assim que você entrava num projeto ou num serviço — `nav_item.gvb`
/// comparava `{view}` contra um `target` de UMA view só (`equals`), e
/// `project_services`/`service` não são `"projects"`.
#[test]
fn nav_item_projects_fica_aceso_nas_sub_telas() {
    use glacier_ui::parser::NodeType;

    fn projects_nav_button_lit<'a>(node: &'a glacier_ui::parser::UiNode) -> Option<bool> {
        if let NodeType::Button {
            on_click, color, ..
        } = &node.kind
            && on_click.as_deref() == Some("NavItem::nav_projects")
        {
            return Some(color.as_deref() == Some("#1F6FEB"));
        }
        node.children.iter().find_map(projects_nav_button_lit)
    }

    let mut m = boot();
    for (view, esperado_aceso) in [
        ("deployments", false),
        ("projects", true),
        ("project_services", true),
        ("service", true),
        ("settings", false),
    ] {
        m.define_data("screen", "shell");
        m.define_data("view", view);
        m.reevaluate_all()
            .unwrap_or_else(|e| panic!("eval view {view}: {e}"));
        let ast = m.evaluated("app").expect("app evaluated");
        let aceso = projects_nav_button_lit(ast).expect("item Projects deveria existir na sidebar");
        assert_eq!(
            aceso,
            esperado_aceso,
            "view={view}: item Projects deveria estar {} ",
            if esperado_aceso { "aceso" } else { "apagado" }
        );
    }
}

/// Janela, título e tamanho (glacier-ui 0.117): a janela PRINCIPAL é do `app(...)`
/// de `views/app.gvb` (tamanho, mínimo, moldura, ícone); o título é da `screen`
/// (acompanha a navegação); e o tamanho de cada janela FILHA vai na chamada
/// `open_window{ component = "…", size = "…" }` dos handlers, porque a `screen` é
/// só conteúdo.
#[test]
fn janelas_declaram_titulo_e_tamanho() {
    cd_ws_root();

    let mut m = GlacierUI::new();
    m.register_app("views/app.gvb").expect("app.gvb deve registrar");
    let janela = m.main_window_meta().expect("o app declara a janela principal");
    assert_eq!(janela.title.as_deref(), Some("Rustploy"), "título da principal");
    assert_eq!(janela.size, Some((1280.0, 820.0)), "tamanho da principal");
    assert_eq!(janela.min_size, Some((480.0, 680.0)), "o min_size da principal");
    assert_eq!(janela.decorations, Some(false), "a principal é borderless");
    assert!(janela.icon.is_some(), "o app declara o ícone");

    let filhas = [
        ("new_project", Some("Novo projeto — Rustploy"), "460 340", "handlers/projects.luau"),
        ("new_job", Some("Novo job — Rustploy"), "560 700", "handlers/jobs.luau"),
        ("new_service", Some("Novo serviço — Rustploy"), "560 700", "handlers/wizard.luau"),
        ("new_registry_token", Some("Novo token — Rustploy"), "480 420", "handlers/registry.luau"),
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
        assert!(src.contains(&chamada), "{handler} deve abrir `{tela}` com `{chamada}`");
    }
}

/// O `app(...)` declara os ajustes do daemon que saíram de `app/mod.rs`
/// (glacier-ui 0.119): fontes, fonte padrão, antialiasing, período dos toasts e
/// `application_id`.
#[test]
fn app_declara_fontes_e_ajustes_do_daemon() {
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
        assert!(std::path::Path::new(&f.src).is_file(), "a fonte {} deve existir", f.src);
    }
}

/// Remove os comentários (`//` e `/* … */`) para que "a primeira tag" seja a
/// primeira tag de verdade: todo template daqui abre com um comentário de
/// cabeçalho.
fn comentarios_fora(src: &str) -> String {
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
fn todo_template_comeca_com_cabecalho() {
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
            let sem_comentarios = comentarios_fora(&src);
            let primeira: String = sem_comentarios
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
                !(so_component && !e_component),
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

/// As grades de cards (projetos e serviços) passam o item INTEIRO ao componente
/// via `spread="{c}"` (glacier-ui 0.62).
#[test]
fn grades_de_cards_renderizam_com_spread() {
    let mut m = boot();
    m.define_data("screen", "shell");
    m.define_data("data_loading", "false");

    m.define_data("view", "projects");
    m.define_data(
        "project_rows",
        r##"[{"cards":[
            {"filler":"0","id":"prj_1","name":"acme","description":"loja",
             "service_count":"3","running_count":"2","can_delete":"0"},
            {"filler":"1","id":"","name":"","description":"","service_count":"",
             "running_count":"","can_delete":"","port":"","status_label":"",
             "status_color":"","cpu":"","mem":"","container_name":"",
             "container_id":"","container_extra":"","project":""}
        ]}]"##,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval grade de projetos: {e}"));
    assert!(m.render("app").is_ok(), "render grade de projetos");
    let arv = format!("{:?}", m.evaluated("app").unwrap());
    assert!(
        arv.contains("acme"),
        "a grade tem que ter renderizado o card"
    );

    m.define_data("view", "project_services");
    m.define_data("proj_loading", "false");
    m.define_data(
        "project_services",
        r##"[{"cards":[
            {"filler":"0","id":"svc_1","name":"api","project":"acme","port":"8080",
             "status_label":"Rodando","status_color":"#A6E3A1","cpu":"1.2%","mem":"64 MB",
             "container_name":"acme-api","container_id":"abc123","container_extra":"+1"},
            {"filler":"1","id":"","name":"","description":"","service_count":"",
             "running_count":"","can_delete":"","port":"","status_label":"",
             "status_color":"","cpu":"","mem":"","container_name":"",
             "container_id":"","container_extra":"","project":""}
        ]}]"##,
    );
    m.reevaluate_all()
        .unwrap_or_else(|e| panic!("eval grade de serviços: {e}"));
    assert!(m.render("app").is_ok(), "render grade de serviços");
}
