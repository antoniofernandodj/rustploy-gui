--!strict
--!nolint FunctionUnused
-- new_registry_token_window.luau — script da JANELA "Novo token do registry",
-- um motor Glacier próprio e ISOLADO do app principal (aberto via open_window
-- por handlers/registry.luau::registry_open_token_window). Recebe a conexão
-- (api_url/api_token) e o host do registry (registry_host) já conhecidos pela
-- janela principal, semeados via open_window({ data = ... }).
--
-- require resolve relativo a ESTE arquivo (scripts/): "net/api" e "helpers".

local Api = require("net/api")
local Helpers = require("helpers")

local function client(): Api.Client?
    local url = ctx.api_url or ""
    if url == "" then
        return nil
    end
    return Api.new(url, ctx.api_token)
end

function init(): ()
    -- ctx.registry_host já chega pronto (semeado via data).
    ctx.registry_host = ctx.registry_host or "127.0.0.1:5100"

    ctx.new_registry_token_step = "form"
    ctx.new_registry_token_name = ""
    ctx.new_registry_token_scope = "pull"
    ctx.new_registry_token_scopes = [=[[{"id":"pull","label":"Somente leitura (pull)"},{"id":"push","label":"Leitura e escrita (push)"}]]=]
    ctx.new_registry_token_error = ""
    ctx.new_registry_token_message = ""
    ctx.new_registry_token_busy = ""
    ctx.new_registry_token_login_command = ""
end

-- Órfão desde que a aba virou <tabbar>: a barra grava `new_registry_token_scope` sozinha.
-- function new_registry_token_scope(s: string): ()
--     ctx.new_registry_token_scope = s
-- end

-- on_validation_error do form(...) — NOME é `rules="required"`; o motor já
-- publicou {error_new_registry_token_name} e acendeu o :invalid.
function new_registry_token_show_validation_errors(_erros_json: string?): ()
    toast{ message = "Informe o nome do token", kind = "warning" }
end

function new_registry_token_create(): ()
    local api = client()
    if not api then
        ctx.new_registry_token_error = "sem conexão — reabra a janela pelo app"
        return
    end
    -- rules="required" no form(...) garante new_registry_token_name preenchido aqui.
    local name = Helpers.trim(ctx.new_registry_token_name)
    ctx.new_registry_token_error = ""
    ctx.new_registry_token_message = "criando…"
    ctx.new_registry_token_busy = "true"

    local registry_token_create_ok, registry_token_create_response = api:rpc_checked{
        RegistryTokenCreate = {
            name = name,
            scope = ctx.new_registry_token_scope
        },
    }
    ctx.new_registry_token_busy = ""
    if not registry_token_create_ok then
        ctx.new_registry_token_message = ""
        ctx.new_registry_token_error = "erro: " .. tostring(registry_token_create_response)
        return
    end

    local created = (type(registry_token_create_response) == "table" and registry_token_create_response.RegistryTokenCreated) or {}
    local secret = created.secret or ""
    ctx.new_registry_token_login_command = string.format(
        "docker login %s -u %s -p %s",
        ctx.registry_host,
        created.name or name,
        secret
    )
    ctx.new_registry_token_step = "reveal"

    -- Avisa a janela principal já — não espera o "Fechar" (o usuário pode
    -- demorar pra copiar o segredo, ou nunca fechar explicitamente).
    broadcast("registry_token_created", { name = created.name or name })
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
