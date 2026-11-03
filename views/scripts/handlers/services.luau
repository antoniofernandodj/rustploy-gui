--!strict
--!nolint FunctionUnused
-- handlers/services.luau — detalhe do serviço (service.gv): fetch completo,
-- mutações de spec/env, ciclo de vida (deploy/reload/stop), build logs de
-- deployments, picker Gitea. Exporta `fetch_service_detail` para
-- handlers/stream.luau reusar no desfecho de um deploy (evento bus
-- DeployStateChanged).

local State = require("../state")
local Helpers = require("../helpers")
local format = require("../format")
local History = require("history")

local M = {}

-- Fila efetiva de pré-deploy check: `pre_deploy_job_ids` quando não vazia,
-- senão cai no `pre_deploy_job_id` legado (retrocompat) — mesmo idioma de
-- `ServiceSpec::pre_deploy_checks` no lado Rust.
local function pre_deploy_checks_ids(spec: any): { string }
    if spec.pre_deploy_job_ids and #spec.pre_deploy_job_ids > 0 then
        return spec.pre_deploy_job_ids
    elseif spec.pre_deploy_job_id and spec.pre_deploy_job_id ~= "" then
        return { spec.pre_deploy_job_id }
    end
    return {}
end

-- Copiar nome/id do container do card (valor de item do ForEach: o
-- `clipboard:` da markup não o alcança, por isso `copy` + toast).
function copy_container_name(name: string): ()
    copy(name)
    toast { message = i18n.tr("Nome copiado"), kind = "success" }
end

function copy_container_id(container_id: string): ()
    copy(container_id)
    toast { message = i18n.tr("ID copiado"), kind = "success" }
end

-- Botões "Copiar" da markup: copia o valor da chave de contexto e avisa por
-- toast (o `clipboard:` embutido copia em silêncio). O sufixo é o NOME da
-- chave.
function copy_ctx(key: string): ()
    copy(ctx[key] or "")
    toast {
        message = i18n.tr("Copiado para a área de transferência"),
        kind = "success",
    }
end

-- ── Fetch completo do painel de detalhe ─────────────────────────────────────

-- Abrir o detalhe de um serviço: navega e dispara o fetch (spec + logs +
-- deployments + provedores Git). O fetch suspende a corrotina, sem travar a
-- UI; service_loading=true segura os Selects até tudo chegar.
function open_service(service_id: string): ()
    History.push()
    State.revealed_secrets = {}
    ctx.selected_service = service_id
    ctx.view = "service"
    ctx.tab = "general"
    ctx.service_error = ""
    ctx.deployment_selected = ""
    ctx.service_action_message = ""
    ctx.service_action_color = "#8B949E"
    ctx.archive_upload_active = "false"
    ctx.archive_upload_percent = 0
    if State.deploy_track.service_id ~= service_id then
        ctx.service_deploy_running = "false"
        ctx.service_deploy_elapsed = ""
    end
    ctx.service_loading = "true"
    M.fetch_service_detail(service_id)
end

-- Voltar (history.luau) reabre o serviço pelo mesmo caminho do clique — o
-- `ctx` ainda guarda o detalhe do ÚLTIMO serviço aberto — e devolve a aba em
-- que estava.
History.register("service", function(snap)
    open_service(snap.selected_service or "")
    ctx.tab = snap.tab
end)

-- One-shot: monta TODAS as chaves svc_*/f_* do painel de detalhe (equivalente
-- a net/services.rs::fetch_detail_inner).
function M.fetch_service_detail(service_id: string): ()
    local api = State.api
    if not api or service_id == "" then
        return
    end
    local service_get_ok, service_get_response =
        api:rpc { ServiceGet = { id = service_id } }
    if not service_get_ok or not service_get_response.Service then
        ctx.service_loading = "false"
        ctx.service_error = service_get_ok
                and i18n.tr("serviço não encontrado")
            or service_get_response
        return
    end
    local service_record = service_get_response.Service
    local spec = service_record.spec

    -- Nome + env vars do projeto (ServiceGet só traz o id). As env vars do
    -- projeto são a base herdada por todos os serviços; usamos elas junto do
    -- serviço para montar a URL externa (ver merged_env abaixo).
    local project_name = spec.project_id
    local project_env = {}
    local snap = State.snap
    if snap then
        for _, project in ipairs(snap.projects or {}) do
            if project.id == spec.project_id then
                project_name = project.name
                project_env = project.env_vars or {}
                break
            end
        end
    end

    -- Runtime logs NÃO são carregados aqui: vivem só na janela isolada de logs
    -- (open_logs_window, que busca o próprio tail). A janela principal não os
    -- renderiza nem os transmite, para não pagar reavaliação por linha.
    local deployments = {}
    local deploy_history_ok, deploy_history_response =
        api:rpc { DeployHistory = { service_id = service_id, limit = 30 } }
    if deploy_history_ok and deploy_history_response.Deployments then
        deployments = deploy_history_response.Deployments
    end

    local status_label, status_color =
        format.status_label_color(service_record.status)
    local source_kind, source_detail, source_build =
        format.source_summary_parts(spec.source)

    -- Campos editáveis da aba General (source).
    local source_fields = {
        repo_url = "",
        branch = "",
        username = "",
        credentials = "",
        build_path = "",
        watch_paths = "",
        submodules = false,
        dockerfile = "",
        context_path = "",
        build_stage = "",
    }
    local compose_content = ""
    local provider_tab, gen_provider_id, bound_url = "git", "", ""
    if spec.source.Git then
        local git_source = spec.source.Git
        source_fields.repo_url = git_source.url or ""
        source_fields.branch = git_source.branch or ""
        source_fields.username = git_source.username or ""
        source_fields.credentials = git_source.credentials or ""
        source_fields.build_path = git_source.root_path or ""
        source_fields.watch_paths =
            table.concat(git_source.watch_paths or {}, ", ")
        source_fields.submodules = git_source.submodules == true
        source_fields.dockerfile = git_source.dockerfile_path or ""
        source_fields.context_path = git_source.build_context or ""
        source_fields.build_stage = git_source.build_stage or ""
        if git_source.provider_id and git_source.provider_id ~= "" then
            provider_tab, gen_provider_id, bound_url =
                "gitea", git_source.provider_id, git_source.url or ""
        end
    elseif spec.source.Registry then
        source_fields.repo_url = spec.source.Registry.image or ""
    elseif spec.source.Compose then
        compose_content = spec.source.Compose.content or ""
    end

    -- Healthcheck → campos do form.
    local healthcheck = spec.healthcheck
    local healthcheck_kind, healthcheck_path, healthcheck_status =
        "tcp", "", ""
    if type(healthcheck.kind) == "table" and healthcheck.kind.Http then
        healthcheck_kind, healthcheck_path, healthcheck_status =
            "http",
            healthcheck.kind.Http.path or "",
            tostring(healthcheck.kind.Http.expected_status)
    elseif healthcheck.kind == "None" then
        healthcheck_kind = "none"
    elseif healthcheck.kind == "DockerNative" then
        healthcheck_kind = "docker"
    else
        healthcheck_kind = "tcp"
    end

    -- Rota primária (Connection) + provedores Gitea conectados.
    local routes = {}
    if spec.domains and #spec.domains > 0 then
        for _, domain in ipairs(spec.domains) do
            table.insert(routes, domain)
        end
    elseif spec.domain and spec.domain ~= "" then
        routes = { { domain = spec.domain, tls = spec.tls_enabled == true } }
    end
    local primary_route = routes[1]
    local pr_domain = primary_route and primary_route.domain or nil
    local pr_tls = primary_route and primary_route.tls == true or false

    ctx.service_loading = "false"
    ctx.service_error = ""
    ctx.service_id = service_record.id
    ctx.service_name = spec.name
    -- Aba General → "Nome do serviço": campo do form de rename + o aviso do
    -- que o rename muda (ou não) para este tipo de serviço.
    ctx.edit_service_name = spec.name
    ctx.error_edit_service_name = ""
    if source_kind == "Compose" then
        ctx.service_rename_note = i18n.tr(
            "A stack e os volumes do Docker não mudam com o nome: os dados continuam os mesmos."
        )
    else
        ctx.service_rename_note = i18n.tr(
            "O hostname interno (rp_<nome>) só passa a valer no próximo deploy. Outros serviços que usam o nome antigo em variáveis de ambiente precisam ser atualizados."
        )
    end
    ctx.service_project = project_name
    ctx.service_project_id = spec.project_id
    ctx.service_status_label = status_label
    ctx.service_status_color = status_color
    -- Containers reais em execução: o snapshot (State.snap) anexa a lista a
    -- cada serviço; buscamos pelo id (ServiceGet não carrega essa informação).
    local service_containers = {}
    if snap then
        for _, service in ipairs(snap.services or {}) do
            if service.service and service.service.id == service_id then
                service_containers = service.service.containers or {}
                break
            end
        end
    end
    ctx.service_containers = format.containers(service_containers)
    ctx.service_containers_count = tostring(#service_containers)
    ctx.service_source_kind = source_kind
    ctx.service_source_detail = source_detail
    ctx.service_compose = compose_content
    ctx.service_compose_original = compose_content
    ctx.service_build = source_build
    ctx.service_port = tostring(spec.port)
    ctx.service_host_port = spec.host_port and tostring(spec.host_port)
        or "—"
    ctx.service_domain = pr_domain or "—"
    ctx.service_tls = pr_tls and "enabled" or "disabled"
    ctx.service_replicas = tostring(spec.replicas)
    ctx.service_domains = format.domains_json(spec)
    ctx.service_domains_count = tostring(#routes)
    -- Credenciais para a URL externa: mesma fusão que o daemon faz em
    -- resolve_env (projeto = base, serviço sobrescreve). Serviços Compose de
    -- banco têm spec.env_vars vazio — os ${POSTGRES_*} vêm do projeto. Como
    -- env_plain retorna o primeiro match por chave, o serviço vem primeiro.
    local merged_env = {}
    for _, env_var in ipairs(spec.env_vars or {}) do
        table.insert(merged_env, env_var)
    end
    for _, env_var in ipairs(project_env) do
        table.insert(merged_env, env_var)
    end
    -- Valor completo (`*_url`) alimenta o clipboard; `*_url_short` é o que a
    -- markup exibe, truncado para não empurrar o botão "Copiar" para fora.
    ctx.service_external_url = format.external_url(
        pr_domain,
        pr_tls,
        spec.host_port,
        spec.db_kind,
        ctx.api_url,
        merged_env
    )
    ctx.service_external_url_short =
        format.ellipsis(ctx.service_external_url, 20)
    -- Internal URL vem pronta do daemon (`shared::connection`): host real,
    -- usuário/senha/database. `format.internal_url` fica só de fallback.
    local service_connection_info_ok, service_connection_info_response =
        api:rpc { ServiceConnectionInfo = { service_id = service_id } }
    if
        service_connection_info_ok
        and type(service_connection_info_response) == "table"
        and service_connection_info_response.ConnectionInfo
    then
        ctx.service_internal_url =
            service_connection_info_response.ConnectionInfo.internal_url
    else
        local compose_src = spec.source.Compose
        local compose_host = compose_src
                and format.compose_host(
                    compose_src.content,
                    compose_src.ingress_service
                )
            or nil
        ctx.service_internal_url = format.internal_url(
            spec.db_kind,
            format.safe_name(spec.name),
            spec.port,
            compose_host
        )
    end
    ctx.service_internal_url_short =
        format.ellipsis(ctx.service_internal_url, 20)
    ctx.service_database_kind = spec.db_kind or "—"
    M.load_shared_state(spec, service_id)
    M.load_migration_state(spec, service_id, project_env)
    ctx.service_healthcheck = format.healthcheck_summary(spec.healthcheck)
    ctx.service_run_command = spec.run_command or "—"
    ctx.service_run_args = (spec.run_args and #spec.run_args > 0)
            and table.concat(spec.run_args, " ")
        or "—"
    ctx.service_env =
        format.env_json_with_comments(spec.env_vars, spec.env_comments)
    ctx.service_env_count = tostring(#(spec.env_vars or {}))
    local dotenv =
        format.env_dotenv_with_comments(spec.env_vars, spec.env_comments)
    ctx.service_env_text = dotenv
    ctx.service_env_text_original = dotenv
    -- Secrets DESTE serviço (só os nomes; no deploy o de serviço vale antes do de projeto).
    local service_secret_names: { string } = {}
    local secret_list_ok, secret_list_response = api:rpc {
        SecretList = { project_id = spec.project_id, service_id = service_id },
    }
    if
        secret_list_ok
        and type(secret_list_response) == "table"
        and type(secret_list_response.SecretNames) == "table"
    then
        service_secret_names = secret_list_response.SecretNames
    end
    ctx.service_secrets = format.secret_rows(
        service_secret_names,
        service_id,
        State.revealed_secrets
    )
    ctx.service_secrets_count = tostring(#service_secret_names)
    ctx.service_deployments = format.deployments_detail(deployments)
    ctx.service_deployments_count = tostring(#deployments)
    -- Webhook de deploy (aba Deployments). Só serviços Application (Git ou
    -- Registry) têm token, e ele nasce no PRIMEIRO deploy — antes disso o
    -- daemon devolve WebhookUrl=null e a UI mostra o aviso em vez da URL.
    ctx.service_webhook_supported = spec.source.Compose and "false" or "true"
    ctx.service_webhook_url = ""
    ctx.service_webhook_url_short = ""
    if not spec.source.Compose then
        local get_webhook_url_ok, get_webhook_url_response =
            api:rpc { GetWebhookUrl = { service_id = service_id } }
        if
            get_webhook_url_ok
            and type(get_webhook_url_response) == "table"
            and get_webhook_url_response.WebhookUrl
        then
            M.set_webhook_url(get_webhook_url_response.WebhookUrl)
        end
    end
    -- Campos editáveis.
    ctx.service_form_domain = ""
    ctx.service_form_port = ""
    ctx.service_form_tls = "false"
    ctx.service_form_host_port = spec.host_port and tostring(spec.host_port)
        or ""
    ctx.service_form_healthcheck_kind = healthcheck_kind
    ctx.service_form_healthcheck_path = healthcheck_path
    ctx.service_form_healthcheck_status = healthcheck_status
    ctx.service_form_healthcheck_interval = tostring(healthcheck.interval_secs)
    ctx.service_form_healthcheck_timeout = tostring(healthcheck.timeout_secs)
    ctx.service_form_healthcheck_retries = tostring(healthcheck.retries)
    ctx.service_form_healthcheck_start =
        tostring(healthcheck.start_period_secs)
    ctx.service_form_replicas = tostring(spec.replicas)
    ctx.service_form_run_command = spec.run_command or ""
    ctx.service_form_pre_deploy_check_add_job_id = ""
    ctx.service_form_repo_url = source_fields.repo_url
    ctx.service_form_branch = source_fields.branch
    ctx.service_form_username = source_fields.username
    ctx.service_form_credentials = source_fields.credentials
    ctx.service_form_build_path = source_fields.build_path
    ctx.service_form_watch_paths = source_fields.watch_paths
    ctx.service_form_submodules = source_fields.submodules and "true"
        or "false"
    ctx.service_form_dockerfile = source_fields.dockerfile
    ctx.service_form_context_path = source_fields.context_path
    ctx.service_form_build_stage = source_fields.build_stage
    ctx.service_form_archive_path = ""
    ctx.service_form_general_port = tostring(spec.port)
    ctx.provider_tab = provider_tab
    ctx.gitea_provider_id = gen_provider_id

    -- Jobs do projeto (aba Advanced → fila de pré-deploy check). Ver
    -- docs/plano-pre-deploy-gate.md.
    local job_list_ok, job_list_response =
        api:rpc { JobList = { project_id = spec.project_id } }
    local project_jobs = job_list_ok and job_list_response.Jobs or nil
    ctx.pre_deploy_checks = format.pre_deploy_queue(spec, project_jobs)
    ctx.pre_deploy_checks_count = tostring(#(pre_deploy_checks_ids(spec)))
    ctx.pre_deploy_available_jobs =
        format.pre_deploy_available(spec, project_jobs)

    -- Dependências e religamento no boot (aba Advanced). Os candidatos são os outros serviços do projeto.
    local project_service_list_ok, project_service_list_response =
        api:rpc { ServiceList = { project_id = spec.project_id } }
    local project_services = project_service_list_ok
            and project_service_list_response.Services
        or nil
    ctx.service_dependencies = format.dependency_rows(spec, project_services)
    ctx.service_dependency_options =
        format.dependency_options(spec, service_id, project_services)
    ctx.service_dependencies_count = tostring(#(spec.depends_on or {}))
    ctx.service_form_dependency_add_id = ""
    ctx.service_form_autostart = (spec.autostart ~= false) and "true"
        or "false"

    -- Provedores Gitea conectados (para o picker de conta).
    local git_provider_list_ok, git_provider_list_response =
        api:rpc("GitProviderList")
    if git_provider_list_ok and git_provider_list_response.GitProviders then
        ctx.gitea_providers =
            format.git_providers(git_provider_list_response.GitProviders)
        ctx.gitea_count = tostring(#git_provider_list_response.GitProviders)
        -- Serviço já ligado a um provedor: pré-carrega repos/branches.
        if gen_provider_id ~= "" then
            local git_repo_list_ok, git_repo_list_response =
                api:rpc { GitRepoList = { provider_id = gen_provider_id } }
            if git_repo_list_ok and git_repo_list_response.GitRepos then
                ctx.gitea_repos =
                    format.git_repos(git_repo_list_response.GitRepos)
                ctx.gitea_message = tostring(#git_repo_list_response.GitRepos)
                    .. i18n.tr(" repositório(s)")
                local full
                for _, git_repo in ipairs(git_repo_list_response.GitRepos) do
                    if git_repo.clone_url == bound_url then
                        full = git_repo.full_name
                        break
                    end
                end
                if full then
                    ctx.gitea_repo = full
                    local git_branch_list_ok, git_branch_list_response =
                        api:rpc {
                            GitBranchList = {
                                provider_id = gen_provider_id,
                                repo_full_name = full,
                            },
                        }
                    if
                        git_branch_list_ok
                        and git_branch_list_response.GitBranches
                    then
                        ctx.gitea_branches = format.git_branches(
                            git_branch_list_response.GitBranches
                        )
                    end
                end
            end
        end
    end
end

-- ── Mutações de spec/env (ServiceGet → muta → ServiceUpdate) ────────────────

-- Busca o spec fresco, aplica `mutate(spec)`, envia ServiceUpdate e refaz o
-- fetch do detalhe. As validações (campo vazio etc.) vivem nos handlers, antes
-- de chamar with_spec; os closures só mutam o spec em lugar, sem retornar
-- erro.
local function with_spec(mutate: (spec: any) -> ()): ()
    local service_id = ctx.selected_service
    local api = State.api
    if not api or service_id == "" then
        return
    end
    local service_get_ok, service_get_response =
        api:rpc { ServiceGet = { id = service_id } }
    if not service_get_ok or not service_get_response.Service then
        ctx.service_action_message = i18n.tr("erro ao carregar spec")
        toast {
            message = tostring(i18n.tr("erro ao carregar o serviço")),
            kind = "error",
        }
        return
    end
    local spec = service_get_response.Service.spec
    mutate(spec)
    local service_update_ok, service_update_response = api:rpc_checked {
        ServiceUpdate = {
            id = service_id,
            spec = spec,
        },
    }
    if service_update_ok then
        ctx.service_action_message = i18n.tr("salvo")
        toast { message = tostring("Salvo"), kind = "success" }
        M.fetch_service_detail(service_id)
    else
        ctx.service_action_message = i18n.tr("erro: ")
            .. service_update_response
        toast { message = tostring(service_update_response), kind = "error" }
    end
end

-- ── Servidor de banco compartilhado (aba Databases) ─────────────────────────
-- Ver docs/plano-banco-compartilhado.md. O daemon cria database + usuário,
-- conecta o servidor à rede do projeto e grava a env var nele.

local SHAREABLE = {
    postgres = true,
    postgresql = true,
    mysql = true,
    mariadb = true,
    mongodb = true,
    mongo = true,
}

-- Preenche service_can_share / service_shared e, se compartilhado, a lista de
-- databases e de projetos (para o <select>).
function M.load_shared_state(spec: any, service_id: string): ()
    local api = State.api
    for _, key in ipairs({
        "service_form_shared_database_name",
        "service_form_shared_database_project",
        "service_form_shared_database_env",
        "service_form_shared_database_limit",
        "service_form_shared_database_timeout",
        "shared_database_url",
        "shared_database_url_short",
    }) do
        if ctx[key] == nil then
            ctx[key] = ""
        end
    end
    if ctx.service_form_shared_database_overwrite == nil then
        ctx.service_form_shared_database_overwrite = "false"
    end
    if ctx.service_form_shared_database_skip_env == nil then
        ctx.service_form_shared_database_skip_env = "false"
    end
    if ctx.service_shared_database_projects == nil then
        ctx.service_shared_database_projects = json.array({})
    end
    local kind = spec.db_kind and string.lower(spec.db_kind) or ""
    local can_share = SHAREABLE[kind] == true and spec.source.Compose ~= nil
    ctx.service_can_share = can_share and "true" or "false"
    local shared = can_share and spec.shared ~= nil
    ctx.service_shared = shared and "true" or "false"
    ctx.service_shared_databases = json.array({})
    ctx.service_shared_databases_count = "0"
    if not shared or not api then
        if ctx.tab == "databases" then
            ctx.tab = "general"
        end
        return
    end
    local project_list_ok, project_list_response = api:rpc("ProjectList")
    local names = {}
    local projs = {}
    if project_list_ok and project_list_response.Projects then
        for _, project in ipairs(project_list_response.Projects) do
            names[project.id] = project.name
            table.insert(projs, { id = project.id, name = project.name })
        end
    end
    ctx.service_shared_database_projects = json.encode(projs)
    local managed_database_list_ok, managed_database_list_response =
        api:rpc { ManagedDatabaseList = { server_service_id = service_id } }
    local rows = {}
    if
        managed_database_list_ok
        and managed_database_list_response.ManagedDatabases
    then
        for _, managed_database in
            ipairs(managed_database_list_response.ManagedDatabases)
        do
            table.insert(rows, {
                id = managed_database.id,
                name = managed_database.name,
                project = names[managed_database.project_id]
                    or managed_database.project_id,
                env_var = managed_database.env_var,
                url = managed_database.connection_url,
            })
        end
    end
    ctx.service_shared_databases = rows
    ctx.service_shared_databases_count = tostring(#rows)
end

function shared_enable(): ()
    with_spec(function(spec: any): ()
        -- tabela vazia serializa como objeto `{}` (SharedServerConfig)
        spec.shared = {}
    end)
end

function shared_disable(): ()
    if
        tonumber(ctx.service_shared_databases_count)
        and tonumber(ctx.service_shared_databases_count) > 0
    then
        toast {
            message = i18n.tr(
                "Remova os databases deste servidor antes de deixar de compartilhar"
            ),
            kind = "warning",
        }
        return
    end
    with_spec(function(spec: any): ()
        spec.shared = nil
    end)
end

function shared_database_show(shared_database_id: string): ()
    local _, shared_databases =
        Helpers.decode_list(ctx.service_shared_databases)
    for _, service_shared_database in ipairs(shared_databases) do
        if service_shared_database.id == shared_database_id then
            ctx.shared_database_url = service_shared_database.url
            ctx.shared_database_url_short = service_shared_database.name
                .. " → "
                .. service_shared_database.env_var
            return
        end
    end
end

function shared_database_create(): ()
    local api = State.api
    local name = Helpers.trim(ctx.service_form_shared_database_name)
    if name == "" or ctx.service_form_shared_database_project == "" then
        toast {
            message = i18n.tr("Informe o nome e o projeto consumidor"),
            kind = "warning",
        }
        return
    end
    local create_request = {
        server_service_id = ctx.selected_service,
        project_id = ctx.service_form_shared_database_project,
        name = name,
        env_var = Helpers.trim(ctx.service_form_shared_database_env),
        overwrite_env = Helpers.is_true(
            ctx.service_form_shared_database_overwrite
        ),
        skip_env = Helpers.is_true(ctx.service_form_shared_database_skip_env),
        connection_limit = tonumber(
            Helpers.trim(ctx.service_form_shared_database_limit)
        ),
        statement_timeout_ms = tonumber(
            Helpers.trim(ctx.service_form_shared_database_timeout)
        ),
    }
    ctx.service_action_message = i18n.tr("criando database…")
    local managed_database_create_ok, managed_database_create_response =
        api:rpc_checked { ManagedDatabaseCreate = create_request }
    if managed_database_create_ok then
        toast { message = i18n.tr("Database criado"), kind = "success" }
        ctx.service_action_message = i18n.tr("database criado")
        ctx.service_form_shared_database_name = ""
        M.fetch_service_detail(ctx.selected_service)
    else
        ctx.service_action_message = i18n.tr("erro: ")
            .. managed_database_create_response
        toast {
            message = tostring(managed_database_create_response),
            kind = "error",
        }
    end
end

function shared_database_delete(shared_database_id: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover database?"),
        message = i18n.tr(
            "O database e o usuário são apagados do servidor, com todos os dados. Ação irreversível."
        ),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local managed_database_delete_ok, managed_database_delete_response =
        State.api:rpc_checked {
            ManagedDatabaseDelete = { id = shared_database_id },
        }
    if managed_database_delete_ok then
        ctx.shared_database_url = ""
        M.fetch_service_detail(ctx.selected_service)
    else
        toast {
            message = tostring(managed_database_delete_response),
            kind = "error",
        }
    end
end

-- ── Migração para banco compartilhado (aba Migrar) ──────────────────────────
-- O daemon roda os 7 passos em segundo plano (pré-checagem, parar escritas,
-- dump+restore, verificação, trocar env, subir serviços, desligar o antigo).
-- "Atualizar" relê o andamento; Reverter/Descartar só com a migração
-- concluída.

local STEP_ICON = {
    ok = "✓",
    running = "…",
    failed = "✗",
    skipped = "–",
    pending = "·",
}

local function default_source_database(
    spec: any,
    project_env: { any }?
): string
    -- Serviço primeiro, depois o projeto (mesma precedência do deploy).
    for _, vars in ipairs({ spec.env_vars or {}, project_env or {} }) do
        for _, key in ipairs({ "POSTGRES_DB", "MYSQL_DATABASE" }) do
            for _, variable in ipairs(vars) do
                if
                    variable.key == key
                    and variable.value
                    and variable.value.Plain
                then
                    return variable.value.Plain
                end
            end
        end
    end
    return ""
end

function M.load_migration_state(
    spec: any,
    service_id: string,
    project_env: { any }?
): ()
    local api = State.api
    local kind = spec.db_kind and string.lower(spec.db_kind) or ""
    local can_migrate = SHAREABLE[kind] == true
        and spec.source.Compose ~= nil
        and spec.shared == nil
    ctx.service_can_migrate = can_migrate and "true" or "false"
    ctx.migration_has = "false"
    ctx.migration_can_finish = "false"
    if not can_migrate or not api then
        if ctx.tab == "migrar" then
            ctx.tab = "general"
        end
        return
    end
    for _, key in ipairs({
        "service_form_migration_destination",
        "service_form_migration_env",
        "migration_status",
        "migration_id",
        "migration_message",
    }) do
        if ctx[key] == nil then
            ctx[key] = ""
        end
    end
    if
        ctx.service_form_migration_database == nil
        or ctx.service_form_migration_database == ""
    then
        ctx.service_form_migration_database =
            default_source_database(spec, project_env)
    end
    local managed_database_list_all_ok, managed_database_list_all_response =
        api:rpc("ManagedDatabaseListAll")
    local dests = {}
    if
        managed_database_list_all_ok
        and managed_database_list_all_response.ManagedDatabases
    then
        for _, managed_database in
            ipairs(managed_database_list_all_response.ManagedDatabases)
        do
            if managed_database.project_id == spec.project_id then
                table.insert(dests, {
                    id = managed_database.id,
                    name = managed_database.name
                        .. " ("
                        .. managed_database.env_var
                        .. ")",
                })
            end
        end
    end
    ctx.migration_destinations = json.encode(dests)
    local migration_list_ok, migration_list_response =
        api:rpc { MigrationList = { project_id = spec.project_id } }
    if migration_list_ok and migration_list_response.Migrations then
        for _, migration in ipairs(migration_list_response.Migrations) do
            if migration.source_service_id == service_id then
                local steps = {}
                for _, step in ipairs(migration.steps) do
                    table.insert(steps, {
                        name = step.name,
                        icon = STEP_ICON[step.state] or "·",
                        detail = step.detail or "",
                    })
                end
                ctx.migration_steps = json.encode(steps)
                ctx.migration_status = migration.status
                ctx.migration_id = migration.id
                ctx.migration_has = "true"
                ctx.migration_can_finish = migration.status == "Completed"
                        and "true"
                    or "false"
                return
            end
        end
    end
end

function migration_refresh(): ()
    M.fetch_service_detail(ctx.selected_service)
end

function migration_start(): ()
    if
        ctx.service_form_migration_destination == ""
        or Helpers.trim(ctx.service_form_migration_database) == ""
    then
        toast {
            message = i18n.tr(
                "Escolha o database de destino e informe o de origem"
            ),
            kind = "warning",
        }
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Iniciar migração?"),
        message = i18n.tr(
            "Os serviços do projeto que usam este banco serão parados durante o dump/restore e subirão de novo no banco novo. O banco antigo é mantido (parado) para rollback."
        ),
        confirm_label = i18n.tr("Migrar"),
    }
    if not confirmed then
        return
    end
    local migration_start_ok, migration_start_response =
        State.api:rpc_checked {
            MigrationStart = {
                source_service_id = ctx.selected_service,
                source_database = Helpers.trim(
                    ctx.service_form_migration_database
                ),
                dest_database_id = ctx.service_form_migration_destination,
                env_var = Helpers.trim(ctx.service_form_migration_env),
            },
        }
    if migration_start_ok then
        toast {
            message = i18n.tr(
                "Migração iniciada — use Atualizar para acompanhar"
            ),
            kind = "success",
        }
        M.fetch_service_detail(ctx.selected_service)
    else
        toast { message = tostring(migration_start_response), kind = "error" }
    end
end

function migration_rollback(): ()
    local confirmed = confirm {
        title = i18n.tr("Reverter a migração?"),
        message = i18n.tr(
            "A app volta ao banco antigo. O que foi escrito no banco novo depois da migração se perde."
        ),
        confirm_label = i18n.tr("Reverter"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local migration_rollback_ok, migration_rollback_response =
        State.api:rpc_checked {
            MigrationRollback = {
                id = ctx.migration_id,
            },
        }
    if not migration_rollback_ok then
        toast {
            message = tostring(migration_rollback_response),
            kind = "error",
        }
    end
    M.fetch_service_detail(ctx.selected_service)
end

function migration_discard(): ()
    local confirmed = confirm {
        title = i18n.tr("Descartar o banco antigo?"),
        message = i18n.tr(
            "O serviço do banco antigo é removido, com os dados dele. Sem volta."
        ),
        confirm_label = i18n.tr("Descartar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local migration_discard_ok, migration_discard_response =
        State.api:rpc_checked {
            MigrationDiscard = {
                id = ctx.migration_id,
            },
        }
    if not migration_discard_ok then
        toast {
            message = tostring(migration_discard_response),
            kind = "error",
        }
        return
    end
    ctx.view = "projects"
    ctx.selected_service = ""
    toast { message = i18n.tr("Banco antigo descartado"), kind = "success" }
end

-- ── Renomear serviço (aba General → "Nome do serviço") ──────────────────────

-- on_validation_error do form(name = service_rename): o motor já acendeu o
-- :invalid e publicou {error_edit_service_name}; aqui é só o aviso.
function service_rename_show_validation_errors(_erros_json: string?): ()
    toast { message = i18n.tr("Informe o nome do serviço"), kind = "warning" }
end

-- on_submit: só roda com a validação (rules="required") aprovada. Unicidade
-- dentro do projeto é checada no daemon (a mensagem volta no toast).
function save_service_name(): ()
    local name = Helpers.trim(ctx.edit_service_name)
    if name == "" or name == ctx.service_name then
        return
    end
    with_spec(function(spec)
        spec.name = name
    end)
end

-- Move o domínio legado (domain/tls_enabled) para a lista `domains`.
local function materialize_domains(spec: any): ()
    if not spec.domains or #spec.domains == 0 then
        local routes = json.array {}
        if spec.domain and spec.domain ~= "" then
            table.insert(
                routes,
                { domain = spec.domain, tls = spec.tls_enabled == true }
            )
        end
        spec.domains = routes
    end
    spec.domain = nil
    spec.tls_enabled = false
end

function domain_add(): ()
    local domain = Helpers.trim(ctx.service_form_domain)
    if domain == "" then
        ctx.error_service_form_domain = i18n.tr("domínio vazio")
        return
    end
    ctx.error_service_form_domain = ""
    with_spec(function(spec: any): ()
        materialize_domains(spec)
        local route = {
            domain = domain,
            port = tonumber(Helpers.trim(ctx.service_form_port)),
            tls = Helpers.is_true(ctx.service_form_tls),
        }
        local found = false
        for index, existing_route in ipairs(spec.domains) do
            if existing_route.domain == domain then
                spec.domains[index] = route
                found = true
                break
            end
        end
        if not found then
            table.insert(spec.domains, route)
        end
    end)
end

function domain_delete(domain: string): ()
    with_spec(function(spec: any): ()
        materialize_domains(spec)
        local kept = json.array {}
        for _, route in ipairs(spec.domains) do
            if route.domain ~= domain then
                table.insert(kept, route)
            end
        end
        spec.domains = kept
    end)
end

function domain_hostport_save(): ()
    with_spec(function(spec: any): ()
        spec.host_port = tonumber(Helpers.trim(ctx.service_form_host_port))
    end)
end

-- Sentinela 0 = "aloque para mim": o daemon troca por uma porta livre da faixa
-- [external_ports] e a libera no firewall (rustployd-fw). O fetch pós-update
-- do with_spec já re-renderiza service_host_port/service_external_url com a
-- porta real.
function domain_hostport_auto(): ()
    with_spec(function(spec: any): ()
        spec.host_port = 0
    end)
end

function compose_save(): ()
    with_spec(function(spec: any): ()
        if spec.source.Compose then
            spec.source = { Compose = { content = ctx.service_compose or "" } }
        end
    end)
end

function compose_cancel(): ()
    ctx.service_compose = ctx.service_compose_original or ""
end

function healthcheck_save(): ()
    with_spec(function(spec: any): ()
        local kind = ctx.service_form_healthcheck_kind
        local healthcheck_kind: any
        if kind == "none" then
            healthcheck_kind = "None"
        elseif kind == "http" then
            local path = Helpers.trim(ctx.service_form_healthcheck_path)
            if path == "" then
                path = "/"
            end
            healthcheck_kind = {
                Http = {
                    path = path,
                    expected_status = tonumber(
                        Helpers.trim(ctx.service_form_healthcheck_status)
                    ) or 200,
                },
            }
        elseif kind == "docker" then
            healthcheck_kind = "DockerNative"
        else
            healthcheck_kind = "Tcp"
        end
        local current_healthcheck = spec.healthcheck
        spec.healthcheck = {
            kind = healthcheck_kind,
            interval_secs = tonumber(
                Helpers.trim(ctx.service_form_healthcheck_interval)
            ) or current_healthcheck.interval_secs,
            timeout_secs = tonumber(
                Helpers.trim(ctx.service_form_healthcheck_timeout)
            ) or current_healthcheck.timeout_secs,
            retries = tonumber(
                Helpers.trim(ctx.service_form_healthcheck_retries)
            ) or current_healthcheck.retries,
            start_period_secs = tonumber(
                Helpers.trim(ctx.service_form_healthcheck_start)
            ) or current_healthcheck.start_period_secs,
        }
    end)
end

function advanced_save(): ()
    with_spec(function(spec: any): ()
        local replicas = tonumber(Helpers.trim(ctx.service_form_replicas)) or 1
        if replicas < 1 then
            replicas = 1
        end
        spec.replicas = math.floor(replicas)
        local run_command = Helpers.trim(ctx.service_form_run_command)
        spec.run_command = (run_command ~= "") and run_command or nil
        spec.autostart = Helpers.is_true(ctx.service_form_autostart)
    end)
end

-- Adiciona o serviço escolhido às dependências. O daemon valida (sem ciclo, só serviços do mesmo
-- projeto) e a recusa aparece no toast de erro do with_spec.
function dependency_add(): ()
    local dependency_id = Helpers.trim(ctx.service_form_dependency_add_id)
    if dependency_id == "" then
        return
    end
    with_spec(function(spec: any): ()
        local kept = json.array {}
        local already = false
        for _, existing_id in ipairs(spec.depends_on or {}) do
            table.insert(kept, existing_id)
            if existing_id == dependency_id then
                already = true
            end
        end
        if not already then
            table.insert(kept, dependency_id)
        end
        spec.depends_on = kept
    end)
end

function dependency_delete(dependency_id: string): ()
    with_spec(function(spec: any): ()
        local kept = json.array {}
        for _, existing_id in ipairs(spec.depends_on or {}) do
            if existing_id ~= dependency_id then
                table.insert(kept, existing_id)
            end
        end
        spec.depends_on = kept
    end)
end

-- Move o `pre_deploy_job_id` legado pra `pre_deploy_job_ids` — mesmo idioma
-- de `materialize_domains`.
local function materialize_pre_deploy(spec: any): ()
    if not spec.pre_deploy_job_ids or #spec.pre_deploy_job_ids == 0 then
        spec.pre_deploy_job_ids = json.array(pre_deploy_checks_ids(spec))
    end
    spec.pre_deploy_job_id = nil
end

-- Adiciona o job escolhido (ctx.service_form_pre_deploy_check_add_job_id) ao
-- FIM da fila — a ordem de adição É a ordem de execução; reordene arrastando
-- na lista.
function pre_deploy_check_add(): ()
    local job_id = Helpers.trim(ctx.service_form_pre_deploy_check_add_job_id)
    if job_id == "" then
        return
    end
    with_spec(function(spec: any): ()
        materialize_pre_deploy(spec)
        local already = false
        for _, queued_job_id in ipairs(spec.pre_deploy_job_ids) do
            if queued_job_id == job_id then
                already = true
                break
            end
        end
        if not already then
            table.insert(spec.pre_deploy_job_ids, job_id)
        end
    end)
end

function pre_deploy_check_delete(job_id: string): ()
    with_spec(function(spec: any): ()
        materialize_pre_deploy(spec)
        local kept = json.array {}
        for _, queued_job_id in ipairs(spec.pre_deploy_job_ids) do
            if queued_job_id ~= job_id then
                table.insert(kept, queued_job_id)
            end
        end
        spec.pre_deploy_job_ids = kept
    end)
end

-- Reordena a fila (arraste): `v` é um JSON array de job_ids na nova ordem
-- (mesmo formato de `env_reorder` — o `reorder_key` do foreach é `id`).
function pre_deploy_check_reorder(reorder_json: string?): ()
    if not reorder_json then
        return
    end
    local json_decode_ok, job_ids = pcall(json.decode, reorder_json)
    if not json_decode_ok or type(job_ids) ~= "table" then
        return
    end
    with_spec(function(spec: any): ()
        materialize_pre_deploy(spec)
        spec.pre_deploy_job_ids = json.array(job_ids)
    end)
end

function general_save(): ()
    with_spec(function(spec: any): ()
        local port = tonumber(Helpers.trim(ctx.service_form_general_port))
        if port then
            spec.port = math.floor(port)
        end
        local function non_empty_or_default(
            raw_value: any,
            fallback: string
        ): string
            local trimmed = Helpers.trim(raw_value)
            if trimmed == "" then
                return fallback
            else
                return trimmed
            end
        end
        local function non_empty_or_nil(raw_value: any): string?
            local trimmed = Helpers.trim(raw_value)
            if trimmed == "" then
                return nil
            else
                return trimmed
            end
        end
        local repo = Helpers.trim(ctx.service_form_repo_url)
        local watch = json.array {}
        local watch_paths = ctx.service_form_watch_paths or ""
        for part in string.gmatch(watch_paths, "[^,]+") do
            local trimmed_part = Helpers.trim(part)
            if trimmed_part ~= "" then
                table.insert(watch, trimmed_part)
            end
        end
        local git = {
            Git = {
                url = repo,
                branch = non_empty_or_default(ctx.service_form_branch, "main"),
                root_path = non_empty_or_default(
                    ctx.service_form_build_path,
                    "."
                ),
                watch_paths = watch,
                submodules = Helpers.is_true(ctx.service_form_submodules),
                dockerfile_path = non_empty_or_default(
                    ctx.service_form_dockerfile,
                    "Dockerfile"
                ),
                build_context = non_empty_or_default(
                    ctx.service_form_context_path,
                    "."
                ),
                build_stage = non_empty_or_nil(ctx.service_form_build_stage),
                credentials = non_empty_or_nil(ctx.service_form_credentials),
                username = non_empty_or_nil(ctx.service_form_username),
                provider_id = non_empty_or_nil(ctx.gitea_provider_id),
            },
        }
        if spec.source.Compose then
            -- inalterado
        elseif spec.source.Git or Helpers.looks_like_git_url(repo) then
            spec.source = git
        else
            spec.source = { Registry = { image = repo } }
        end
    end)
end

-- Cancela o envio do zip em andamento (botão "Cancelar" da aba Zip). O
-- controlador só existe enquanto `archive_upload` roda.
local archive_upload_abort: any = nil

function archive_upload_cancel(): ()
    if archive_upload_abort then
        archive_upload_abort:abort()
    end
end

function archive_upload(): ()
    local api = State.api
    local service_id = ctx.selected_service or ""
    local path = Helpers.trim(ctx.service_form_archive_path)
    if not api or service_id == "" then
        return
    end
    if path == "" then
        ctx.service_action_message = i18n.tr("informe o caminho do zip")
        return
    end

    -- O motor lê o zip do disco ao enviar (`body_file`): nada de ler o arquivo
    -- inteiro para o Lua nem de base64. O progresso alimenta a barra da aba.
    local filename = path:match("([^/\\]+)$") or "archive.zip"
    archive_upload_abort = abort_controller()
    ctx.archive_upload_percent = 0
    ctx.archive_upload_active = "true"
    ctx.service_action_message = i18n.tr("enviando zip…")
    local upload_archive_ok, upload_archive_response =
        api:upload_archive(service_id, filename, path, {
            signal = archive_upload_abort,
            on_progress = function(progress: any): ()
                local percent = (progress.fraction or 0) * 100
                ctx.archive_upload_percent = percent
                ctx.service_action_message =
                    `enviando zip… {math.floor(percent)}%`
            end,
        })
    archive_upload_abort = nil
    ctx.archive_upload_active = "false"

    if upload_archive_ok and upload_archive_response.Service then
        ctx.service_action_message = i18n.tr("zip enviado")
        toast { message = tostring(i18n.tr("Zip enviado")), kind = "success" }
        M.fetch_service_detail(service_id)
    elseif upload_archive_response == "cancelado" then
        ctx.service_action_message = i18n.tr("envio cancelado")
    else
        ctx.service_action_message = i18n.tr("erro: ")
            .. tostring(upload_archive_response)
        toast { message = tostring(upload_archive_response), kind = "error" }
    end
end

-- ── Environment ──────────────────────────────────────────────────────────

-- Aplica uma ordem de keys (vars + linhas `__c<idx>`) a vars/comments: vars
-- reordenadas; cada comentário reancora na primeira var real que o segue.
local function reorder_env(
    vars: { any },
    comments: { any },
    keys: { any }
): ({ any }, { any })
    local var_keys = {}
    local by_key = {}
    for _, variable in ipairs(vars) do
        var_keys[variable.key] = true
        by_key[variable.key] = variable
    end
    local seen = {}
    local new_vars = json.array {}
    local new_comments = json.array {}
    for key_position, key in ipairs(keys) do
        local comment_index_text = key:match("^__c(%d+)$")
        if comment_index_text then
            -- __c é 0-based
            local comment_index = (tonumber(comment_index_text) or 0) + 1
            local comment = comments[comment_index]
            if comment then
                seen[comment_index] = true
                local anchor = nil
                for key_index = key_position + 1, #keys do
                    if var_keys[keys[key_index]] then
                        anchor = keys[key_index]
                        break
                    end
                end
                table.insert(
                    new_comments,
                    { text = comment.text, before_key = anchor }
                )
            end
        elseif by_key[key] then
            table.insert(new_vars, by_key[key])
            by_key[key] = nil
        end
    end
    for _, variable in ipairs(vars) do
        if by_key[variable.key] then
            table.insert(new_vars, variable)
        end
    end
    for index, comment in ipairs(comments) do
        if not seen[index] then
            table.insert(new_comments, comment)
        end
    end
    return new_vars, new_comments
end

-- on_validation_error do form(name = env_add) — a chave é `rules="required"`;
-- o motor publica {error_env_new_key} e acende o :invalid. Aqui é só o aviso.
function env_show_validation_errors(_erros_json: string?): ()
    toast { message = i18n.tr("Informe a chave (KEY)"), kind = "warning" }
end

function env_add(): ()
    -- rules="required" no form(...) garante a chave preenchida aqui.
    local key = Helpers.trim(ctx.env_new_key)
    local raw_value = ctx.env_new_value or ""
    -- `<secret:NOME>`/`secret:NOME` digitado no campo valor vira referência de
    -- secret, como no editor .env (parse_dotenv) — é o caminho para valores
    -- sensíveis aqui, já que a aba do serviço não tem o toggle "usar secret"
    -- do projeto. O daemon decifra no deploy (deploy/env_resolve.rs).
    local secret = Helpers.parse_secret_ref(raw_value)
    if not Helpers.confirm_env_key(key, ctx.service_env) then
        return
    end
    with_spec(function(spec: any): ()
        local kept = json.array {}
        for _, env_var in ipairs(spec.env_vars or {}) do
            if env_var.key ~= key then
                table.insert(kept, env_var)
            end
        end
        local value = secret and { Secret = secret } or { Plain = raw_value }
        table.insert(kept, { key = key, value = value })
        spec.env_vars = kept
    end)
    ctx.env_new_key = ""
    ctx.env_new_value = ""
end

-- on_validation_error do form(name = service_secret_add) — nome e valor são `rules="required"`.
function service_secret_add_show_validation_errors(_erros_json: string?): ()
    toast {
        message = i18n.tr("Preencha nome e valor do secret"),
        kind = "warning",
    }
end

-- Cria (ou sobrescreve) um secret do SERVIÇO aberto. Write-only como o do projeto: o daemon só devolve
-- os nomes. O novo valor vale no próximo deploy.
function service_secret_add(): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    if service_id == "" or project_id == "" or not api then
        return
    end
    local name = Helpers.trim(ctx.service_secret_new_name)
    local value = ctx.service_secret_new_value or ""
    local secret_set_ok, secret_set_response = api:rpc_checked {
        SecretSet = {
            project_id = project_id,
            service_id = service_id,
            name = name,
            value = value,
        },
    }
    if secret_set_ok then
        ctx.service_secret_new_name = ""
        ctx.service_secret_new_value = ""
        toast {
            message = i18n.tr('Secret "') .. name .. i18n.tr(
                '" salvo — vale no próximo deploy'
            ),
            kind = "success",
        }
        M.fetch_service_detail(service_id)
    else
        toast { message = tostring(secret_set_response), kind = "error" }
    end
end

function service_secret_delete(name: string): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    if service_id == "" or project_id == "" or name == "" or not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Remover secret?"),
        message = i18n.tr(
            'O valor cifrado será apagado e não há como recuperá-lo. Variáveis que referenciam "'
        )
            .. name
            .. i18n.tr('" passarão a receber valor vazio no próximo deploy.'),
        confirm_label = i18n.tr("Remover secret"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local secret_delete_ok, secret_delete_response = api:rpc_checked {
        SecretDelete = {
            project_id = project_id,
            service_id = service_id,
            name = name,
        },
    }
    if secret_delete_ok then
        toast {
            message = tostring(i18n.tr("Secret removido")),
            kind = "success",
        }
        M.fetch_service_detail(service_id)
    else
        toast { message = tostring(secret_delete_response), kind = "error" }
    end
end

-- "→ secret" numa variável em claro: o valor passa a ser guardado cifrado e a variável vira uma
-- referência ao secret (mesmo nome). O valor não muda, então nada precisa ser redigitado.
function env_to_secret(key: string): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    if service_id == "" or project_id == "" or key == "" or not api then
        return
    end
    local move_ok, move_response = api:rpc_checked {
        SecretMove = {
            project_id = project_id,
            service_id = service_id,
            name = key,
            op = "EnvToSecret",
        },
    }
    if move_ok then
        toast {
            message = i18n.tr("Variável movida para secret: ") .. key,
            kind = "success",
        }
        M.fetch_service_detail(service_id)
    else
        toast { message = tostring(move_response), kind = "error" }
    end
end

-- 👁 num secret do serviço: pede o valor ao daemon (SecretReveal, que grava auditoria: quem, qual,
-- quando; nunca o valor) e o mostra na linha. Só em memória; 🙈 ou trocar de tela esconde.
function service_secret_reveal(name: string): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    if service_id == "" or project_id == "" or name == "" or not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Ver o valor do secret?"),
        message = i18n.tr('O valor de "')
            .. name
            .. i18n.tr(
                '" vai aparecer na tela. O acesso fica registrado na auditoria do servidor (quem, qual secret e quando; nunca o valor).'
            ),
        confirm_label = i18n.tr("Ver valor"),
    }
    if not confirmed then
        return
    end
    local reveal_ok, reveal_response = api:rpc {
        SecretReveal = {
            project_id = project_id,
            service_id = service_id,
            name = name,
        },
    }
    if
        not reveal_ok
        or type(reveal_response) ~= "table"
        or reveal_response.SecretValue == nil
    then
        toast { message = tostring(reveal_response), kind = "error" }
        return
    end
    State.revealed_secrets[service_id .. ":" .. name] =
        reveal_response.SecretValue :: string
    M.fetch_service_detail(service_id)
end

function service_secret_hide(name: string): ()
    local service_id = ctx.selected_service or ""
    State.revealed_secrets[service_id .. ":" .. name] = nil
    M.fetch_service_detail(service_id)
end

-- Copia o valor já revelado (a chave é "escopo:nome", a mesma da linha).
function secret_copy(ref: string): ()
    local value = State.revealed_secrets[ref]
    if value == nil then
        return
    end
    copy(value)
    toast {
        message = i18n.tr("Valor copiado para a área de transferência"),
        kind = "success",
    }
end

-- Grava o mini-formulário de renomear (armado por service_env_rename_pick / service_secret_rename_pick
-- em handlers/secrets.luau) para a variável ou o secret do SERVIÇO aberto.
function service_rename_apply(): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    local from = ctx.rename_from or ""
    local to = Helpers.trim(ctx.rename_to)
    if service_id == "" or project_id == "" or from == "" or not api then
        return
    end
    if to == "" or to == from then
        toast {
            message = i18n.tr("Digite um nome novo, diferente do atual."),
            kind = "warning",
        }
        return
    end
    local body = {
        project_id = project_id,
        service_id = service_id,
        from = from,
        to = to,
    }
    local rename_ok, rename_response
    if ctx.rename_open == "service_secret" then
        rename_ok, rename_response = api:rpc_checked { SecretRename = body }
    else
        rename_ok, rename_response = api:rpc_checked { EnvKeyRename = body }
    end
    if rename_ok then
        toast {
            message = i18n.tr("Renomeado: ") .. from .. " → " .. to,
            kind = "success",
        }
        ctx.rename_open = ""
        ctx.rename_from = ""
        ctx.rename_to = ""
        M.fetch_service_detail(service_id)
    else
        toast { message = tostring(rename_response), kind = "error" }
    end
end

-- Move genérico (SecretMove) de uma coisa do SERVIÇO aberto; `done_message` é o aviso de sucesso.
local function service_move(op: string, name: string, done_message: string): ()
    local service_id = ctx.selected_service or ""
    local project_id = ctx.service_project_id or ""
    local api = State.api
    if service_id == "" or project_id == "" or name == "" or not api then
        return
    end
    local move_ok, move_response = api:rpc_checked {
        SecretMove = {
            project_id = project_id,
            service_id = service_id,
            name = name,
            op = op,
        },
    }
    if move_ok then
        toast { message = done_message .. name, kind = "success" }
        M.fetch_service_detail(service_id)
    else
        toast { message = tostring(move_response), kind = "error" }
    end
end

-- 🔓 num secret do serviço (ou numa variável que aponta para um): volta a ser uma variável em
-- claro do serviço. Cuidado: o valor passa a ficar visível na lista e no YAML do estado.
function service_secret_to_env(name: string): ()
    local confirmed = confirm {
        title = i18n.tr("Voltar para variável em claro?"),
        message = i18n.tr('O valor de "')
            .. name
            .. i18n.tr(
                '" deixa de ser cifrado e passa a aparecer em claro na variável (e no estado versionado).'
            ),
        confirm_label = i18n.tr("Mover para variável"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    service_move(
        "SecretToEnv",
        name,
        i18n.tr("Secret movido para variável: ")
    )
end

-- ↑ secret do serviço → secret do projeto (todos os serviços do projeto passam a enxergá-lo).
function service_secret_to_project(name: string): ()
    local confirmed = confirm {
        title = i18n.tr("Subir para o projeto?"),
        message = i18n.tr('O secret "')
            .. name
            .. i18n.tr(
                '" passa a valer para todos os serviços deste projeto.'
            ),
        confirm_label = i18n.tr("Subir para o projeto"),
    }
    if not confirmed then
        return
    end
    service_move(
        "ServiceSecretToProject",
        name,
        i18n.tr("Secret movido para o projeto: ")
    )
end

-- ↑ variável em claro do serviço → variável do projeto (todos os serviços herdam).
function env_to_project(key: string): ()
    local confirmed = confirm {
        title = i18n.tr("Subir para o projeto?"),
        message = i18n.tr('A variável "')
            .. key
            .. i18n.tr(
                '" passa a valer para todos os serviços deste projeto.'
            ),
        confirm_label = i18n.tr("Subir para o projeto"),
    }
    if not confirmed then
        return
    end
    service_move(
        "EnvServiceToProject",
        key,
        i18n.tr("Variável movida para o projeto: ")
    )
end

function env_delete(key: string): ()
    with_spec(function(spec: any): ()
        local kept = json.array {}
        for _, env_var in ipairs(spec.env_vars or {}) do
            if env_var.key ~= key then
                table.insert(kept, env_var)
            end
        end
        spec.env_vars = kept
        local new_env_comments = json.array {}
        for _, env_comment in ipairs(spec.env_comments or {}) do
            if env_comment.before_key ~= key then
                table.insert(new_env_comments, env_comment)
            end
        end
        spec.env_comments = new_env_comments
    end)
end

function env_import(): ()
    local text = ctx.service_env_text or ""
    local _, _, errors = Helpers.parse_dotenv(text)
    if #errors > 0 then
        toast { message = Helpers.dotenv_errors_message(errors), kind = "error" }
        return
    end
    with_spec(function(spec: any): ()
        local vars, comments = Helpers.parse_dotenv(text)
        spec.env_vars = vars
        spec.env_comments = comments
    end)
    ctx.env_text_open = "false"
end

function env_export(): ()
    -- Abre o editor .env já preenchido (o texto vem do fetch em
    -- service_env_text).
    ctx.env_text_open = "true"
end

function env_text_toggle(): ()
    ctx.env_text_open = (Helpers.is_true(ctx.env_text_open)) and "false"
        or "true"
end

function env_text_cancel(): ()
    ctx.service_env_text = ctx.service_env_text_original or ""
    ctx.env_text_open = "false"
end

-- Reordena env (arraste): `value` é um JSON array de keys na nova ordem.
function env_reorder(reorder_json: string?): ()
    if not reorder_json then
        return
    end
    local json_decode_ok, keys = pcall(json.decode, reorder_json)
    if not json_decode_ok or type(keys) ~= "table" then
        return
    end
    with_spec(function(spec: any): ()
        local reordered_vars, reordered_comments =
            reorder_env(spec.env_vars or {}, spec.env_comments or {}, keys)
        spec.env_vars = reordered_vars
        spec.env_comments = reordered_comments
    end)
end

-- ── Deployments (build log + delete) ────────────────────────────────────────

-- Abre os build logs de um deployment numa JANELA à parte (mesma janela
-- genérica dos runtime logs — ver open_logs_window). Busca o histórico na hora
-- via GetBuildLogs (ação despachada → fetch funciona) e semeia; a janela então
-- segue ao vivo pelo endpoint dedicado /api/deployments/<id>/build-logs. Isola
-- o custo de rolar milhares de linhas de build fora da árvore da janela
-- principal.
function deployment_logs(deployment_id: string): ()
    if not deployment_id or deployment_id == "" then
        return
    end
    local seed = json.array({})
    local api = State.api
    if api then
        local get_build_logs_ok, get_build_logs_response =
            api:rpc { GetBuildLogs = { deployment_id = deployment_id } }
        if get_build_logs_ok and get_build_logs_response.BuildLogs then
            seed = json.array(get_build_logs_response.BuildLogs)
        end
    end
    open_window {
        component = "log",
        size = "900 560",
        decorations = false,
        title = i18n.tr("Build — ") .. string.sub(deployment_id, 1, 12),
        resizable = true,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            log_window_title = i18n.tr("Build logs · ")
                .. string.sub(deployment_id, 1, 12),
            log_window_stream_url = "/api/deployments/"
                .. deployment_id
                .. "/build-logs",
            log_window_seed = seed,
        },
    }
end

function delete_deployment(deployment_id: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover deployment?"),
        message = i18n.tr(
            "O registro do deployment e seus build logs serão removidos. Essa ação não pode ser desfeita."
        ),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api then
        return
    end
    local deploy_delete_ok, deploy_delete_response =
        api:rpc_checked { DeployDelete = { deployment_id = deployment_id } }
    ctx.service_action_message = deploy_delete_ok
            and i18n.tr("deployment removido")
        or ("erro: " .. deploy_delete_response)
    if not deploy_delete_ok then
        toast { message = tostring(deploy_delete_response), kind = "error" }
    end
    M.fetch_service_detail(ctx.selected_service)
end

-- ── Webhook de deploy ───────────────────────────────────────────────────────

-- A URL do webhook é longa (base + service_id + token de 48 hex). Exibida
-- inteira, ela estoura o card em janelas estreitas e passa por cima do painel
-- ao lado. A tela mostra a versão truncada; o valor completo fica em
-- `service_webhook_url` para o clipboard (e no tooltip).
function M.set_webhook_url(url: string): ()
    ctx.service_webhook_url = url
    ctx.service_webhook_url_short = format.ellipsis(url, 46)
end

-- Regenerar invalida o token antigo NA HORA: qualquer webhook já cadastrado no
-- GitHub/Gitea/Docker Hub com a URL anterior passa a receber 401. Por isso
-- passa pelo confirm.
function regenerate_webhook(): ()
    local confirmed = confirm {
        title = i18n.tr("Regenerar token do webhook?"),
        message = i18n.tr(
            "A URL atual para de funcionar imediatamente. Você precisará recadastrá-la no provedor (GitHub, Gitea, Docker Hub…)."
        ),
        confirm_label = i18n.tr("Regenerar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    local service_id = ctx.selected_service
    if not api or service_id == "" then
        return
    end
    local regenerate_webhook_token_ok, regenerate_webhook_token_response =
        api:rpc_checked {
            RegenerateWebhookToken = {
                service_id = service_id,
            },
        }
    if
        regenerate_webhook_token_ok
        and type(regenerate_webhook_token_response) == "table"
        and regenerate_webhook_token_response.WebhookUrl
    then
        M.set_webhook_url(regenerate_webhook_token_response.WebhookUrl)
        ctx.service_action_message = i18n.tr("token do webhook regenerado")
        toast {
            message = tostring(i18n.tr("Token do webhook regenerado")),
            kind = "success",
        }
    else
        local error_message = type(regenerate_webhook_token_response)
                    == "string"
                and regenerate_webhook_token_response
            or i18n.tr("falha ao regenerar o token")
        ctx.service_action_message = i18n.tr("erro: ") .. error_message
        toast { message = tostring(error_message), kind = "error" }
    end
end

-- ── Ciclo de vida do serviço ────────────────────────────────────────────────

local function service_lifecycle(command: any, message: string): ()
    local service_id = ctx.selected_service
    local api = State.api
    if not api or service_id == "" then
        return
    end
    ctx.service_action_message = message
    local rpc_ok, rpc_response = api:rpc_checked(command)
    if not rpc_ok then
        ctx.service_action_message = i18n.tr("erro: ") .. rpc_response
    end
    M.fetch_service_detail(service_id)
end

-- Deploy de um serviço (a partir de um card / detalhe). Arma deploy_track para
-- o timer decorrido (atualizado pelo snapshot de 2s, via engine.active) e o
-- desfecho (via evento bus DeployStateChanged, ver handlers/stream.luau).
local function start_deploy(requested_service_id: string?): ()
    local service_id = (requested_service_id and requested_service_id ~= "")
            and requested_service_id
        or ctx.selected_service
    local api = State.api
    if not api or not service_id or service_id == "" then
        return
    end
    ctx.service_action_message = i18n.tr("iniciando deploy…")
    ctx.service_action_color = "#58A6FF"
    -- Nome do serviço (para a notificação do SO no desfecho, ver stream.luau):
    -- resolvido agora, do snapshot corrente, pois o evento só traz o
    -- service_id.
    local service_name = ""
    for _, last_pair in ipairs(State.last_pairs) do
        if last_pair.svc.id == service_id then
            service_name = last_pair.svc.spec.name
            break
        end
    end
    local deploy_start_ok, deploy_start_response = api:rpc_checked {
        DeployStart = {
            service_id = service_id,
        },
    }
    if deploy_start_ok and deploy_start_response.Deployment then
        State.deploy_track = {
            service_id = service_id,
            deployment_id = deploy_start_response.Deployment.id,
            running = true,
            name = service_name,
        }
        ctx.service_deploy_running = "true"
        ctx.service_deploy_elapsed = "0s"
        ctx.service_action_message = i18n.tr("deploy iniciado · ")
            .. tostring(deploy_start_response.Deployment.state)
        toast {
            message = tostring(i18n.tr("Deploy iniciado")),
            kind = "success",
        }
    else
        ctx.service_action_message = deploy_start_ok
                and i18n.tr("resposta inesperada")
            or ("erro: " .. deploy_start_response)
        ctx.service_action_color = "#F85149"
        toast {
            message = tostring(
                deploy_start_ok and i18n.tr("resposta inesperada do daemon")
                    or deploy_start_response
            ),
            kind = "error",
        }
    end
    if ctx.selected_service == service_id then
        M.fetch_service_detail(service_id)
    end
end

-- Atalho "Deploy" do painel "Em execução": dispara o deploy sem abrir o
-- serviço.
function running_deploy(service_id: string): ()
    start_deploy(service_id)
end

function service_deploy(): ()
    start_deploy(ctx.selected_service)
end

function service_rebuild(): ()
    start_deploy(ctx.selected_service)
end

function service_reload(): ()
    service_lifecycle({
        ServiceReload = {
            service_id = ctx.selected_service,
        },
    }, i18n.tr("recarregando…"))
end

function service_stop(): ()
    local confirmed = confirm {
        title = i18n.tr("Parar serviço?"),
        message = i18n.tr(
            "O tráfego para este serviço será interrompido até um novo deploy."
        ),
        confirm_label = i18n.tr("Parar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    service_lifecycle({
        ServiceStop = {
            service_id = ctx.selected_service,
        },
    }, i18n.tr("parando…"))
end

-- Aquece o serviço (constrói a imagem para popular o cache de build) sem
-- fazer deploy: o container no ar não muda. Já quente: o daemon não dispara
-- nada e só avisa. O fim chega em `Event::ServiceWarmChanged`
-- (handlers/stream.luau); o selo acompanha o snapshot. Sem `refresh_now`
-- aqui: o começo também vira `ServiceWarmChanged`, que já atualiza a tela (e
-- `stream` requer este arquivo, então o contrário seria um ciclo).
function service_warm(): ()
    local api = State.api
    if not api then
        return
    end
    local service_warm_ok, service_warm_response = api:rpc_checked {
        ServiceWarm = { service_id = ctx.selected_service },
    }
    if not service_warm_ok then
        toast { message = tostring(service_warm_response), kind = "error" }
        return
    end
    if service_warm_response.ServiceWarmRequested.already_warm then
        toast {
            message = tostring(i18n.tr("Serviço já está aquecido")),
            kind = "success",
        }
    else
        toast {
            message = tostring(i18n.tr("Aquecimento iniciado")),
            kind = "success",
        }
    end
end

-- ── Picker Gitea (conta → repos → branches) ─────────────────────────────────

function gitea_provider_pick(provider_id: string): ()
    ctx.gitea_provider_id = provider_id or ""
    ctx.gitea_repo = ""
    ctx.gitea_repos = json.array({})
    ctx.gitea_branches = json.array({})
    local api = State.api
    if not api or provider_id == "" then
        return
    end
    ctx.gitea_message = i18n.tr("carregando repositórios…")
    ctx.gitea_busy = "true"
    local git_repo_list_ok, git_repo_list_response =
        api:rpc { GitRepoList = { provider_id = provider_id } }
    ctx.gitea_busy = ""
    if git_repo_list_ok and git_repo_list_response.GitRepos then
        ctx.gitea_repos = format.git_repos(git_repo_list_response.GitRepos)
        ctx.gitea_message = tostring(#git_repo_list_response.GitRepos)
            .. i18n.tr(" repositório(s)")
    else
        ctx.gitea_message = i18n.tr("erro ao listar repositórios")
    end
end

function gitea_repo_pick(full_name: string): ()
    if not full_name then
        return
    end
    ctx.gitea_repo = full_name
    -- Resolve clone_url/branch a partir da lista já carregada.
    local json_decode_ok, repos = Helpers.decode_list(ctx.gitea_repos)
    if json_decode_ok and type(repos) == "table" then
        for _, repo in ipairs(repos) do
            if repo.full_name == full_name then
                if repo.clone_url and repo.clone_url ~= "" then
                    ctx.service_form_repo_url = repo.clone_url
                end
                if repo.default_branch and repo.default_branch ~= "" then
                    ctx.service_form_branch = repo.default_branch
                end
                break
            end
        end
    end
    ctx.gitea_branches = json.array({})
    local provider_id = ctx.gitea_provider_id or ""
    local api = State.api
    if not api or provider_id == "" then
        return
    end
    ctx.gitea_message = i18n.tr("carregando branches…")
    ctx.gitea_busy = "true"
    local git_branch_list_ok, git_branch_list_response = api:rpc {
        GitBranchList = {
            provider_id = provider_id,
            repo_full_name = full_name,
        },
    }
    ctx.gitea_busy = ""
    if git_branch_list_ok and git_branch_list_response.GitBranches then
        ctx.gitea_branches =
            format.git_branches(git_branch_list_response.GitBranches)
        ctx.gitea_message = tostring(#git_branch_list_response.GitBranches)
            .. " branch(es)"
    else
        ctx.gitea_message = i18n.tr("erro ao listar branches")
    end
end

-- Abre os logs ao vivo do serviço numa JANELA à parte (motor Glacier isolado e
-- leve — ver log_window.gv/.luau). Semeia a conexão, o serviço-alvo e um tail
-- FRESCO via open_window({data}); a janela abre sua própria SSE (endpoint
-- dedicado) e rola os logs sem o custo de reavaliar a árvore inteira do app
-- principal. Sendo uma ação despachada, o `fetch` do LogsGet aqui funciona (ao
-- contrário do init de uma janela) — pegamos o tail na hora para não haver vão
-- entre o que a principal tinha e o que a stream ao vivo passa a entregar.
function open_logs_window(): ()
    local service_id = ctx.selected_service or ""
    if service_id == "" then
        return
    end
    local seed = json.array({})
    local api = State.api
    if api then
        local logs_get_ok, logs_get_response = api:rpc {
            LogsGet = {
                service_id = service_id,
                tail = 500,
            },
        }
        if logs_get_ok and logs_get_response.Logs then
            seed = json.array(logs_get_response.Logs)
        end
    end
    open_window {
        component = "log",
        size = "900 560",
        decorations = false,
        title = i18n.tr("Logs — ") .. (ctx.service_name or service_id),
        resizable = true,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            log_window_title = i18n.tr("Logs · ")
                .. (ctx.service_name or service_id),
            log_window_stream_url = "/api/services/" .. service_id .. "/logs",
            log_window_seed = seed,
        },
    }
end

return M
