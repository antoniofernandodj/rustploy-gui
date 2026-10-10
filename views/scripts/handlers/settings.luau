--!strict
--!nolint FunctionUnused
-- handlers/settings.luau — Settings (Web Server) e Settings → Git (provedores
-- Gitea: conectar via OAuth/PAT, atualizar lista, remover).

local State = require("../state")
local Helpers = require("../helpers")
local format = require("../format")
local Stream = require("stream")

local M = {}

-- ── Settings (Web Server) ────────────────────────────────────────────────

-- Órfão desde que a aba virou <tabbar>: a barra grava `settings_tab` sozinha.
-- function settings_tab(t: string): ()
--     ctx.settings_tab = t
-- end

function settings_save(): ()
    local api = State.api
    if not api then
        return
    end
    local email = Helpers.trim(ctx.server_settings_email)
    local registry_domain = Helpers.trim(ctx.server_settings_registry_domain)
    ctx.settings_message = "salvando…"
    local set_daemon_settings_ok, set_daemon_settings_response = api:rpc_checked{ SetDaemonSettings = {
        acme_email = (email ~= "" and email or nil),
        registry_domain = (registry_domain ~= "" and registry_domain or nil),
    } }
    ctx.settings_message = set_daemon_settings_ok and "configurações salvas" or ("erro: " .. set_daemon_settings_response)
    if set_daemon_settings_ok then
        toast{ message = tostring("Configurações salvas"), kind = "success" }
    else
        toast{ message = tostring(set_daemon_settings_response), kind = "error" }
    end
end

-- ── Settings → Git (provedores Gitea / GitHub) ───────────────────────────

-- Órfão desde que a aba virou <tabbar>: a barra grava `git_provider_mode` sozinha.
-- function git_provider_mode(m: string): ()
--     ctx.git_provider_mode = m
-- end

-- Alterna o tipo de provedor (gitea | github) e recomputa a redirect URI, que
-- tem path por provedor (/oauth/gitea/callback vs /oauth/github/callback).
function git_provider_kind(selected_kind: string): ()
    local kind = (selected_kind == "github") and "github" or "gitea"
    ctx.git_provider_kind = kind
    ctx.git_provider_redirect = Helpers.oauth_redirect_uri(ctx.server_settings_public_base, kind)
    -- GitHub conecta ao github.com por padrão; Base URL só p/ Enterprise.
    if kind == "github" and Helpers.trim(ctx.git_provider_base_url) == "" then
        ctx.git_provider_name = (
            Helpers.trim(ctx.git_provider_name) == "" and "GitHub" or ctx.git_provider_name
        )
    end
end

local function git_provider_refresh_list(): ()
    local api = State.api
    if not api then
        return
    end
    local git_provider_list_ok, git_provider_list_response = api:rpc("GitProviderList")
    if git_provider_list_ok and git_provider_list_response.GitProviders then
        ctx.gitea_providers = format.git_providers(git_provider_list_response.GitProviders)
        ctx.gitea_count = tostring(#git_provider_list_response.GitProviders)
    end
end

function git_provider_refresh(): ()
    if not State.api then
        return
    end
    git_provider_refresh_list()
end

function git_provider_connect(): ()
    local api = State.api
    if not api then
        return
    end
    ctx.git_provider_oauth_url = ""
    local is_github = (ctx.git_provider_kind or "gitea") == "github"
    local kind_wire = is_github and "Github" or "Gitea"
    local label = is_github and "GitHub" or "Gitea"
    local base = Helpers.trim(ctx.git_provider_base_url)
    -- GitHub conecta ao github.com por padrão; a Base URL só é preenchida para
    -- GitHub Enterprise Server. Gitea sempre exige a Base URL.
    if base == "" then
        if is_github then
            base = "https://github.com"
        else
            ctx.git_provider_message = "informe a Base URL do Gitea";
            return
        end
    end
    local name = Helpers.trim(ctx.git_provider_name); if name == "" then
        name = label
    end
    local is_oauth = (ctx.git_provider_mode or "oauth") ~= "pat"
    local provider_command: any
    if is_oauth then
        local client_id = Helpers.trim(ctx.git_provider_client_id)
        local client_secret = ctx.git_provider_client_secret or ""
        if client_id == "" or Helpers.trim(client_secret) == "" then
            ctx.git_provider_message = "Client ID e Client Secret são obrigatórios";
            return
        end
        provider_command = {
            GitProviderCreate = {
                kind = kind_wire,
                name = name,
                base_url = base,
                auth_mode = "OAuth",
                oauth_client_id = client_id,
                oauth_client_secret = client_secret,
                pat = nil
            }
        }
    else
        local personal_access_token = ctx.git_provider_personal_access_token or ""
        if Helpers.trim(personal_access_token) == "" then
            ctx.git_provider_message = "informe o Personal Access Token";
            return
        end
        provider_command = {
            GitProviderCreate = {
                kind = kind_wire,
                name = name,
                base_url = base,
                auth_mode = "Pat",
                oauth_client_id = nil,
                oauth_client_secret = nil,
                pat = personal_access_token
            }
        }
    end
    ctx.git_provider_message = "conectando…"
    local rpc_ok, rpc_response = api:rpc(provider_command)
    if not rpc_ok or not rpc_response.GitProviderInfo then
        ctx.git_provider_message = "erro: " .. (rpc_ok and "resposta inesperada" or rpc_response);
        return
    end
    local provider_id = rpc_response.GitProviderInfo.id
    if is_oauth then
        -- OAuth precisa de round-trip no navegador. O Luau não abre o browser;
        -- surface a URL para o usuário abrir (built-in open:<chave> no template)
        -- e depois clicar em "Atualizar lista".
        local git_o_auth_start_ok, git_o_auth_start_response = api:rpc{ GitOAuthStart = { provider_id = provider_id } }
        if git_o_auth_start_ok and git_o_auth_start_response.OAuthUrl then
            ctx.git_provider_oauth_url = git_o_auth_start_response.OAuthUrl
            ctx.git_provider_message = "abra para autorizar: " .. git_o_auth_start_response.OAuthUrl
        else
            ctx.git_provider_message = "provider criado; inicie o OAuth manualmente"
        end
    else
        ctx.git_provider_message = "conta " .. label .. " conectada ✓"
    end
    ctx.git_provider_name = ""
    ctx.git_provider_base_url = ""
    ctx.git_provider_client_id = ""
    ctx.git_provider_client_secret = ""
    ctx.git_provider_personal_access_token = ""
    git_provider_refresh_list()
end

function git_provider_delete(provider_id: string): ()
    local api = State.api
    if not api then
        return
    end
    local git_provider_delete_ok, git_provider_delete_response = api:rpc_checked{ GitProviderDelete = { id = provider_id } }
    ctx.git_provider_message = git_provider_delete_ok and "provider removido" or ("erro: " .. git_provider_delete_response)
    if not git_provider_delete_ok then
        toast{ message = tostring(git_provider_delete_response), kind = "error" }
    end
    git_provider_refresh_list()
end

-- ── Settings → Infra as Code (export/import declarativo) ─────────────────
--
-- O manifesto é um `.zip` (um ARQUIVO) com exatamente dois membros na raiz:
--   • rustploy.yml       — projetos/serviços (env vars sempre como ${VAR})
--   • rustploy.vars.toml  — os valores reais das vars (aninhado por escopo)
-- Ler/gravar o zip é `manifest_zip_read`/`manifest_zip_write` — extensão Rust
-- da camada Luau (src/manifest_zip.rs), porque o motor tem `zip_dir` mas não
-- o inverso. Exportar e importar usam os diálogos nativos do SO; o import
-- REJEITA um zip que não tenha exatamente um .yml e um .toml, sem mais nada.

-- O corpo do export DEPOIS do diálogo — separado só para o `manifest_busy` ser
-- ligado/desligado em volta sem repetir o reset em cada early-return.
local function do_export(api: any, zip_path: string): ()
    ctx.manifest_export_message = "exportando…"
    local manifest_export_all_ok, manifest_export_all_response = api:rpc_checked("ManifestExportAll")
    if not manifest_export_all_ok or type(manifest_export_all_response) ~= "table" or not manifest_export_all_response.ManifestBundle then
        ctx.manifest_export_message = "erro: " .. tostring(manifest_export_all_response)
        toast{ message = tostring(tostring(manifest_export_all_response)), kind = "error" }
        return
    end

    local zip_write_ok, zip_write_error = manifest_zip_write(
        zip_path,
        manifest_export_all_response.ManifestBundle.yaml or "",
        manifest_export_all_response.ManifestBundle.dotenv or ""
    )
    if not zip_write_ok then
        ctx.manifest_export_message = "erro ao gravar o zip: " .. tostring(zip_write_error)
        toast{ message = "Falha ao gravar o zip: " .. tostring(zip_write_error), kind = "error" }
        return
    end
    ctx.manifest_export_message = "salvo em " .. zip_path
    toast{ message = "Infra as Code exportado", kind = "success" }
end

function manifest_export(): ()
    local api = State.api
    if not api then
        return
    end

    -- `save_file` (SUSPENDE): o usuário escolhe o caminho do .zip.
    local zip_path = save_file{
        title = "Exportar Infra as Code",
        default_name = "rustploy-infra.zip",
        filters = { { name = "Zip", extensions = { "zip" } } },
    }
    if not zip_path then
        return
    end
    if not string.match(zip_path, "%.zip$") then
        zip_path = zip_path .. ".zip"
    end

    ctx.manifest_busy = "true"
    do_export(api, zip_path)
    ctx.manifest_busy = ""
end

local function do_import(api: any, yaml: string, toml: string, prune: boolean, deploy: boolean): ()
    ctx.manifest_has_missing = "false"
    ctx.manifest_has_report = "false"
    ctx.manifest_missing_vars = ""
    ctx.manifest_report_lines = {}

    ctx.manifest_import_message = "importando…"
    local manifest_import_ok, manifest_import_response = api:rpc{
        ManifestImport = {
            yaml = yaml,
            dotenv = toml,
            prune = prune,
            deploy = deploy,
        },
    }
    if not manifest_import_ok then
        ctx.manifest_import_message = "erro: " .. tostring(manifest_import_response)
        toast{ message = tostring(tostring(manifest_import_response)), kind = "error" }
        return
    end

    if type(manifest_import_response) == "table" and manifest_import_response.MissingEnvVars ~= nil then
        ctx.manifest_has_missing = "true"
        ctx.manifest_missing_vars = table.concat(manifest_import_response.MissingEnvVars, ", ")
        ctx.manifest_import_message = "faltam variáveis — nada foi aplicado"
        toast{ message = tostring("Faltam variáveis no TOML: " .. ctx.manifest_missing_vars), kind = "error" }
        return
    end

    if type(manifest_import_response) == "table" and manifest_import_response.Err ~= nil then
        ctx.manifest_import_message = "erro: " .. tostring(manifest_import_response.Err.code) .. ": " .. tostring(manifest_import_response.Err.message)
        toast{ message = tostring(tostring(manifest_import_response.Err.message)), kind = "error" }
        return
    end

    if type(manifest_import_response) ~= "table" or not manifest_import_response.ManifestReport then
        ctx.manifest_import_message = "resposta inesperada do daemon"
        return
    end

    local lines = {}
    for _, action in ipairs(manifest_import_response.ManifestReport.actions or {}) do
        table.insert(lines, "[" .. tostring(action.action) .. "] " .. tostring(action.kind) .. " " .. tostring(action.name))
    end
    local pruned = manifest_import_response.ManifestReport.pruned or manifest_import_response.ManifestReport.removed or {}
    if #pruned > 0 then
        table.insert(lines, "removidos (prune): " .. table.concat(pruned, ", "))
    elseif prune then
        table.insert(lines, "prune ligado — nenhum serviço ausente para remover")
    end
    if #(manifest_import_response.ManifestReport.deployed or {}) > 0 then
        table.insert(lines, "deploy disparado: " .. table.concat(manifest_import_response.ManifestReport.deployed, ", "))
    elseif deploy then
        table.insert(lines, "deploy ligado — nada mudou para disparar")
    end
    ctx.manifest_report_lines = lines
    ctx.manifest_has_report = "true"
    ctx.manifest_import_message = "import concluído ✓"
    toast{ message = tostring("Infra as Code importado"), kind = "success" }
    Stream.refresh_now()
end

function manifest_import(): ()
    local api = State.api
    if not api then
        return
    end

    -- `open_file` (SUSPENDE): o `.zip` do manifesto. `manifest_zip_read` extrai
    -- e VALIDA — exatamente um .yml e um .toml na raiz, nada mais.
    local zip_path = open_file{
        title = "Importar Infra as Code (.zip)",
        filters = { { name = "Zip", extensions = { "zip" } } },
    }
    if not zip_path then
        return
    end

    local zip_manifest = manifest_zip_read(zip_path)
    if not zip_manifest.ok then
        ctx.manifest_import_message = "zip inválido: " .. tostring(zip_manifest.error)
        toast{ message = tostring(zip_manifest.error), kind = "error" }
        return
    end

    -- Lê os dois checkboxes AQUI e confirma o que vai acontecer — prune remove
    -- serviços, então o usuário vê exatamente o que marcou antes de aplicar.
    local prune = ctx.manifest_prune == "true"
    local deploy = ctx.manifest_deploy == "true"
    local confirmed = confirm{
        title = "Aplicar este manifesto?",
        message = "Do zip: "
            .. tostring(zip_manifest.yaml and #zip_manifest.yaml or 0) .. " B de YAML + "
            .. tostring(zip_manifest.toml and #zip_manifest.toml or 0) .. " B de TOML.\n\n"
            .. "• Remover serviços ausentes (prune): "
            .. (prune and "SIM" or "não") .. "\n"
            .. "• Disparar deploy dos alterados: "
            .. (deploy and "SIM" or "não"),
        confirm_label = "Aplicar",
        destructive = prune,
    }
    if not confirmed then
        ctx.manifest_import_message = "cancelado"
        return
    end

    ctx.manifest_busy = "true"
    do_import(api, zip_manifest.yaml or "", zip_manifest.toml or "", prune, deploy)
    ctx.manifest_busy = ""
end

-- ── Settings → Manutenção (limpeza automática de Docker) ─────────────────
-- Ver docs/plano-limpeza-automatica-docker.md. Config é um singleton do
-- daemon (não uma lista) — sem tabela própria, carregada/salva inteira a
-- cada Get/Set. `docker_cleanup_last_run_at_raw`/`dc_next_run_at_raw` são campos "mudos"
-- (não exibidos, só round-trip): preservam o `last_run_at` real entre saves
-- pra um agendamento `IntervalHours` não reiniciar a contagem toda vez que o
-- usuário aperta "Save" sem ter mudado nada de agendamento.

-- Recorrência (Option<Recurrence>, externally-tagged) → (kind, hours, hour,
-- minute, weekday) — mesmo formato de new_job_window.luau::unpack_recurrence,
-- mas aqui a recorrência nunca é `nil` (a config sempre tem uma, mesmo com o
-- interruptor geral desligado).
local function docker_cleanup_unpack_recurrence(recurrence: any): (string, string, string, string, string)
    if recurrence ~= nil and recurrence.IntervalHours ~= nil then
        return "interval", tostring(recurrence.IntervalHours), "3", "0", "0"
    end
    if recurrence ~= nil and recurrence.Weekly ~= nil then
        return "weekly", "6", tostring(recurrence.Weekly.hour), tostring(recurrence.Weekly.minute), tostring(recurrence.Weekly.weekday)
    end
    if recurrence ~= nil and recurrence.Daily ~= nil then
        return "daily", "6", tostring(recurrence.Daily.hour), tostring(recurrence.Daily.minute), "0"
    end
    return "daily", "6", "3", "0", "0"
end

local function docker_cleanup_apply_config(config: any): ()
    ctx.docker_cleanup_enabled = tostring(config.enabled)
    ctx.docker_cleanup_containers = tostring(config.containers)
    ctx.docker_cleanup_images = tostring(config.images)
    ctx.docker_cleanup_images_all = tostring(config.images_all)
    ctx.docker_cleanup_volumes = tostring(config.volumes)
    ctx.docker_cleanup_volumes_all = tostring(config.volumes_all)
    ctx.docker_cleanup_networks = tostring(config.networks)
    ctx.docker_cleanup_build_cache = tostring(config.build_cache)
    local kind, hours, hour, minute, weekday = docker_cleanup_unpack_recurrence(config.recurrence)
    ctx.docker_cleanup_kind = kind
    ctx.docker_cleanup_hours = hours
    -- Uma chave só, "HH:MM", porque quem edita agora é o <timeedit> em home.gvb.
    -- `docker_cleanup_unpack_recurrence` continua devolvendo hora e minuto separados (é o
    -- formato do daemon); a junção acontece aqui, na fronteira.
    ctx.docker_cleanup_time = format.hour_minute_join(hour, minute)
    ctx.docker_cleanup_weekday = weekday
    ctx.docker_cleanup_next_run_label = config.next_run_at and format.date_day_month_hour_minute(config.next_run_at) or "—"
    State.docker_cleanup_last_run_at_raw = config.last_run_at
end

-- Carregado uma vez na conexão (handlers/connection.luau::load_settings) —
-- não faz parte do snapshot de 2s, é config, não estado que muda sozinho
-- (exceto por `last_run`, atualizado ao vivo por `Event::DockerCleanupCompleted`
-- em stream.luau, sem precisar buscar de novo).
function M.docker_cleanup_load(): ()
    local api = State.api
    if not api then
        return
    end
    local docker_cleanup_config_get_ok, docker_cleanup_config_get_response = api:rpc("DockerCleanupConfigGet")
    if docker_cleanup_config_get_ok and docker_cleanup_config_get_response.DockerCleanupConfig then
        docker_cleanup_apply_config(docker_cleanup_config_get_response.DockerCleanupConfig.config)
        ctx.docker_cleanup_last_run_text = format.docker_cleanup_last_run_summary(
            docker_cleanup_config_get_response.DockerCleanupConfig.last_run
        )
    end
end

-- Órfão desde que a aba virou <tabbar>: a barra grava `docker_cleanup_kind` sozinha.
-- function docker_cleanup_kind(k: string): ()
--     ctx.docker_cleanup_kind = k
-- end

-- Órfão desde que o seletor de dia da semana virou um <radiogroup> em home.gvb:
-- o builtin grava `docker_cleanup_weekday` sozinho, no update dele em Rust, e ninguém mais
-- dispara esta ação. Fica comentado porque volta a ser necessário se algum dia
-- o grupo voltar a ser markup à mão (ex.: para recuperar a fileira de pílulas).
-- function docker_cleanup_weekday(w: string): ()
--     ctx.docker_cleanup_weekday = w
-- end

local function docker_cleanup_build_recurrence(): any
    if ctx.docker_cleanup_kind == "interval" then
        return {
            IntervalHours = math.max(1, tonumber(ctx.docker_cleanup_hours) or 1)
        }
    end
    -- O caminho de volta do <timeedit>: a chave única vira os dois campos que
    -- Recurrence::Daily/Weekly declaram no daemon.
    local hour, minute = format.hour_minute_split(ctx.docker_cleanup_time)
    if ctx.docker_cleanup_kind == "weekly" then
        return {
            Weekly = {
                weekday = tonumber(ctx.docker_cleanup_weekday) or 0,
                hour = hour,
                minute = minute,
            },
        }
    end
    return {
        Daily = {
            hour = hour,
            minute = minute,
        },
    }
end

function docker_cleanup_save(): ()
    local api = State.api
    if not api then
        return
    end
    ctx.docker_cleanup_message = "salvando…"
    local docker_cleanup_config_set_ok, docker_cleanup_config_set_response = api:rpc_checked{
        DockerCleanupConfigSet = {
            config = {
                enabled = ctx.docker_cleanup_enabled == "true",
                recurrence = docker_cleanup_build_recurrence(),
                containers = ctx.docker_cleanup_containers == "true",
                images = ctx.docker_cleanup_images == "true",
                images_all = ctx.docker_cleanup_images_all == "true",
                volumes = ctx.docker_cleanup_volumes == "true",
                volumes_all = ctx.docker_cleanup_volumes_all == "true",
                networks = ctx.docker_cleanup_networks == "true",
                build_cache = ctx.docker_cleanup_build_cache == "true",
                last_run_at = State.docker_cleanup_last_run_at_raw,
            },
        },
    }
    if docker_cleanup_config_set_ok and docker_cleanup_config_set_response.DockerCleanupConfig then
        docker_cleanup_apply_config(docker_cleanup_config_set_response.DockerCleanupConfig.config)
        ctx.docker_cleanup_last_run_text = format.docker_cleanup_last_run_summary(
            docker_cleanup_config_set_response.DockerCleanupConfig.last_run
        )
        ctx.docker_cleanup_message = "configurações salvas"
        toast{ message = tostring("Limpeza automática salva"), kind = "success" }
    else
        ctx.docker_cleanup_message = "erro: " .. tostring(docker_cleanup_config_set_response)
        toast{ message = tostring(docker_cleanup_config_set_response), kind = "error" }
    end
end

-- Botão "Executar agora": roda os recursos marcados fora do horário
-- agendado, independente do interruptor geral (é um botão de teste). Roda em
-- background no daemon — `ctx.docker_cleanup_running` volta a "false" quando
-- `Event::DockerCleanupCompleted` chega (stream.luau::apply_bus_event), não pela
-- resposta deste RPC.
function docker_cleanup_run_now(): ()
    local api = State.api
    if not api then
        return
    end
    local any_selected = ctx.docker_cleanup_containers == "true" or ctx.docker_cleanup_images == "true"
        or ctx.docker_cleanup_volumes == "true" or ctx.docker_cleanup_networks == "true" or ctx.docker_cleanup_build_cache == "true"
    if not any_selected then
        ctx.docker_cleanup_message = "marque pelo menos um recurso"
        return
    end
    local confirmed = confirm{
        title = "Executar limpeza agora?",
        message = "Roda a limpeza dos recursos marcados imediatamente, fora do horário agendado. Ação irreversível.",
        confirm_label = "Executar",
        destructive = true,
    }
    if not confirmed then
        return
    end
    ctx.docker_cleanup_running = "true"
    ctx.docker_cleanup_message = "executando…"
    local docker_cleanup_run_now_ok, docker_cleanup_run_now_response = api:rpc_checked("DockerCleanupRunNow")
    if not docker_cleanup_run_now_ok then
        ctx.docker_cleanup_running = "false"
        ctx.docker_cleanup_message = "erro: " .. tostring(docker_cleanup_run_now_response)
        toast{ message = tostring(docker_cleanup_run_now_response), kind = "error" }
    end
end

return M
