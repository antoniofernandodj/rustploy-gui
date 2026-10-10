--!strict
--!nolint FunctionUnused
-- handlers/settings.luau — Settings (Web Server) e Settings → Git (provedores
-- Gitea: conectar via OAuth/PAT, atualizar lista, remover).

local State = require("../state")
local Helpers = require("../helpers")
local fmt = require("../fmt")
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
    local ok, res = api:rpc_checked{ SetDaemonSettings = {
        acme_email = (email ~= "" and email or nil),
        registry_domain = (registry_domain ~= "" and registry_domain or nil),
    } }
    ctx.settings_message = ok and "configurações salvas" or ("erro: " .. res)
    if ok then
        toast{ message = tostring("Configurações salvas"), kind = "success" }
    else
        toast{ message = tostring(res), kind = "error" }
    end
end

-- ── Settings → Git (provedores Gitea / GitHub) ───────────────────────────

-- Órfão desde que a aba virou <tabbar>: a barra grava `git_provider_mode` sozinha.
-- function git_provider_mode(m: string): ()
--     ctx.git_provider_mode = m
-- end

-- Alterna o tipo de provedor (gitea | github) e recomputa a redirect URI, que
-- tem path por provedor (/oauth/gitea/callback vs /oauth/github/callback).
function git_provider_kind(k: string): ()
    local kind = (k == "github") and "github" or "gitea"
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
    local ok, res = api:rpc("GitProviderList")
    if ok and res.GitProviders then
        ctx.gitea_providers = fmt.git_providers(res.GitProviders)
        ctx.gitea_count = tostring(#res.GitProviders)
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
    local cmd: any
    if is_oauth then
        local cid = Helpers.trim(ctx.git_provider_client_id)
        local csec = ctx.git_provider_client_secret or ""
        if cid == "" or Helpers.trim(csec) == "" then
            ctx.git_provider_message = "Client ID e Client Secret são obrigatórios";
            return
        end
        cmd = {
            GitProviderCreate = {
                kind = kind_wire,
                name = name,
                base_url = base,
                auth_mode = "OAuth",
                oauth_client_id = cid,
                oauth_client_secret = csec,
                pat = nil
            }
        }
    else
        local pat = ctx.git_provider_personal_access_token or ""
        if Helpers.trim(pat) == "" then
            ctx.git_provider_message = "informe o Personal Access Token";
            return
        end
        cmd = {
            GitProviderCreate = {
                kind = kind_wire,
                name = name,
                base_url = base,
                auth_mode = "Pat",
                oauth_client_id = nil,
                oauth_client_secret = nil,
                pat = pat
            }
        }
    end
    ctx.git_provider_message = "conectando…"
    local ok, res = api:rpc(cmd)
    if not ok or not res.GitProviderInfo then
        ctx.git_provider_message = "erro: " .. (ok and "resposta inesperada" or res);
        return
    end
    local pid = res.GitProviderInfo.id
    if is_oauth then
        -- OAuth precisa de round-trip no navegador. O Luau não abre o browser;
        -- surface a URL para o usuário abrir (built-in open:<chave> no template)
        -- e depois clicar em "Atualizar lista".
        local oko, reso = api:rpc{ GitOAuthStart = { provider_id = pid } }
        if oko and reso.OAuthUrl then
            ctx.git_provider_oauth_url = reso.OAuthUrl
            ctx.git_provider_message = "abra para autorizar: " .. reso.OAuthUrl
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

function git_provider_delete(id: string): ()
    local api = State.api
    if not api then
        return
    end
    local ok, res = api:rpc_checked{ GitProviderDelete = { id = id } }
    ctx.git_provider_message = ok and "provider removido" or ("erro: " .. res)
    if not ok then
        toast{ message = tostring(res), kind = "error" }
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
    local ok, res = api:rpc_checked("ManifestExportAll")
    if not ok or type(res) ~= "table" or not res.ManifestBundle then
        ctx.manifest_export_message = "erro: " .. tostring(res)
        toast{ message = tostring(tostring(res)), kind = "error" }
        return
    end

    local okz, zerr = manifest_zip_write(
        zip_path,
        res.ManifestBundle.yaml or "",
        res.ManifestBundle.dotenv or ""
    )
    if not okz then
        ctx.manifest_export_message = "erro ao gravar o zip: " .. tostring(zerr)
        toast{ message = "Falha ao gravar o zip: " .. tostring(zerr), kind = "error" }
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
    local ok, res = api:rpc{
        ManifestImport = {
            yaml = yaml,
            dotenv = toml,
            prune = prune,
            deploy = deploy,
        },
    }
    if not ok then
        ctx.manifest_import_message = "erro: " .. tostring(res)
        toast{ message = tostring(tostring(res)), kind = "error" }
        return
    end

    if type(res) == "table" and res.MissingEnvVars ~= nil then
        ctx.manifest_has_missing = "true"
        ctx.manifest_missing_vars = table.concat(res.MissingEnvVars, ", ")
        ctx.manifest_import_message = "faltam variáveis — nada foi aplicado"
        toast{ message = tostring("Faltam variáveis no TOML: " .. ctx.manifest_missing_vars), kind = "error" }
        return
    end

    if type(res) == "table" and res.Err ~= nil then
        ctx.manifest_import_message = "erro: " .. tostring(res.Err.code) .. ": " .. tostring(res.Err.message)
        toast{ message = tostring(tostring(res.Err.message)), kind = "error" }
        return
    end

    if type(res) ~= "table" or not res.ManifestReport then
        ctx.manifest_import_message = "resposta inesperada do daemon"
        return
    end

    local lines = {}
    for _, a in ipairs(res.ManifestReport.actions or {}) do
        table.insert(lines, "[" .. tostring(a.action) .. "] " .. tostring(a.kind) .. " " .. tostring(a.name))
    end
    local pruned = res.ManifestReport.pruned or res.ManifestReport.removed or {}
    if #pruned > 0 then
        table.insert(lines, "removidos (prune): " .. table.concat(pruned, ", "))
    elseif prune then
        table.insert(lines, "prune ligado — nenhum serviço ausente para remover")
    end
    if #(res.ManifestReport.deployed or {}) > 0 then
        table.insert(lines, "deploy disparado: " .. table.concat(res.ManifestReport.deployed, ", "))
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

    local m = manifest_zip_read(zip_path)
    if not m.ok then
        ctx.manifest_import_message = "zip inválido: " .. tostring(m.error)
        toast{ message = tostring(m.error), kind = "error" }
        return
    end

    -- Lê os dois checkboxes AQUI e confirma o que vai acontecer — prune remove
    -- serviços, então o usuário vê exatamente o que marcou antes de aplicar.
    local prune = ctx.manifest_prune == "true"
    local deploy = ctx.manifest_deploy == "true"
    local ok_go = confirm{
        title = "Aplicar este manifesto?",
        message = "Do zip: "
            .. tostring(m.yaml and #m.yaml or 0) .. " B de YAML + "
            .. tostring(m.toml and #m.toml or 0) .. " B de TOML.\n\n"
            .. "• Remover serviços ausentes (prune): "
            .. (prune and "SIM" or "não") .. "\n"
            .. "• Disparar deploy dos alterados: "
            .. (deploy and "SIM" or "não"),
        confirm_label = "Aplicar",
        destructive = prune,
    }
    if not ok_go then
        ctx.manifest_import_message = "cancelado"
        return
    end

    ctx.manifest_busy = "true"
    do_import(api, m.yaml or "", m.toml or "", prune, deploy)
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
local function docker_cleanup_unpack_recurrence(r: any): (string, string, string, string, string)
    if r ~= nil and r.IntervalHours ~= nil then
        return "interval", tostring(r.IntervalHours), "3", "0", "0"
    end
    if r ~= nil and r.Weekly ~= nil then
        return "weekly", "6", tostring(r.Weekly.hour), tostring(r.Weekly.minute), tostring(r.Weekly.weekday)
    end
    if r ~= nil and r.Daily ~= nil then
        return "daily", "6", tostring(r.Daily.hour), tostring(r.Daily.minute), "0"
    end
    return "daily", "6", "3", "0", "0"
end

local function docker_cleanup_apply_config(cfg: any): ()
    ctx.docker_cleanup_enabled = tostring(cfg.enabled)
    ctx.docker_cleanup_containers = tostring(cfg.containers)
    ctx.docker_cleanup_images = tostring(cfg.images)
    ctx.docker_cleanup_images_all = tostring(cfg.images_all)
    ctx.docker_cleanup_volumes = tostring(cfg.volumes)
    ctx.docker_cleanup_volumes_all = tostring(cfg.volumes_all)
    ctx.docker_cleanup_networks = tostring(cfg.networks)
    ctx.docker_cleanup_build_cache = tostring(cfg.build_cache)
    local kind, hours, hour, minute, weekday = docker_cleanup_unpack_recurrence(cfg.recurrence)
    ctx.docker_cleanup_kind = kind
    ctx.docker_cleanup_hours = hours
    -- Uma chave só, "HH:MM", porque quem edita agora é o <timeedit> em home.gvb.
    -- `docker_cleanup_unpack_recurrence` continua devolvendo hora e minuto separados (é o
    -- formato do daemon); a junção acontece aqui, na fronteira.
    ctx.docker_cleanup_time = fmt.hm_join(hour, minute)
    ctx.docker_cleanup_weekday = weekday
    ctx.docker_cleanup_next_run_label = cfg.next_run_at and fmt.date_dm_hm(cfg.next_run_at) or "—"
    State.docker_cleanup_last_run_at_raw = cfg.last_run_at
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
    local ok, res = api:rpc("DockerCleanupConfigGet")
    if ok and res.DockerCleanupConfig then
        docker_cleanup_apply_config(res.DockerCleanupConfig.config)
        ctx.docker_cleanup_last_run_text = fmt.docker_cleanup_last_run_summary(
            res.DockerCleanupConfig.last_run
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
    local hora, minuto = fmt.hm_split(ctx.docker_cleanup_time)
    if ctx.docker_cleanup_kind == "weekly" then
        return {
            Weekly = {
                weekday = tonumber(ctx.docker_cleanup_weekday) or 0,
                hour = hora,
                minute = minuto,
            },
        }
    end
    return {
        Daily = {
            hour = hora,
            minute = minuto,
        },
    }
end

function docker_cleanup_save(): ()
    local api = State.api
    if not api then
        return
    end
    ctx.docker_cleanup_message = "salvando…"
    local ok, res = api:rpc_checked{
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
    if ok and res.DockerCleanupConfig then
        docker_cleanup_apply_config(res.DockerCleanupConfig.config)
        ctx.docker_cleanup_last_run_text = fmt.docker_cleanup_last_run_summary(
            res.DockerCleanupConfig.last_run
        )
        ctx.docker_cleanup_message = "configurações salvas"
        toast{ message = tostring("Limpeza automática salva"), kind = "success" }
    else
        ctx.docker_cleanup_message = "erro: " .. tostring(res)
        toast{ message = tostring(res), kind = "error" }
    end
end

-- Botão "Executar agora": roda os recursos marcados fora do horário
-- agendado, independente do interruptor geral (é um botão de teste). Roda em
-- background no daemon — `ctx.docker_cleanup_running` volta a "false" quando
-- `Event::DockerCleanupCompleted` chega (stream.luau::apply_bus), não pela
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
    local ok_confirm = confirm{
        title = "Executar limpeza agora?",
        message = "Roda a limpeza dos recursos marcados imediatamente, fora do horário agendado. Ação irreversível.",
        confirm_label = "Executar",
        destructive = true,
    }
    if not ok_confirm then
        return
    end
    ctx.docker_cleanup_running = "true"
    ctx.docker_cleanup_message = "executando…"
    local ok, res = api:rpc_checked("DockerCleanupRunNow")
    if not ok then
        ctx.docker_cleanup_running = "false"
        ctx.docker_cleanup_message = "erro: " .. tostring(res)
        toast{ message = tostring(res), kind = "error" }
    end
end

return M
