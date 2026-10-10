--!strict
--!nolint FunctionUnused
-- new_service_window.luau — script da JANELA do wizard "Novo serviço", um motor
-- Glacier próprio e ISOLADO do app principal (aberto via open_window por
-- handlers/wizard.luau::open_new_service_window). Recebe a conexão
-- (api_url/api_token) e o projeto-alvo (selected_project_id/project_name) semeados
-- no contexto por open_window({ data = ... }).
--
-- A lógica do wizard em si (new_service_kind/new_service_database/new_service_create/…)
-- vem de handlers/wizard.luau,
-- carregado abaixo por require (define as funções globais que o template usa).
-- require resolve relativo a ESTE arquivo (scripts/): "state", "net/api" e
-- "handlers/wizard" — os mesmos módulos do app principal, mas neste motor isolado
-- (State.api é reconstruído da conexão semeada).
--
-- O catálogo (new_service_databases/new_service_brokers/new_service_templates)
-- vem SEMEADO via open_window({data})
-- — a janela principal já o buscou. NÃO buscamos aqui no init: o `fetch` de um
-- init é descartado pelo motor (só ações despachadas rodam no executor); por isso
-- o antigo `load_catalog()` no init deixava as listas vazias.

local State = require("state")
local Api = require("net/api")
require("handlers/wizard")
require("handlers/bundle_import")

function init(): ()
    -- Reconstrói o cliente da API a partir da conexão semeada (usado pelo
    -- new_service_create, que é uma ação despachada — aí o fetch funciona).
    local url = ctx.api_url or ""
    if url ~= "" then
        State.api = Api.new(url, ctx.api_token)
    end

    -- Decodifica os templates semeados para State (usado por new_service_pick_template/
    -- new_service_template_search, que leem State.new_service_templates_all, não o contexto).
    local okt, all = pcall(json.decode, ctx.new_service_templates or "[]")
    State.new_service_templates_all = (okt and type(all) == "table") and all or {}

    -- Estado inicial do wizard (o catálogo já veio no contexto via data).
    ctx.new_service_name = ""
    ctx.new_service_app_name = ""
    ctx.new_service_message = ""
    ctx.new_service_busy = ""
    ctx.error_new_service_name = ""
    ctx.new_service_template_search = ""
    ctx.new_service_step = (ctx.new_service_start == "import") and "import_form" or "pick_type"

    -- Passo "Importar" (handlers/bundle_import.luau).
    ctx.import_text = ""
    ctx.import_file = ""
    ctx.import_name = ""
    ctx.import_report = "false"
    ctx.import_error = ""
    ctx.import_message = ""
    ctx.import_busy = ""
    ctx.import_provider_id = ""
    ctx.import_drop_domains = "false"
    ctx.import_deploy = "false"
end

-- Setter genérico de campo (on_change="field:<chave>" dos inputs do wizard).
-- Precisa existir NESTE motor: `field` mora em handlers/nav.luau, que a janela
-- não carrega (só carrega handlers/wizard); sem ele, digitar nos inputs não
-- escrevia nada no contexto. Mesmo papel do `field` de new_project_window.luau.
function field(key: string?, v: string?): ()
    if key then
        ctx[key] = v or ""
    end
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
