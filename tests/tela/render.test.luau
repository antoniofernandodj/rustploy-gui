--!nonstrict
-- O que a tela MOSTRA, não só o estado que os handlers escrevem. Cada teste
-- monta a tela com dados de exemplo (a forma que o `format/*.luau` produz),
-- avalia o markup e confere a árvore avaliada: sobe sem erro, tem o texto e o
-- botão certos, esconde o que deve esconder, e o estilo resolvido na largura
-- da janela.
--
-- `tela:render()` reavalia a tela do zero com o `ctx` de agora e LANÇA se o
-- markup ou um import estiver quebrado — é o "sobe sem erro" de cada passo.
--
-- LIMITE: avalia, não desenha. Um widget que o iced recusa na construção só
-- aparece no `make run`. O que depende do manifesto (`app(...)`: título e
-- tamanho das janelas, fontes) e da estrutura dos arquivos fica em
-- `tests/app_manifest.rs`.

-- O init do app pré-preencheria `access_key` com o servidor salvo da máquina.
local function app(visao, extra)
    local tela = component("views/app.gv", { access_key = "x" })
    tela:call("init")
    if visao then
        tela:set("screen", "shell")
        tela:set("view", visao)
    end
    for k, v in extra or {} do
        tela:set(k, v)
    end
    return tela
end

-- Avalia a tela com o ctx de agora; lança se o markup estiver quebrado.
local function rende(tela)
    assert_not_nil(tela:render())
end

local function seta(tela, dados)
    for k, v in dados do
        tela:set(k, v)
    end
end

local function tem_trecho(lista, trecho)
    for _, t in lista do
        if string.find(t, trecho, 1, true) then
            return true
        end
    end
    return false
end

local function contagem(lista, esperados)
    local n = 0
    for _, t in lista do
        if table.find(esperados, t) then
            n += 1
        end
    end
    return n
end

local SEMANA = {
    { id = "0", label = "Seg" },
    { id = "1", label = "Ter" },
    { id = "2", label = "Qua" },
    { id = "3", label = "Qui" },
    { id = "4", label = "Sex" },
    { id = "5", label = "Sáb" },
    { id = "6", label = "Dom" },
}

-- ── o app e as janelas ──────────────────────────────────────────────────────

--- o app e todos os imports carregam (uma view quebrada, mesmo não usada,
--- falha aqui)
function test_o_app_todo_carrega()
    assert_renders("views/app.gv")
end

--- cada janela auxiliar carrega por conta própria
function test_cada_janela_auxiliar_carrega()
    each({
        { "views/new_project_form.gv" },
        { "views/new_job_window.gv" },
        { "views/log_window.gv" },
        { "views/new_service_window.gv" },
        { "views/new_registry_token_window.gv" },
        { "views/service_export_window.gv" },
    }, function(caminho)
        assert_renders(caminho)
    end)
end

--- a tela de login aparece sem sessão
function test_login_renderiza()
    local tela = app()
    rende(tela)
    assert_true(#tela:buttons() > 0)
end

--- todas as visões do shell avaliam
function test_visoes_do_shell()
    each({
        { "deployments" },
        { "projects" },
        { "service" },
        { "monitoring" },
        { "ingress" },
        { "docker" },
        { "settings" },
        { "schedules" },
        { "support" },
    }, function(visao)
        rende(app(visao))
    end)
end

-- ── janelas auxiliares ──────────────────────────────────────────────────────

local function janela(caminho, dados)
    local base = { api_url = "http://localhost", api_token = "t" }
    for k, v in dados or {} do
        base[k] = v
    end
    return component(caminho, base)
end

--- janela Novo projeto
function test_janela_novo_projeto_renderiza()
    rende(janela("views/new_project_form.gv"))
end

--- janela Novo job, em cada passo e em cada tipo de recorrência
function test_janela_novo_job_passos_e_recorrencias()
    local tela = janela("views/new_job_window.gv", {
        new_job_projects = { { id = "prj_1", name = "acme" } },
        new_job_services = {
            { id = "svc_1", name = "web", project_id = "prj_1" },
        },
    })
    tela:set("new_job_step", "pick_project")
    rende(tela)

    seta(tela, {
        new_job_step = "pick_service",
        new_job_project_name = "acme",
        new_job_services_filtered = {
            { id = "svc_1", name = "web", project_id = "prj_1" },
        },
    })
    rende(tela)

    seta(tela, {
        new_job_step = "form",
        new_job_service_name = "web",
        new_job_time = "03:00",
        weekdays = SEMANA,
    })
    for _, tipo in { "manual", "interval", "daily", "weekly" } do
        tela:set("new_job_kind", tipo)
        rende(tela)
    end
end

--- janela de logs ao vivo
function test_janela_de_logs_renderiza()
    local tela = janela("views/log_window.gv", {
        log_window_title = "Logs · api",
        log_window_stream_url = "/api/services/svc1/logs",
        log_window_seed = {
            {
                stream = "Stdout",
                line = "hello",
                timestamp = "2026-07-10T23:00:00Z",
            },
        },
    })
    rende(tela)
end

local function wizard(dados)
    local base = {
        selected_project_id = "p1",
        project_name = "demo",
        new_service_database_has_dbname = "true",
        new_service_database_has_user = "true",
        new_service_database_has_rootpw = "true",
        new_service_database_has_replica = "true",
        new_service_databases = {
            { id = "postgres", label = "PostgreSQL", image = "postgres:18" },
        },
        new_service_templates = {
            {
                id = "forgejo",
                name = "Forgejo",
                description = "git",
                logo = "assets/blueprint-logos/forgejo/forgejo.svg",
                logo_kind = "svg",
            },
            {
                id = "wordpress",
                name = "WordPress",
                description = "cms",
                logo = "assets/blueprint-logos/wordpress/wordpress.png",
                logo_kind = "img",
            },
        },
        new_service_template_vars = {
            { idx = "0", label = "Domínio", placeholder = "x" },
        },
    }
    for k, v in dados or {} do
        base[k] = v
    end
    return janela("views/new_service_window.gv", base)
end

--- wizard Novo serviço, em cada passo
function test_janela_novo_servico_passos()
    local tela = wizard()
    for _, passo in
        {
            "pick_type",
            "pick_db",
            "app_form",
            "db_form",
            "compose_form",
            "pick_template",
            "template_form",
            "import_form",
        }
    do
        tela:set("new_service_step", passo)
        rende(tela)
    end
end

--- passo Importar, na tela do relatório (todas as listas e ramos preenchidos)
function test_janela_novo_servico_relatorio_de_importacao()
    local tela = wizard({
        new_service_step = "import_form",
        import_report = "true",
        import_file = "api.rustploy-service.yml",
        import_name = "api",
        import_conflict = "true",
        import_has_warnings = "true",
        import_warnings = { { text = "• Domínios trazidos: a.tech." } },
        import_has_service_missing = "true",
        import_service_text = "CACHE=\nOWN=",
        import_has_project_missing = "true",
        import_project_text = "REDIS_URL=",
        import_has_secret_missing = "true",
        import_secret_text = "SENTRY_DSN=",
        import_missing_provider = "github-acme",
        import_providers = { { id = "gp_1", label = "github", mark = "○" } },
        import_has_project_env = "true",
        import_project_env = {
            {
                key = "REDIS_URL",
                info = "em conflito",
                can_choose = "true",
                choice = "manter a do projeto",
            },
            {
                key = "SENTRY",
                info = "secret · igual",
                can_choose = "false",
                choice = "x",
            },
        },
        import_drop_domains = "false",
        import_deploy = "false",
    })
    rende(tela)
end

--- janela Exportar serviço: renderiza com o plano semeado
function test_janela_exportar_servico_renderiza()
    local tela = janela("views/service_export_window.gv", {
        export_service_id = "svc_1",
        export_plan = {
            service_name = "api",
            project_name = "Flow",
            service_env = {
                { key = "CACHE", is_secret = false, suggested = false },
            },
            project_env = {
                { key = "REDIS_URL", is_secret = false, suggested = true },
                { key = "NAO_LEVAR", is_secret = false, suggested = false },
                { key = "SENTRY", is_secret = true, suggested = false },
            },
        },
    })
    tela:call("init")
    rende(tela)
    assert_true(#tela:buttons() > 0)
end

-- ── deploy engine ───────────────────────────────────────────────────────────

--- as três abas do Deploy Engine, com fila, execução (stepper + popup) e
--- histórico
function test_deploy_engine_abas()
    local tela = app("deploy_engine", {
        deploy_engine_tab = "fila",
        deploy_engine_queued_count = "2",
        deploy_engine_paused = "true",
        deploy_engine_queued = {
            {
                deployment_id = "dep_1",
                pos = "1",
                service = "api",
                project = "acme",
            },
            {
                deployment_id = "dep_2",
                pos = "2",
                service = "worker",
                project = "acme",
            },
        },
    })
    rende(tela)

    seta(tela, {
        deploy_engine_tab = "executando",
        deploy_engine_active_count = "1",
        deploy_engine_active = {
            {
                service = "api",
                project = "acme",
                state_label = "BUILDING",
                state_kind = "info",
                steps = {
                    { text = "✓ Fila", status = "done" },
                    { text = "● Obter", status = "current" },
                    { text = "○ Live", status = "pending" },
                },
                total = "10s",
                phase = "4s",
                service_id = "svc_1",
            },
        },
        deploy_engine_detail_open = "true",
        deploy_engine_detail_title = "api",
        deploy_engine_detail_steps = {
            { text = "✓ Fila", status = "done" },
            { text = "✕ Obter", status = "failed" },
        },
        deploy_engine_detail_rows = {
            { label = "Pending", kind = "ok", dur = "2s", msg = "" },
            {
                label = "Failed",
                kind = "bad",
                dur = "—",
                msg = "build quebrou",
            },
        },
    })
    rende(tela)

    tela:set("deploy_engine_tab", "historico")
    rende(tela)
end

--- portas do host na tela de ingress
function test_ingress_portas_do_host()
    local tela = app("ingress", {
        host_ports_count = "1",
        host_ports = {
            {
                service = "web",
                project = "acme",
                host_port = "8081",
                container_port = "80",
            },
        },
    })
    rende(tela)
end

-- ── docker ──────────────────────────────────────────────────────────────────

local function docker()
    return app("docker", {
        docker_containers_count = "1",
        docker_containers = {
            {
                id_full = "c1",
                name = "rp_api_live",
                image = "acme/api:latest",
                owner = "acme / api",
                state_kind = "ok",
                state_label = "running",
                can_remove = "0",
            },
        },
        docker_images_count = "1",
        docker_images = {
            {
                id_full = "i1",
                tags = "acme/api:latest",
                owner = "acme / api",
                size = "120 MB",
                created = "12/07",
                in_use_kind = "ok",
                in_use_label = "EM USO",
            },
        },
        docker_volumes_count = "1",
        docker_volumes = {
            {
                name = "pgdata",
                owner = "—",
                size = "1.2 GB",
                in_use_kind = "ok",
                in_use_label = "EM USO",
            },
        },
        docker_networks_count = "1",
        docker_networks = {
            {
                name = "rp_net_acme",
                owner = "acme",
                in_use_kind = "ok",
                in_use_label = "EM USO",
            },
        },
        registry_status_label = "ativo em 127.0.0.1:5100",
        registry_status_enabled = "true",
        registry_storage_human = "340 MB",
        registry_repos_count = "1",
        registry_repos = {
            { name = "acme/api", tag_count = "3", size = "340 MB" },
        },
        registry_tokens_count = "1",
        registry_tokens = {
            { name = "ci", scope = "pull", created = "12/07" },
        },
        registry_selected_repo = "",
        registry_tags_loading = "false",
        registry_tags_count = "0",
        registry_tags = json.array({}),
    })
end

--- cada aba do Docker avalia
function test_docker_cada_aba()
    local tela = docker()
    local abas = { "containers", "images", "volumes", "networks", "registry" }
    for _, aba in abas do
        tela:set("docker_tab", aba)
        rende(tela)
    end
end

--- a célula da tabela sai avaliada com a linha (`@c.name`), não só o cabeçalho
function test_docker_a_celula_da_linha_e_avaliada()
    local tela = docker()
    tela:set("docker_tab", "containers")
    assert_has_text(tela, "rp_api_live")
end

--- o registry com um repositório selecionado lista as tags
function test_docker_registry_com_repositorio_selecionado()
    local tela = docker()
    seta(tela, {
        docker_tab = "registry",
        registry_selected_repo = "acme/api",
        registry_tags_count = "1",
        registry_tags = {
            {
                tag = "latest",
                size = "120 MB",
                created = "12/07",
                digest_short = "sha256:abcd1234",
            },
        },
    })
    rende(tela)
end

-- ── jobs agendados ──────────────────────────────────────────────────────────

local JOB_PARADO = {
    {
        id = "job_1",
        name = "backup-db",
        name_full = "backup-db",
        owner = "acme / postgres",
        recurrence = "a cada 6h",
        enabled = true,
        enabled_label = "Pausar",
        running = false,
        last_run_label = "ok",
        last_run_kind = "ok",
        last_run_id = "jrun_1",
        next_run_at = "12/07 03:00",
        is_warm = false,
        is_warming = false,
        warm_label = "frio",
        warm_kind = "muted",
        warm_reason = "nunca aquecido",
        warmed_at_label = "",
    },
}

local JOB_RODANDO = {
    {
        id = "job_1",
        name = "backup-db",
        name_full = "backup-db",
        owner = "acme / postgres",
        recurrence = "a cada 6h",
        enabled = false,
        enabled_label = "Ativar",
        running = true,
        last_run_label = "rodando…",
        last_run_kind = "warn",
        last_run_id = "jrun_2",
        next_run_at = "—",
        is_warm = true,
        is_warming = false,
        warm_label = "quente",
        warm_kind = "ok",
        warm_reason = "",
        warmed_at_label = "12/07 03:00",
    },
}

--- job parado: estado frio e todas as ações no painel — menos cancelar
-- O painel "Ações do job" mora dentro da célula da linha: o eval o avalia
-- mesmo fechado, e a lista de botões não cabia mais na linha, então uma ação
-- que sumisse aqui sumiria da tela.
function test_agenda_job_parado()
    local tela =
        app("schedules", { jobs_count = "1", jobs_summary = JOB_PARADO })
    assert_has_text(tela, "frio")
    assert_has_text(tela, "nunca aquecido")
    for _, botao in
        {
            "▶  Run now",
            "◐  Warm",
            "≡  View logs",
            "‖  Pausar",
            "✎  Edit",
            "✕  Remove",
        }
    do
        assert_has_button(tela, botao)
    end
    assert_no_button(tela, "■  Cancel run")
end

--- job rodando: quente, cancelável, e não oferece rodar de novo
function test_agenda_job_rodando()
    local tela =
        app("schedules", { jobs_count = "1", jobs_summary = JOB_RODANDO })
    assert_has_text(tela, "quente")
    assert_has_text(tela, "warmed 12/07 03:00")
    assert_has_button(tela, "■  Cancel run")
    assert_has_button(tela, "‖  Ativar")
    assert_no_button(tela, "▶  Run now")
end

-- ── projeto ─────────────────────────────────────────────────────────────────

local function projeto()
    return app("project_services", {
        project_loading = "false",
        project_env = {
            { key = "__c0", value = "# comentário", kind = "comment" },
            {
                key = "A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_"
                    .. "THAT_SHOULD_BE_TRUNCATED",
                key_display = "A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_TH…",
                value = "x",
                kind = "plain",
            },
        },
        project_jobs_count = "1",
        project_jobs = JOB_PARADO,
        project_secrets_count = "1",
        project_secrets = {
            { name = "GITHUB_TOKEN", name_display = "GITHUB_TOKEN" },
        },
    })
end

--- cada aba do projeto avalia
function test_projeto_cada_aba()
    local tela = projeto()
    for _, aba in { "services", "env", "secrets", "jobs" } do
        tela:set("project_tab", aba)
        rende(tela)
    end
end

--- a aba Jobs do projeto mostra o estado e as ações
function test_projeto_aba_jobs_mostra_estado_e_acoes()
    local tela = projeto()
    tela:set("project_tab", "jobs")
    assert_has_text(tela, "frio")
    for _, botao in { "◐  Warm", "✎  Edit", "✕  Remove" } do
        assert_has_button(tela, botao)
    end
end

--- variáveis em modo secret, e sem nenhum secret cadastrado
function test_projeto_env_em_modo_secret_e_sem_secrets()
    local tela = projeto()
    seta(tela, { project_tab = "env", project_env_new_is_secret = "true" })
    rende(tela)
    seta(
        tela,
        { project_secrets_count = "0", project_secrets = json.array({}) }
    )
    for _, aba in { "env", "secrets" } do
        tela:set("project_tab", aba)
        rende(tela)
    end
end

--- edição no lugar: a linha em edição ganha ✓ e ✕ no lugar do texto; as outras linhas seguem normais
function test_projeto_edicao_no_lugar_da_chave_e_do_valor()
    local tela = projeto()
    seta(tela, {
        project_tab = "env",
        project_env = {
            { key = "A", key_display = "A", value = "x", kind = "plain", secret_name = "", edit_key_id = "key:A", edit_value_id = "value:A" },
            { key = "B", key_display = "B", value = "y", kind = "plain", secret_name = "", edit_key_id = "key:B", edit_value_id = "value:B" },
        },
        env_edit_id = "",
    })
    local sem_edicao = tela:buttons()
    assert_false(tem_trecho(sem_edicao, "✓"), "sem edição não há ✓")
    assert_true(tem_trecho(sem_edicao, "✎"), "falta o botão de editar o valor")

    for _, id in { "key:A", "value:B" } do
        seta(tela, { env_edit_id = id, env_edit_draft = "novo" })
        rende(tela)
        local botoes = tela:buttons()
        assert_true(tem_trecho(botoes, "✓"), "em edição falta o ✓ (" .. id .. ")")
        assert_true(tem_trecho(botoes, "✕"), "em edição falta o ✕ (" .. id .. ")")
    end
end

--- projeto: botões de mover (🔒 ↓ nas variáveis em claro, 🔓 nas que apontam para secret e nos secrets)
function test_projeto_movimentos_entre_escopos()
    local tela = projeto()
    seta(tela, {
        project_tab = "env",
        project_service_options = '[{"id":"svc1","display":"db"}]',
        project_env = {
            { key = "A", key_display = "A", value = "x", kind = "plain", secret_name = "" },
            { key = "B", key_display = "B", value = "🔒 secret:B", kind = "secret", secret_name = "B" },
        },
    })
    local botoes = tela:buttons()
    assert_true(tem_trecho(botoes, "🔒"), "variável em claro sem o botão → secret")
    assert_true(tem_trecho(botoes, "↓"), "variável em claro sem o botão → serviço")
    assert_true(tem_trecho(botoes, "🔓"), "variável que aponta para secret sem o botão → variável")
    -- aba Secrets: 🔓 e ↓ em cada secret
    tela:set("project_tab", "secrets")
    local botoes_secrets = tela:buttons()
    assert_true(tem_trecho(botoes_secrets, "🔓"), "secret sem o botão → variável")
    assert_true(tem_trecho(botoes_secrets, "↓"), "secret sem o botão → serviço")
end

--- projeto: secret escondido mostra 👁 e "encrypted"; revelado mostra o valor, 🙈 e copiar
function test_projeto_secret_ver_valor()
    local Format = require("format")
    local tela = projeto()
    seta(tela, {
        project_tab = "secrets",
        project_secrets = Format.secret_rows({ "TOKEN" }, "project", {}),
        project_secrets_count = "1",
    })
    assert_true(tem_trecho(tela:buttons(), "👁"), "botão de ver valor ausente")
    assert_true(not tem_trecho(tela:buttons(), "🙈"), "botão de esconder não devia aparecer")
    assert_true(tem_trecho(tela:texts(), "encrypted"), "rótulo encrypted ausente")
    seta(tela, {
        project_secrets = Format.secret_rows({ "TOKEN" }, "project", { ["project:TOKEN"] = "valor-revelado" }),
    })
    assert_true(tem_trecho(tela:texts(), "valor-revelado"), "valor revelado ausente")
    assert_true(tem_trecho(tela:buttons(), "🙈"), "botão de esconder ausente")
    assert_true(tem_trecho(tela:buttons(), "📋"), "botão de copiar ausente")
    assert_true(not tem_trecho(tela:buttons(), "👁"), "botão de ver não devia aparecer")
end

-- ── configurações ───────────────────────────────────────────────────────────

--- Git: provedor OAuth e token
function test_configuracoes_git()
    local tela = app("settings", { gitea_count = "1", settings_tab = "git" })
    for _, modo in { "oauth", "pat" } do
        tela:set("git_provider_mode", modo)
        rende(tela)
    end
end

--- Web Server
function test_configuracoes_web()
    local tela = app("settings", {
        settings_tab = "web",
        server_settings_public_base = "https://rustploy.meusite.com",
    })
    rende(tela)
end

--- Manutenção: limpeza do Docker em cada recorrência
function test_configuracoes_manutencao()
    local tela = app("settings", {
        settings_tab = "maintenance",
        docker_cleanup_enabled = "true",
        docker_cleanup_hours = "6",
        docker_cleanup_time = "03:00",
        docker_cleanup_weekday = "0",
        weekdays = SEMANA,
        docker_cleanup_containers = "true",
        docker_cleanup_images = "true",
        docker_cleanup_images_all = "false",
        docker_cleanup_volumes = "false",
        docker_cleanup_volumes_all = "false",
        docker_cleanup_networks = "true",
        docker_cleanup_build_cache = "true",
        docker_cleanup_build_cache_older_than_hours = "168",
        docker_cleanup_images_older_than_hours = "168",
        docker_cleanup_next_run_label = "hoje às 03:00",
        docker_cleanup_last_run_text = "12/07 03:00 · 3 removidos · 120 MB "
            .. "liberados",
        docker_cleanup_running = "false",
        docker_cleanup_message = "",
    })
    for _, tipo in { "interval", "daily", "weekly" } do
        tela:set("docker_cleanup_kind", tipo)
        rende(tela)
    end
end

--- Sincronização com o git: desligada, ligada, pausada (divergência), commit recusado,
--- removidos no git e auditoria de valores em claro
function test_configuracoes_sincronizacao_git()
    local StateGit = require("format/state_git")
    local SHA = "da3da09aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local tela = app("settings", { settings_tab = "gitsync", gitea_providers = "[]" })
    rende(tela) -- desligada, sem snapshot ainda

    -- ligada em modo sync, tudo certo
    seta(tela, StateGit.context({
        mode = "sync",
        git_available = true,
        recovery_configured = true,
        last_commit = { sha = SHA, at = "2026-11-02T06:28:44Z", subject = "Atualiza projeto E2E" },
        last_push_ok = true,
        last_push_at = "2026-11-02T06:28:50Z",
        last_fetch_at = "2026-11-02T06:29:00Z",
    }, {}))
    seta(tela, { state_git_form_mode = "sync" })
    rende(tela)

    -- pausada por divergência + commit recusado + removidos + auditoria
    seta(tela, StateGit.context({
        mode = "sync",
        git_available = false,
        recovery_configured = false,
        ahead = 1,
        behind = 1,
        paused_reason = "o histórico divergiu",
        incoming_rejected = { sha = SHA, reason = "traz 1 valor(es) em claro" },
        removed_in_git = {
            { id = "serviço:svc_web", kind = "serviço", name = "web", project = "E2E", sha = SHA, at = "2026-11-02T06:28:44Z" },
        },
    }, {
        { definite = false, allowed = false, project = "E2E", scope = "projeto", what = "env PASSWORD_MIN_LENGTH" },
        { definite = true, allowed = false, project = "E2E", scope = "serviço api", what = "token de webhook sem cifra" },
    }))
    rende(tela)
    -- Os painéis abaixo do formulário (situação, divergência, removidos) são irmãos dentro do
    -- scrollable: já sumiram em silêncio quando ficaram fora de uma coluna só.
    local textos = tela:texts()
    assert_true(tem_trecho(textos, "o histórico divergiu"), "painel de divergência ausente")
    assert_true(tem_trecho(textos, "web"), "lista de removidos no git ausente")
    for _, modo in { "off", "commit", "sync" } do
        tela:set("state_git_form_mode", modo)
        rende(tela)
    end
end

--- Atualizações: sem consulta ainda, com versão nova e com erro do daemon
function test_configuracoes_atualizacoes()
    local tela = app("settings", { settings_tab = "updates" })
    rende(tela)

    seta(tela, {
        update_current_version = "0.1.7",
        update_latest_version = "0.1.8",
        update_checked_at_label = "25/10 14:03",
        update_is_available = "true",
        update_release_url = "https://github.com/o/r/releases/tag/v0.1.8",
        update_message = "Há uma versão nova: 0.1.8",
    })
    rende(tela)

    seta(tela, {
        update_is_available = "false",
        update_message = "UpdateCheckFailed: não consegui consultar o GitHub",
    })
    rende(tela)

    -- Com o helper de instalação: botões de atualizar e reverter, e o resultado
    -- da última tentativa (lido do daemon depois que a janela volta ao login).
    seta(tela, {
        update_is_helper_available = "true",
        update_is_available = "true",
        update_progress_message = "A atualização falhou: assinatura inválida",
    })
    rende(tela)
    seta(tela, { update_is_available = "false", update_progress_message = "" })
    rende(tela)

    -- Atualização do app: sem consulta, com versão nova instalável (.deb + pkexec) e com versão
    -- nova num app que não veio de .deb (só o comando manual).
    seta(tela, {
        update_app_current_version = "0.1.21",
        update_app_latest_version = "0.1.21",
        update_app_message = "O app está na versão mais recente.",
    })
    rende(tela)
    seta(tela, {
        update_app_latest_version = "0.1.22",
        update_app_is_available = "true",
        update_app_can_update = "true",
        update_app_message = "Há uma versão nova do app: 0.1.22",
    })
    rende(tela)
    -- Windows (zip do install.ps1): a mesma tela, com o texto da troca de arquivos.
    seta(tela, {
        update_app_install_kind = "zip",
        update_app_apply_hint = "O app baixa a versão nova e confere a assinatura; depois fecha, troca os arquivos e reabre sozinho.",
    })
    rende(tela)
    seta(tela, {
        update_app_can_update = "false",
        update_app_manual_command = "irm https://raw.githubusercontent.com/antoniofernandodj/rustploy/main/install.ps1 | iex",
    })
    rende(tela)
end

-- ── serviço ─────────────────────────────────────────────────────────────────

local function servico(aba)
    return app("service", {
        tab = aba or "general",
        env_text_open = "true",
        service_env = {
            { key = "__c0", value = "# comentário", kind = "comment" },
            {
                key = "OLA",
                key_display = "OLA",
                value = "mundo",
                kind = "plain",
            },
            {
                key = "A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_"
                    .. "THAT_SHOULD_BE_TRUNCATED",
                key_display = "A_VERY_LONG_ENVIRONMENT_VARIABLE_NAME_TH…",
                value = "x",
                kind = "plain",
            },
        },
        deployment_selected = "abc123",
        service_webhook_supported = "true",
        service_webhook_url = "https://rustploy.meusite.com/webhook/"
            .. "svc_01ABC/f4b53d4d9d574a55",
        service_webhook_url_short = "https://rustploy.meusite.com/webhook/"
            .. "svc_01ABC…",
        gitea_count = "1",
        provider_tab = "gitea",
    })
end

--- cada aba da tela de serviço avalia
function test_servico_cada_aba()
    each({
        { "general" },
        { "connection" },
        { "environment" },
        { "domains" },
        { "deployments" },
        { "healthcheck" },
        { "logs" },
        { "advanced" },
    }, function(aba)
        rende(servico(aba))
    end)
end

--- aba Environment: secrets do serviço aparecem (nome + cadeado), com o botão "→ secret" nas variáveis em claro
function test_servico_environment_secrets_do_servico()
    local Format = require("format")
    local tela = servico("environment")
    seta(tela, {
        service_secrets = Format.secret_rows({ "POSTGRES_PASSWORD", "API_TOKEN" }),
        service_secrets_count = "2",
    })
    local textos = tela:texts()
    assert_true(tem_trecho(textos, "POSTGRES_PASSWORD"), "nome do secret do serviço ausente")
    assert_true(tem_trecho(textos, "API_TOKEN"), "segundo secret ausente")
    assert_true(tem_trecho(tela:buttons(), "🔒"), "botão de mover para secret ausente")
    assert_true(tem_trecho(tela:buttons(), "↑"), "botão de subir para o projeto ausente")
    assert_true(tem_trecho(tela:buttons(), "🔓"), "botão de voltar a variável ausente")
    -- sem secrets: o estado vazio aparece
    seta(tela, { service_secrets = "[]", service_secrets_count = "0" })
    assert_true(tem_trecho(tela:texts(), "No secret in this service yet."), "estado vazio ausente")
end

--- aba Advanced: dependências (lista, seletor e botão) e a caixa de religar no boot
function test_servico_advanced_dependencias()
    local Format = require("format")
    local tela = servico("advanced")
    local servicos = {
        { id = "svc_db", spec = { name = "db" } },
        { id = "svc_cache", spec = { name = "cache" } },
        { id = "svc_api", spec = { name = "api" } },
    }
    local spec = { depends_on = { "svc_db" } }
    seta(tela, {
        service_dependencies = Format.dependency_rows(spec, servicos),
        service_dependency_options = Format.dependency_options(spec, "svc_api", servicos),
        service_dependencies_count = "1",
        service_form_autostart = "true",
    })
    local textos = tela:texts()
    assert_true(tem_trecho(textos, "db"), "dependência atual ausente")
    assert_true(tem_trecho(tela:buttons(), "Add dependency"), "botão de adicionar dependência ausente")
    -- sem dependências: o estado vazio aparece
    seta(tela, {
        service_dependencies = Format.dependency_rows({ depends_on = {} }, servicos),
        service_dependencies_count = "0",
    })
    assert_true(tem_trecho(tela:texts(), "No dependencies."), "estado vazio ausente")
end

--- o formatter: o próprio serviço e as dependências já postas não entram como candidatos
function test_dependencias_candidatos_e_removido()
    local Format = require("format")
    local servicos = {
        { id = "a", spec = { name = "a" } },
        { id = "b", spec = { name = "b" } },
        { id = "c", spec = { name = "c" } },
    }
    local candidatos = json.decode(Format.dependency_options({ depends_on = { "b" } }, "a", servicos))
    assert_eq(#candidatos, 1)
    assert_eq(candidatos[1].id, "c")
    -- id que sumiu aparece com rótulo próprio, para dar para remover
    local linhas = json.decode(Format.dependency_rows({ depends_on = { "fantasma" } }, servicos))
    assert_true(string.find(linhas[1].name, "fantasma", 1, true) ~= nil)
end

--- aba Geral: origem Git, zip e compose
function test_servico_geral_por_origem()
    local tela = servico("general")
    seta(
        tela,
        { service_source_kind = "Git", error_service_form_general_port = "" }
    )
    for _, provedor in { "git", "zip" } do
        tela:set("provider_tab", provedor)
        rende(tela)
    end
    seta(tela, {
        service_source_kind = "Compose",
        service_compose = "services:\n  web:\n    image: nginx\n",
        service_compose_original = "services:\n  web:\n    image: nginx\n",
    })
    rende(tela)
end

--- aba Deployments: webhook sem token e em serviço compose
function test_servico_webhook()
    local tela = servico("deployments")
    tela:set("service_webhook_url", "")
    rende(tela)
    tela:set("service_webhook_supported", "false")
    rende(tela)
end

-- ── a estrutura que a tela mostra ───────────────────────────────────────────

--- só a tela ativa é avaliada: o login não vaza para dentro do shell
function test_so_a_tela_ativa_e_avaliada()
    local login = app()
    local shell = app("deployments")
    assert_ne(login:texts(), shell:texts())
end

--- as grades de cards (projetos e serviços) passam o item inteiro (`spread`)
function test_grades_de_cards_com_spread()
    local campos = {
        "id",
        "name",
        "description",
        "service_count",
        "running_count",
        "can_delete",
        "port",
        "status_label",
        "status_color",
        "cpu",
        "mem",
        "container_name",
        "container_id",
        "container_extra",
        "project",
        "warm_label",
        "warm_color",
        "warm_reason",
        "container_name_full",
        "container_id_full",
    }
    -- O card de preenchimento: todas as props que o componente exige, vazias.
    local function filler()
        local card = { filler = "1", has_warm = "false" }
        for _, campo in campos do
            card[campo] = ""
        end
        return card
    end

    local tela = app("projects", { data_loading = "false" })
    tela:set("project_rows", {
        {
            cards = {
                {
                    filler = "0",
                    id = "prj_1",
                    name = "acme",
                    description = "loja",
                    service_count = "3",
                    running_count = "2",
                    can_delete = "0",
                },
                filler(),
            },
        },
    })
    rende(tela)
    assert_true(
        tem_trecho(tela:texts(), "acme"),
        "o card do projeto não foi renderizado"
    )

    seta(tela, {
        view = "project_services",
        project_tab = "services",
        project_loading = "false",
        project_services = {
            {
                cards = {
                    {
                        filler = "0",
                        id = "svc_1",
                        name = "api",
                        project = "acme",
                        port = "8080",
                        status_label = "Rodando",
                        status_color = "#A6E3A1",
                        cpu = "1.2%",
                        mem = "64 MB",
                        container_name = "acme-api",
                        container_id = "abc123",
                        container_extra = "+1",
                        has_warm = "false",
                        warm_label = "",
                        warm_color = "",
                        warm_reason = "",
                        container_name_full = "",
                        container_id_full = "",
                    },
                    filler(),
                },
            },
        },
    })
    rende(tela)
    assert_true(
        tem_trecho(tela:texts(), "api"),
        "o card do serviço não foi renderizado"
    )
end

--- a tela Em execução: o each aninhado (projeto -> serviços) chega aos cards
function test_em_execucao_cards_aninhados()
    local tela = app("running", {
        running_count = "1",
        running = {
            {
                project_id = "prj_1",
                project_name = "loja",
                count_label = "1 serviço",
                rows = {
                    {
                        cards = {
                            {
                                filler = "0",
                                id = "svc_1",
                                name = "api",
                                port = "8080",
                                status_label = "rodando",
                                status_color = "#3FB950",
                                kind_label = "App · Git",
                                branch = "main",
                                detail = "https://example.com/r.git",
                                domains = "domínio: app.example.com",
                                cpu = "1.0%",
                                mem = "10 MB",
                                checks = "1. migrate",
                                has_webhook = "true",
                                webhook = "https://h/webhook/svc_1/tok",
                                webhook_shown = "https://h/webhook/svc_1/"
                                    .. "••••••••",
                                reveal_label = "Mostrar",
                                has_warm = "true",
                                warm_label = "frio",
                                warm_color = "muted",
                            },
                        },
                    },
                },
            },
        },
    })
    assert_has_text(tela, "loja")
    assert_has_text(tela, "api")
    assert_true(
        tem_trecho(tela:texts(), "••••••••"),
        "webhook mascarado"
    )
    assert_true(tem_trecho(tela:buttons(), "Deploy"), "atalho de deploy")
end

-- ── navegação e estilo resolvido ────────────────────────────────────────────

local function nav_projects(tela)
    for _, b in tela:find_all({ kind = "button" }) do
        if b.attrs.on_click == "NavItem::nav_projects" then
            return b
        end
    end
    return nil
end

--- o item Projects da sidebar fica aceso nas sub-telas (não só em "projects")
-- Foi um bug real: o nav_item comparava `{view}` com UMA view só, e
-- `project_services`/`service` não são "projects".
function test_nav_projects_fica_aceso_nas_subtelas()
    each({
        { "deployments", false },
        { "projects", true },
        { "project_services", true },
        { "service", true },
        { "settings", false },
    }, function(visao, aceso)
        local item = nav_projects(app(visao))
        assert_not_nil(item, "o item Projects deveria existir na sidebar")
        assert_eq(item.style.color == "#1F6FEB", aceso, "view=" .. visao)
    end)
end

--- Settings mostra um ponto quando há versão nova do daemon, e só então
function test_nav_settings_mostra_ponto_com_versao_nova()
    local function pontos(tela)
        local total = 0
        for _, t in tela:texts() do
            if t == "●" then
                total += 1
            end
        end
        return total
    end
    local tela = app("projects", { update_is_available = "false" })
    local antes = pontos(tela)
    tela:set("update_is_available", "true")
    assert_eq(pontos(tela), antes + 1, "versão nova acende um ponto a mais")
end

--- o item aceso recolore ícone e rótulo pelo combinador `.nav-item--active >
--- …`
-- Se a regra composta não casasse, o item aceso ficaria com as cores base
-- (`--faint`/`--muted`), sem erro algum.
function test_nav_item_aceso_recolore_os_filhos_pelo_combinador()
    each({
        { "projects", "#E6EDF3", "#E6EDF3" },
        { "deployments", "#6E7681", "#8B949E" },
    }, function(visao, icone, rotulo)
        local item = nav_projects(app(visao))
        assert_not_nil(item, "o item Projects deveria existir na sidebar")
        local cores = {}
        for _, filho in item.children do
            table.insert(cores, filho.style.color)
        end
        assert_eq(cores, { icone, rotulo }, "view=" .. visao)
    end)
end

--- a sidebar é uma <drawer> ligada à chave `menu`
function test_sidebar_e_uma_gaveta_ligada_a_chave_menu()
    local tela = app("deployments", { menu = "true" })
    tela:set_viewport(731, 680)

    local gatilhos = 0
    for _, b in tela:find_all({ kind = "button" }) do
        if b.attrs.on_click == "drawer::toggle:menu" then
            gatilhos += 1
        end
    end
    assert_eq(
        gatilhos,
        1,
        'esperava um botão on_click="drawer::toggle:menu" (o ☰ da topbar)'
    )

    -- Gaveta aberta: os rótulos aparecem. `texts()` só devolve os visíveis,
    -- então um rótulo forçado a `hidden` não passaria aqui.
    local rotulos = {}
    for _, t in tela:texts() do
        if
            t == "Deploy Engine"
            or string.find(t, "Projects (", 1, true) == 1
        then
            table.insert(rotulos, t)
        end
    end
    assert_eq(
        #rotulos,
        2,
        'esperava "Deploy Engine" e "Projects (N)" na gaveta aberta'
    )
end

-- Em `view = "service"`, as ações têm duas fileiras que se alternam por
-- largura.
local ACOES_TEXTO = { "Deploy", "Reload", "Rebuild", "Stop" }
local ACOES_ICONE = { "▶", "⟳", "⚙", "■" }

--- aba Logs: a lista "Execuções anteriores" só aparece com execuções, e cada linha tem Ver logs / Excluir
function test_servico_aba_logs_lista_execucoes_anteriores()
    local SD = require("format/service_detail")
    local tela = servico("logs")
    -- sem execuções passadas: só o botão dos "Logs de execução"
    seta(tela, { log_executions_visible = "false", log_executions = json.array({}) })
    assert_has_button(tela, "Execution logs")
    assert_no_button(tela, "View logs")
    seta(tela, {
        log_executions_visible = "true",
        log_selected_none = "true",
        log_selected_label = "Clear selected (0)",
        log_executions = json.array(SD.log_execution_rows({
            {
                container_ids = { "old000000002" },
                deployment_id = "dep_2",
                started_at = "2026-11-05T10:00:00Z",
                ended_at = "2026-11-05T11:00:00Z",
                lines = 20,
                bytes = 2048,
                outcome = "Stopped",
            },
        }, {})),
    })
    assert_has_button(tela, "View logs")
    assert_has_button(tela, "Delete")
    assert_has_button(tela, "Select all")
    assert_true(tem_trecho(tela:texts(), "dep_2"), "resumo da execução ausente")
    -- sem seleção o "Limpar selecionados" fica travado
    local travado = tela:find_all({ text = "Clear selected (0)" })
    assert_eq(#travado, 1)
    assert_eq(travado[1].attrs.disabled, true)
    seta(tela, { log_selected_none = "false", log_selected_label = "Clear selected (1)" })
    local livre = tela:find_all({ text = "Clear selected (1)" })
    assert_eq(#livre, 1)
    assert_eq(livre[1].attrs.disabled, false)
end

--- as ações do serviço viram ícones quando a janela estreita
function test_acoes_do_servico_viram_icones_quando_estreito()
    local tela = app("service", { tab = "general" })

    tela:set_viewport(1400, 820)
    assert_eq({
        contagem(tela:buttons(), ACOES_TEXTO),
        contagem(tela:buttons(), ACOES_ICONE),
    }, { 4, 0 }, "em 1400px espera 4 botões de texto e 0 ícones")

    tela:set_viewport(980, 820)
    assert_eq({
        contagem(tela:buttons(), ACOES_TEXTO),
        contagem(tela:buttons(), ACOES_ICONE),
    }, { 0, 4 }, "em 980px espera 0 botões de texto e 4 ícones")
end

-- ── trava de ação em andamento ──────────────────────────────────────────────

--- o botão de uma ação suspensa num fetch fica travado até ela terminar
-- O init semeia `busy_<ação>` e o botão do template o liga em `disabled`.
function test_acao_em_andamento_trava_o_botao()
    local tela = app()
    assert_eq(
        tela:get("busy_connect"),
        "false",
        "o init deve semear o flag de cada ação instalada"
    )

    -- `connect` faz o login (fetch): a corrotina suspende com o flag ligado.
    -- O token de conexão é o base64 de `127.0.0.1:9::x`.
    tela:set("access_key", "MTI3LjAuMC4xOjk6Ong=")
    tela:call("connect")
    assert_eq(
        tela:get("busy_connect"),
        "true",
        "ação suspensa no fetch deve manter o botão bloqueado"
    )
end

--- projeto: o ↓ de mover só destrava com um serviço de destino escolhido (a opção nula "escolha…" o trava)
function test_projeto_mover_so_destrava_com_destino()
    local tela = projeto()
    seta(tela, {
        project_tab = "env",
        project_service_options = '[{"id":"","display":"escolha"},{"id":"svc1","display":"db"}]',
        project_env = {
            { key = "A", key_display = "A", value = "x", kind = "plain", secret_name = "" },
        },
        move_target_service_id = "",
    })
    local travado = tela:find_all({ text = "↓" })
    assert_eq(#travado, 1)
    assert_eq(travado[1].attrs.disabled, true)
    tela:set("move_target_service_id", "svc1")
    local livre = tela:find_all({ text = "↓" })
    assert_eq(#livre, 1)
    assert_eq(livre[1].attrs.disabled, false)
end
