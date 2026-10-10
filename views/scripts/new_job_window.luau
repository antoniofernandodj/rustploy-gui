--!strict
--!nolint FunctionUnused
-- new_job_window.luau — script da JANELA "Novo job", um motor Glacier próprio
-- e ISOLADO do app principal (aberto via open_window por
-- handlers/jobs.luau::open_new_job_window). Recebe a conexão (api_url/
-- api_token) e os catálogos de projetos/serviços JÁ BUSCADOS pela janela
-- principal, semeados via open_window({ data = ... }) — um `fetch` rodado no
-- `init()` é descartado pelo motor (só ações despachadas chegam ao
-- executor), mesma razão de `new_service_window.luau`.
--
-- require resolve relativo a ESTE arquivo (scripts/): "net/api", "helpers" e
-- "format" (só os builders de git_providers/git_repos/git_branches, reusados da
-- aba Gitea de serviço — ver handlers/services.luau).

local Api = require("net/api")
local Helpers = require("helpers")
local format = require("format")

local function client(): Api.Client?
    local url = ctx.api_url or ""
    if url == "" then
        return nil
    end
    return Api.new(url, ctx.api_token)
end

local function decode(json_text: string?): { any }
    local json_decode_ok, decoded = pcall(json.decode, json_text or "[]")
    if json_decode_ok and type(decoded) == "table" then
        return decoded
    end
    return {}
end

-- Recorrência (Option<Recurrence>, externally-tagged) → (kind, hours, hour,
-- minute, weekday), pro formulário. Inverso do bloco em new_job_create.
local function unpack_recurrence(recurrence: any): (string, string, string, string, string)
    if recurrence == nil then
        return "manual", "6", "3", "0", "0"
    end
    if recurrence.IntervalHours ~= nil then
        return "interval", tostring(recurrence.IntervalHours), "3", "0", "0"
    end
    if recurrence.Daily ~= nil then
        return "daily", "6", tostring(recurrence.Daily.hour), tostring(recurrence.Daily.minute), "0"
    end
    if recurrence.Weekly ~= nil then
        return "weekly", "6", tostring(recurrence.Weekly.hour), tostring(recurrence.Weekly.minute), tostring(recurrence.Weekly.weekday)
    end
    return "manual", "6", "3", "0", "0"
end

function init(): ()
    -- ctx.new_job_projects/new_job_services já chegam como JSON (semeados via data).
    ctx.new_job_projects = ctx.new_job_projects or "[]"
    ctx.new_job_services_all = ctx.new_job_services or "[]"
    ctx.new_job_services_filtered = "[]"

    ctx.new_job_step = "pick_project"
    ctx.new_job_project_id = ""
    ctx.new_job_project_name = ""
    ctx.new_job_service_id = ""
    ctx.new_job_service_name = ""
    ctx.new_job_name = ""
    ctx.new_job_compose = ""
    ctx.new_job_main_service = ""

    -- Fonte do compose: "compose" (colado, default) | "git" (clona um repo
    -- a cada execução — mesmo picker conta→repo→branch da aba Gitea de
    -- serviço). Ver new_job_source/new_job_git_provider_pick/new_job_git_repo_pick.
    -- Os campos de picker usam `or` (não sobrescrevem à força): em modo
    -- edição de job git-sourced, open_edit_job_window já resolveu e semeou
    -- esses valores (não dá pra buscar aqui dentro, ver docstring do topo).
    ctx.new_job_source = "compose"
    ctx.new_job_git_providers = ctx.new_job_git_providers or "[]"
    ctx.new_job_git_provider_id = ""
    ctx.new_job_git_repos = ctx.new_job_git_repos or "[]"
    ctx.new_job_git_repo = ctx.new_job_git_repo or ""
    ctx.new_job_git_branches = ctx.new_job_git_branches or "[]"
    ctx.new_job_git_branch = ""
    ctx.new_job_compose_path = "docker-compose.yml"
    ctx.new_job_git_message = ""
    ctx.new_job_git_busy = ""
    ctx.new_job_busy = ""

    -- Env vars próprias do job (blob .env colado, parseado em new_job_create).
    ctx.new_job_env_text = ""

    ctx.new_job_kind = "manual"
    ctx.new_job_hours = "6"
    -- Uma chave só, "HH:MM": quem edita o horário agora é o <timeedit> do
    -- .gvb. `unpack_recurrence` segue devolvendo hora/minuto separados (é o
    -- formato do daemon) e format.hour_minute_join/hour_minute_split fazem a ponte.
    ctx.new_job_time = "03:00"
    ctx.new_job_weekday = "0"
    -- Coleção fixa do <radiogroup> de dia da semana (recorrência Semanal).
    ctx.weekdays = format.WEEKDAYS_JSON
    ctx.new_job_error = ""
    ctx.new_job_message = ""

    -- ── Modo edição: open_edit_job_window semeia new_job_edit_job (Job cru em
    -- JSON) — pula os passos 1/2 (projeto/serviço gatilho não são editáveis
    -- via JobUpdate) e preenche o passo 3 inteiro com o job existente.
    ctx.new_job_edit_id = ""
    ctx.new_job_enabled = "true"
    if ctx.new_job_edit_job and ctx.new_job_edit_job ~= "" then
        local json_decode_ok, job = pcall(json.decode, ctx.new_job_edit_job)
        if json_decode_ok and type(job) == "table" then
            ctx.new_job_edit_id = job.id
            ctx.new_job_step = "form"
            ctx.new_job_name = job.name or ""
            ctx.new_job_main_service = job.main_service or ""
            ctx.new_job_enabled = job.enabled and "true" or "false"

            if job.git_source then
                ctx.new_job_source = "git"
                ctx.new_job_git_provider_id = job.git_source.provider_id or ""
                ctx.new_job_git_branch = job.git_source.branch or ""
                ctx.new_job_compose_path = job.git_source.compose_path or "docker-compose.yml"
                -- new_job_git_repo já vem semeado (resolvido por
                -- open_edit_job_window a partir de git_source.url).
            else
                ctx.new_job_compose = job.compose or ""
            end

            ctx.new_job_env_text = format.env_dotenv_with_comments(job.env_vars, job.env_comments)

            local kind, hours, hour, minute, weekday = unpack_recurrence(job.recurrence)
            ctx.new_job_kind = kind
            ctx.new_job_hours = hours
            ctx.new_job_time = format.hour_minute_join(hour, minute)
            ctx.new_job_weekday = weekday
        end
    end
end

-- onChange dos inputs (mesma convenção `field:<chave>` do app principal).
function field(key: string?, value: string?): ()
    if key then
        ctx[key] = value or ""
    end
end

-- ── Fonte do compose: Compose (colado) x Git (picker conta→repo→branch) ──
-- Idêntico a gitea_provider_pick/gitea_repo_pick de handlers/services.luau,
-- só que dentro desta janela isolada (não pode buscar no init(), mas ações
-- despachadas por clique/on_change chegam ao executor normalmente).

function new_job_source(kind: string): ()
    ctx.new_job_source = kind
    if kind == "git" and ctx.new_job_git_providers == "[]" then
        local api = client()
        if not api then
            return
        end
        ctx.new_job_git_message = "carregando contas…"
        ctx.new_job_git_busy = "true"
        local git_provider_list_ok, git_provider_list_response = api:rpc("GitProviderList")
        ctx.new_job_git_busy = ""
        if git_provider_list_ok and git_provider_list_response.GitProviders then
            ctx.new_job_git_providers = format.git_providers(git_provider_list_response.GitProviders)
            ctx.new_job_git_message = ""
        else
            ctx.new_job_git_message = "erro ao listar contas conectadas"
        end
    end
end

function new_job_git_provider_pick(provider_id: string): ()
    ctx.new_job_git_provider_id = provider_id or ""
    ctx.new_job_git_repo = ""
    ctx.new_job_git_repos = "[]"
    ctx.new_job_git_branches = "[]"
    local api = client()
    if not api or ctx.new_job_git_provider_id == "" then
        return
    end
    ctx.new_job_git_message = "carregando repositórios…"
    ctx.new_job_git_busy = "true"
    local git_repo_list_ok, git_repo_list_response = api:rpc{
        GitRepoList = { provider_id = ctx.new_job_git_provider_id }
    }
    ctx.new_job_git_busy = ""
    if git_repo_list_ok and git_repo_list_response.GitRepos then
        ctx.new_job_git_repos = format.git_repos(git_repo_list_response.GitRepos)
        ctx.new_job_git_message = tostring(#git_repo_list_response.GitRepos) .. " repositório(s)"
    else
        ctx.new_job_git_message = "erro ao listar repositórios"
    end
end

function new_job_git_repo_pick(full_name: string): ()
    if not full_name then
        return
    end
    ctx.new_job_git_repo = full_name
    local json_decode_ok, repos = pcall(json.decode, ctx.new_job_git_repos or "[]")
    if json_decode_ok and type(repos) == "table" then
        for _, repo in ipairs(repos) do
            if repo.full_name == full_name and repo.default_branch and repo.default_branch ~= "" then
                ctx.new_job_git_branch = repo.default_branch
                break
            end
        end
    end
    ctx.new_job_git_branches = "[]"
    local provider_id = ctx.new_job_git_provider_id or ""
    local api = client()
    if not api or provider_id == "" then
        return
    end
    ctx.new_job_git_message = "carregando branches…"
    ctx.new_job_git_busy = "true"
    local git_branch_list_ok, git_branch_list_response = api:rpc{
        GitBranchList = { provider_id = provider_id, repo_full_name = full_name }
    }
    ctx.new_job_git_busy = ""
    if git_branch_list_ok and git_branch_list_response.GitBranches then
        ctx.new_job_git_branches = format.git_branches(git_branch_list_response.GitBranches)
        ctx.new_job_git_message = ""
    else
        ctx.new_job_git_message = "erro ao listar branches"
    end
end

function new_job_pick_project(project_id: string): ()
    ctx.new_job_project_id = project_id
    local name = ""
    for _, new_job_project in ipairs(decode(ctx.new_job_projects)) do
        if new_job_project.id == project_id then
            name = new_job_project.name
        end
    end
    ctx.new_job_project_name = name

    local filtered = {}
    for _, service in ipairs(decode(ctx.new_job_services_all)) do
        if service.project_id == project_id then
            table.insert(filtered, service)
        end
    end
    ctx.new_job_services_filtered = json.encode(filtered)
    ctx.new_job_step = "pick_service"
end

function new_job_pick_service(service_id: string): ()
    ctx.new_job_service_id = service_id
    local name = ""
    for _, service in ipairs(decode(ctx.new_job_services_filtered)) do
        if service.id == service_id then
            name = service.name
        end
    end
    ctx.new_job_service_name = name
    ctx.new_job_step = "form"
end

-- Job 100% autônomo: sem serviço gatilho, só as env vars do projeto.
function new_job_pick_no_service(): ()
    ctx.new_job_service_id = ""
    ctx.new_job_service_name = "nenhum (autônomo)"
    ctx.new_job_step = "form"
end

function new_job_back(): ()
    -- Modo edição: não há passos 1/2 pra voltar (projeto/serviço gatilho não
    -- são editáveis via JobUpdate) — "Voltar" fecha a janela.
    if ctx.new_job_edit_id ~= "" then
        close_window()
        return
    end
    if ctx.new_job_step == "form" then
        ctx.new_job_step = "pick_service"
    elseif ctx.new_job_step == "pick_service" then
        ctx.new_job_step = "pick_project"
    end
end

function new_job_kind(kind_choice: string): ()
    ctx.new_job_kind = kind_choice
end

-- Órfão desde que o seletor de dia da semana virou um <radiogroup> — mesma
-- história do `docker_cleanup_weekday` em handlers/settings.luau.
-- function new_job_weekday(w: string): ()
--     ctx.new_job_weekday = w
-- end

function new_job_create(): ()
    local api = client()
    if not api then
        ctx.new_job_error = "sem conexão — reabra a janela pelo app"
        return
    end
    local name = Helpers.trim(ctx.new_job_name)
    if name == "" then
        ctx.new_job_error = "informe um nome"
        return
    end
    local main_service = Helpers.trim(ctx.new_job_main_service)
    if main_service == "" then
        ctx.new_job_error = "informe o main_service (nome do serviço dentro do compose)"
        return
    end

    local compose = ""
    local git_source: any = nil
    if ctx.new_job_source == "git" then
        local branch = Helpers.trim(ctx.new_job_git_branch)
        if ctx.new_job_git_repo == "" or branch == "" then
            ctx.new_job_error = "selecione repositório e branch"
            return
        end
        local compose_path = Helpers.trim(ctx.new_job_compose_path)
        if compose_path == "" then
            compose_path = "docker-compose.yml"
        end
        -- URL de clone vem da lista de repos já carregada (mesma resolução
        -- de gitea_repo_pick em handlers/services.luau).
        local url = ""
        local json_decode_ok, repos = pcall(json.decode, ctx.new_job_git_repos or "[]")
        if json_decode_ok and type(repos) == "table" then
            for _, repo in ipairs(repos) do
                if repo.full_name == ctx.new_job_git_repo then
                    url = repo.clone_url or ""
                    break
                end
            end
        end
        if url == "" then
            ctx.new_job_error = "não foi possível resolver a URL do repositório — selecione de novo"
            return
        end
        git_source = {
            provider_id = ctx.new_job_git_provider_id ~= "" and ctx.new_job_git_provider_id or nil,
            url = url,
            branch = branch,
            username = nil,
            credentials = nil,
            compose_path = compose_path,
        }
    else
        compose = ctx.new_job_compose or ""
        if Helpers.trim(compose) == "" then
            ctx.new_job_error = "cole o docker-compose.yml do job"
            return
        end
    end
    ctx.new_job_error = ""

    -- O caminho de volta do <timeedit>: a chave única "HH:MM" vira os dois
    -- campos que Recurrence::Daily/Weekly declaram no daemon.
    local hour, minute = format.hour_minute_split(ctx.new_job_time)
    local recurrence: any = nil
    if ctx.new_job_kind == "interval" then
        recurrence = { IntervalHours = math.max(1, tonumber(ctx.new_job_hours) or 1) }
    elseif ctx.new_job_kind == "daily" then
        recurrence = {
            Daily = {
                hour = hour,
                minute = minute,
            },
        }
    elseif ctx.new_job_kind == "weekly" then
        recurrence = {
            Weekly = {
                weekday = tonumber(ctx.new_job_weekday) or 0,
                hour = hour,
                minute = minute,
            },
        }
    end

    local env_vars, env_comments = Helpers.parse_dotenv(ctx.new_job_env_text)
    local editing = ctx.new_job_edit_id ~= ""

    ctx.new_job_message = editing and "salvando…" or "criando…"
    ctx.new_job_busy = "true"
    local save_ok, save_response
    if editing then
        save_ok, save_response = api:rpc_checked{
            JobUpdate = {
                id = ctx.new_job_edit_id,
                name = name,
                compose = compose,
                git_source = git_source,
                main_service = main_service,
                env_vars = env_vars,
                env_comments = env_comments,
                enabled = ctx.new_job_enabled == "true",
                recurrence = recurrence,
            },
        }
    else
        save_ok, save_response = api:rpc_checked{
            JobCreate = {
                project_id = ctx.new_job_project_id,
                trigger_service_id = ctx.new_job_service_id,
                name = name,
                compose = compose,
                git_source = git_source,
                main_service = main_service,
                env_vars = env_vars,
                env_comments = env_comments,
                recurrence = recurrence,
            },
        }
    end
    ctx.new_job_busy = ""
    if not save_ok then
        ctx.new_job_message = ""
        ctx.new_job_error = "erro: " .. tostring(save_response)
        return
    end

    local job = (type(save_response) == "table" and save_response.Job) or {}
    broadcast(editing and "job_updated" or "job_created", { id = job.id, name = job.name or name })
    close_window()
end

function cancel(): ()
    close_window()
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
