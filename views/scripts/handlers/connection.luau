--!strict
--!nolint FunctionUnused
-- handlers/connection.luau — ciclo de vida da sessão: init (semeia o contexto),
-- login/logout, configurações do daemon buscadas uma vez na conexão.

local State = require("../state")
local Helpers = require("../helpers")
local Api = require("../net/api")
local format = require("../format")
local Stream = require("stream")
local Settings = require("settings")
local AccessKey = require("../access_key")

-- ── login lembrado: lista de servidor/token (via o `storage` do glacier) ────
-- O login é UM campo: a chave de acesso (endereço + token, ver
-- access_key.luau). Toda conexão bem-sucedida salva/atualiza o par sozinha
-- (ver `connect()`), e quem administra mais de um daemon tem a lista inteira
-- no `<ComboEdit>` (login.gvb): cada item mostra `host:porta · cnVzdH…` como
-- dica de a qual servidor a chave se refere, e escolher um preenche a chave
-- inteira. O armazenamento continua `{url, token}` (a chave é montada na hora
-- de mostrar), então servidores salvos antes do login por chave não se
-- perdem. `storage` grava em `~/.local/share/rustploy/.glacier-storage/app.json`
-- (raiz definida por `app(id = rustploy)` de `views/app.gvb`).
local saved_servers: { { url: string, token: string } } = {}

-- Publica `{label, value}` para o `<ComboEdit>`: o rótulo é a dica com o
-- endereço; o valor, a chave que vai para o campo.
local function publish_saved_servers(): ()
    local server_options = json.array{}
    for _, saved_server in ipairs(saved_servers) do
        local key = AccessKey.encode(saved_server.url, saved_server.token)
        table.insert(server_options, { label = AccessKey.hint(saved_server.url, key), value = key })
    end
    ctx.saved_servers = json.encode(server_options)
end

-- Salva/atualiza um par e o move pro topo da lista — o mais usado por último
-- fica em primeiro, e é também o que `init()` pré-preenche no próximo boot.
local function remember_server(url: string, token: string): ()
    for index = #saved_servers, 1, -1 do
        if saved_servers[index].url == url then
            table.remove(saved_servers, index)
        end
    end
    table.insert(saved_servers, 1, { url = url, token = token })
    storage.set("saved_servers", saved_servers)
    publish_saved_servers()
end

-- Handler do `<ComboEdit>` da chave: dispara a cada tecla (`onChange`) e ao
-- escolher um item salvo (`onSelect`). O motor já grava o texto em
-- `access_key`; aqui só some o erro da tentativa anterior.
function choose_server(_value: string): ()
    ctx.error_access_key = ""
end

-- Botão "Esquecer" ao lado do combo: remove da lista o servidor da chave
-- atual e limpa o campo — sem isso a tela continuava mostrando o par recém
-- esquecido até a próxima troca de servidor ou reabertura do app.
function forget_server(): ()
    local decoded_key = AccessKey.decode(ctx.access_key)
    local url = decoded_key and Helpers.normalize_url(decoded_key.url) or ""
    for index = #saved_servers, 1, -1 do
        if saved_servers[index].url == url then
            table.remove(saved_servers, index)
        end
    end
    storage.set("saved_servers", saved_servers)
    publish_saved_servers()
    ctx.access_key = ""
    ctx.error_access_key = ""
end

-- ── init: semeia o contexto para a UI pintar antes de qualquer dado ─────────
function init(): ()
    if not ctx.screen or ctx.screen == "" then
        ctx.screen = "login"
    end
    if not ctx.view or ctx.view == "" then
        ctx.view = "deployments"
    end
    ctx.connected = ctx.connected or "false"
    ctx.status_line = ctx.status_line or "pronto para conectar"
    ctx.error = ctx.error or ""
    ctx.search = ctx.search or ""
    -- Sidebar-gaveta (<drawer> em shell.gvb): começa aberta; o ☰ da topbar
    -- alterna via `drawer::toggle:menu`.
    ctx.menu = ctx.menu or "true"
    -- Checkboxes do Infra as Code (Settings → aba IaC): semeados aqui pra o
    -- estado ser determinístico e o `do_import` nunca ler `nil`.
    ctx.manifest_prune = ctx.manifest_prune or "false"
    ctx.manifest_deploy = ctx.manifest_deploy or "false"
    ctx.data_loading = "true"
    -- Coleção fixa do <radiogroup> de dia da semana (aba Manutenção). Semeada
    -- aqui, e não no docker_cleanup_apply_config, porque não depende da config carregada:
    -- se o load falhasse, a lista sumiria e o grupo ficaria vazio.
    ctx.weekdays = format.WEEKDAYS_JSON
    -- Itens das <tabbar> de rótulo fixo ({id,label}); a barra grava o id na
    -- chave `:value` sozinha, sem handler.
    ctx.settings_tabs = [=[[{"id":"web","label":"Web Server"},{"id":"git","label":"Git"},{"id":"iac","label":"Infra as Code"},{"id":"maintenance","label":"Manutenção"}]]=]
    ctx.docker_cleanup_kinds = [=[[{"id":"interval","label":"A cada N horas"},{"id":"daily","label":"Todo dia"},{"id":"weekly","label":"Toda semana"}]]=]
    ctx.git_provider_modes = [=[[{"id":"oauth","label":"OAuth2"},{"id":"pat","label":"Token (PAT)"}]]=]
    ctx.healthcheck_kinds = [=[[{"id":"none","label":"None"},{"id":"tcp","label":"Tcp"},{"id":"http","label":"Http"},{"id":"docker","label":"Docker"}]]=]
    -- Listas vazias como "[]" (não nil) para os ForEach não verem literal.
    for _, key in ipairs{
        "deployments",
        "projects",
        "project_rows",
        "services",
        "service_rows",
        "docker_rows",
        "docker_images",
        "docker_volumes",
        "docker_networks",
        "ingress",
        "host_ports",
        "jobs_summary",
        "project_jobs",
        "monitoring",
        "deploy_engine_active",
        "deploy_engine_recent",
        "project_services",
    } do
        if not ctx[key] or ctx[key] == "" then
            ctx[key] = "[]"
        end
    end
    -- Contadores nascem "…", não "0": antes do primeiro snapshot não sabemos
    -- quantos são, e "0" AFIRMA vazio — a UI piscava "Projects (0)" → "Projects
    -- (2)", e mensagens como "Nenhum job cadastrado ainda" apareciam durante o
    -- carregamento. O snapshot troca todos por número (apply_snapshot em
    -- handlers/stream.luau, junto de `data_loading = "false"`). Os `equals="0"`
    -- dos templates continuam valendo: com "…" não casam, então o estado vazio
    -- só pinta quando o dado realmente chegou e é zero.
    for _, key in ipairs{
        "deployments_count",
        "projects_count",
        "services_count",
        "ingress_count",
        "host_ports_count",
        "jobs_count",
        "project_env_count",
        "project_jobs_count",
        "project_secrets_count",
        "docker_images_count",
        "docker_volumes_count",
        "docker_networks_count",
        "deploy_engine_active_count",
        "deploy_engine_recent_count",
        "deploy_engine_success_24h",
        "deploy_engine_failed_24h",
        "deploy_engine_total_24h",
        "services_running",
        "services_total",
    } do
        if not ctx[key] or ctx[key] == "" then
            ctx[key] = "…"
        end
    end
    -- Semeia o formulário de login com a lista de servidores salvos, e
    -- pré-preenche a chave do mais usado por último (topo da lista) — para
    -- nascer pronto pra conectar de novo sem escolher nada.
    local stored = storage.get("saved_servers")
    if type(stored) == "table" then
        saved_servers = stored
    end
    publish_saved_servers()
    if #saved_servers > 0 and (not ctx.access_key or ctx.access_key == "") then
        ctx.access_key = AccessKey.encode(saved_servers[1].url, saved_servers[1].token)
    end
end

-- Configurações do daemon + provedores Git, buscados uma vez na conexão (não
-- entram no snapshot para não sobrescrever campos que o usuário edita).
local function load_settings(): ()
    local api = State.api
    if not api then return end
    local get_daemon_settings_ok, get_daemon_settings_response = api:rpc("GetDaemonSettings")
    if get_daemon_settings_ok and get_daemon_settings_response.DaemonSettings then
        -- Base pública derivada pelo daemon a partir de [api] domain/port — é
        -- só-leitura (não há setter no protocolo), serve para exibir a base do
        -- webhook e montar a redirect URI do OAuth.
        local base = get_daemon_settings_response.DaemonSettings.public_base_url or ""
        ctx.server_settings_public_base = base
        ctx.server_settings_email = get_daemon_settings_response.DaemonSettings.acme_email or ""
        ctx.server_settings_registry_domain = get_daemon_settings_response.DaemonSettings.registry_domain or ""
        ctx.git_provider_redirect = Helpers.oauth_redirect_uri(base)
    end
    -- A chave deste servidor, para Settings → Web Server → copiar. Montada
    -- aqui (já temos url + token da sessão) em vez de pedida ao daemon: assim
    -- ela é a que FUNCIONOU desta máquina, não a do `public_base_url`.
    ctx.server_access_key = if api.token then AccessKey.encode(api.base_url, api.token) else ""
    -- O comando que liga o Claude Code ao MCP deste servidor, pronto para colar
    -- num terminal: o token já resolvido, sem `curl /api/login` no meio.
    ctx.server_mcp_command = "claude mcp add --transport http --scope user rustploy "
        .. api.base_url .. "/mcp"
        .. (if api.token then ' --header "Authorization: Bearer ' .. api.token .. '"' else "")
    ctx.server_access_key_short = if api.token
        then string.sub(ctx.server_access_key, 1, 12) .. "…" .. string.sub(ctx.server_access_key, -6)
        else "— (daemon sem token)"
    local git_provider_list_ok, git_provider_list_response = api:rpc("GitProviderList")
    if git_provider_list_ok and git_provider_list_response.GitProviders then
        ctx.gitea_count = tostring(#git_provider_list_response.GitProviders)
    end
    Settings.docker_cleanup_load()
end

-- on_submit/on_click do formulário de login: decodifica a chave para saber
-- ONDE bater, troca-a pelo token em `POST /api/login` e valida a sessão com um
-- DaemonStatus antes de abrir o stream. `fetch` suspende a corrotina.
function connect(): ()
    local decoded_key, key_error = AccessKey.decode(ctx.access_key)
    if not decoded_key then
        ctx.error_access_key = key_error or "chave inválida"
        return
    end
    local base = Helpers.normalize_url(decoded_key.url)
    if not base then
        ctx.error_access_key = "a chave aponta para um endereço inválido: " .. decoded_key.url
        return
    end
    ctx.error_access_key = ""
    ctx.status_line = "conectando…"
    ctx.error = ""

    local login_ok, token_or_error, login_status = Api.login(base, ctx.access_key)
    local token = decoded_key.token
    if login_ok then
        token = token_or_error
    elseif login_status ~= 404 then
        -- 404 = daemon anterior ao login por chave: segue com o token de
        -- dentro dela, como antes. Atualizar a GUI antes do daemon não pode
        -- trancar ninguém para fora.
        ctx.error = token_or_error
        ctx.status_line = "falha na conexão"
        ctx.connected = "false"
        return
    end

    ctx.api_url = base
    ctx.api_token = token
    -- Topbar: a qual servidor esta janela está ligada (host:porta, sem esquema).
    ctx.connected_server = string.match(base, "^%a[%w+.-]*://(.+)$") or base
    local client = Api.new(base, token)
    State.api = client
    local daemon_status_ok, daemon_status_response = client:rpc("DaemonStatus")
    if not daemon_status_ok then
        State.api = nil
        ctx.error = daemon_status_response
        ctx.status_line = "falha na conexão"
        ctx.connected = "false"
        return
    end

    -- Só salva na lista quando a conexão realmente deu certo — uma tentativa
    -- com URL/token errados não deve virar entrada salva.
    remember_server(base, token)

    ctx.connected = "true"
    ctx.status_line = "conectado"
    ctx.screen = "shell"
    if not ctx.view or ctx.view == "" then
        ctx.view = "deployments"
    end

    load_settings()
    Stream.open_stream()
end

-- Logout: nada da sessão anterior pode sobreviver em RAM — nem no `ctx` (o
-- espelho do contexto do motor, de onde a UI pinta tudo: nomes de projeto,
-- linhas de log, api_token…) nem no `State` (cache do snapshot/métricas).
--
-- Em vez de enumerar as chaves a limpar — a lista cresce a cada tela nova e
-- sempre esquece alguma — apagamos o `ctx` INTEIRO e deixamos `init()` semear
-- os defaults como no boot. O login lembrado volta do `storage` (disco), não da
-- memória, então conectar de novo continua nascendo preenchido.
--
-- `ctx[k] = nil` é remoção de verdade, não só sumiço do lado Luau: o glacier
-- espelha o contexto na tabela no início da execução e, no fim, remove do motor
-- toda chave ausente nela (sync_to_luau/sync_from_luau).
function disconnect(): ()
    if State.state_conn then
        pcall(function()
            State.state_conn:close()
        end)
        State.state_conn = nil
    end
    State.api = nil
    State.snap = nil
    State.last_pairs = {}
    State.metrics_by_id = {}
    State.jobs_by_id = {}
    State.new_service_templates_all = {}
    State.search_term = ""
    State.deploy_track =
        { service_id = "", deployment_id = "", running = false, name = "" }

    -- Coleta as chaves antes de apagar: mutar a tabela durante o próprio
    -- `pairs` sobre ela é comportamento indefinido.
    local data = ctx :: { [string]: any }
    local keys: { string } = {}
    for key in pairs(data) do
        table.insert(keys, key)
    end
    for _, key in ipairs(keys) do
        data[key] = nil
    end

    init()
    ctx.connected = "false"
    ctx.screen = "login"
    ctx.status_line = "desconectado"
end
