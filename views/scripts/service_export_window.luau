--!strict
--!nolint FunctionUnused
-- service_export_window.luau — script da JANELA "Exportar serviço", um motor
-- Glacier próprio e ISOLADO do app principal (aberto via open_window por
-- handlers/bundle.luau::open_export_window, que semeia a conexão e o plano:
-- export_plan = JSON do ServiceExportPlan).
--
-- O usuário marca quais variáveis do PROJETO levar (o rustploy não sabe quais o
-- app lê: o container recebe todas) e escolhe incluir ou não os valores; o
-- daemon gera o pacote (YAML) — aqui só se escolhe e se grava.

local Api = require("net/api")

local plan: any = {}
local picked: { [string]: boolean } = {}

local function client(): Api.Client?
    local url = ctx.api_url or ""
    if url == "" then
        return nil
    end
    return Api.new(url, ctx.api_token)
end

-- Reconstrói a lista exibida (☑/☐ por variável do projeto) a partir de `picked`.
local function render(): ()
    local rows = json.array{}
    local picked_count = 0

    for _, env_var in ipairs(plan.project_env or {}) do
        local on = picked[env_var.key] == true
        if on then
            picked_count += 1
        end

        local tags = {}
        if env_var.is_secret then
            table.insert(tags, "secret")
        end
        if env_var.suggested then
            table.insert(tags, "citada pelo serviço")
        end

        table.insert(rows, {
            key = env_var.key,
            mark = on and "☑" or "☐",
            tag = table.concat(tags, " · "),
        })
    end

    ctx.export_vars = json.encode(rows)
    ctx.export_picked_count = tostring(picked_count)
end

local function pick(rule: (env_var: any) -> boolean): ()
    picked = {}
    for _, env_var in ipairs(plan.project_env or {}) do
        picked[env_var.key] = rule(env_var)
    end
    render()
end

function init(): ()
    local json_decode_ok, decoded = pcall(json.decode, ctx.export_plan or "{}")
    plan = (json_decode_ok and type(decoded) == "table") and decoded or {}

    ctx.export_service = plan.service_name or ""
    ctx.export_project = plan.project_name or ""
    ctx.export_blocked = plan.blocked or ""

    local names = {}
    for _, env_var in ipairs(plan.service_env or {}) do
        table.insert(names, env_var.key .. (env_var.is_secret and " 🔒" or ""))
    end
    ctx.export_service_vars = #names > 0 and table.concat(names, ", ") or "(este serviço não tem variáveis próprias)"
    ctx.export_service_count = tostring(#names)
    ctx.export_has_vars = (#(plan.project_env or {}) > 0) and "true" or "false"

    ctx.export_values = "true"
    ctx.export_yaml = ""
    ctx.export_error = ""
    ctx.export_message = ""

    pick(function(env_var: any): boolean
        return env_var.suggested == true
    end)
end

function field(key: string?, value: string?): ()
    if key then
        ctx[key] = value or ""
    end
end

function export_toggle(key: string): ()
    picked[key] = not picked[key]
    render()
end

function export_suggested(): ()
    pick(function(env_var: any): boolean
        return env_var.suggested == true
    end)
end

function export_all(): ()
    pick(function(_v: any): boolean
        return true
    end)
end

function export_none(): ()
    pick(function(_v: any): boolean
        return false
    end)
end

-- Pede o pacote ao daemon com as escolhas da tela. `(yaml, nome_de_arquivo)`
-- ou `nil` (com ctx.export_error preenchido).
local function generate(): (string?, string?)
    local api = client()
    if not api then
        ctx.export_error = "sem conexão — reabra a janela pelo app"
        return nil, nil
    end

    local keys = json.array{}
    for _, env_var in ipairs(plan.project_env or {}) do
        if picked[env_var.key] then
            table.insert(keys, env_var.key)
        end
    end

    ctx.export_error = ""
    ctx.export_message = "gerando…"
    local service_export_ok, service_export_response = api:rpc_checked{
        ServiceExport = {
            service_id = ctx.export_service_id,
            include_values = ctx.export_values == "true",
            project_env_keys = keys,
        },
    }
    ctx.export_message = ""

    if not service_export_ok or type(service_export_response) ~= "table" or not service_export_response.ServiceBundleYaml then
        ctx.export_error = "erro: " .. tostring(service_export_response)
        return nil, nil
    end

    return service_export_response.ServiceBundleYaml.yaml, service_export_response.ServiceBundleYaml.filename
end

function export_save(): ()
    local yaml, filename = generate()
    if not yaml then
        return
    end

    -- `save_file` (SUSPENDE): o usuário escolhe onde gravar.
    local path = save_file{
        title = "Salvar pacote do serviço",
        default_name = filename or "servico.rustploy-service.yml",
        filters = { { name = "YAML", extensions = { "yml", "yaml" } } },
    }
    if not path then
        return
    end

    local write_ok, write_error = write_file(path, yaml)
    if not write_ok then
        ctx.export_error = "falha ao gravar: " .. tostring(write_error)
        return
    end
    ctx.export_message = "salvo em " .. path
end

-- Mostra o pacote como texto (com o botão Copiar) para quem não quer arquivo.
function export_show(): ()
    local yaml = generate()
    if yaml then
        ctx.export_yaml = yaml
    end
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
