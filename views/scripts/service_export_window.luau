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
    local n = 0

    for _, v in ipairs(plan.project_env or {}) do
        local on = picked[v.key] == true
        if on then
            n += 1
        end

        local tags = {}
        if v.is_secret then
            table.insert(tags, "secret")
        end
        if v.suggested then
            table.insert(tags, "citada pelo serviço")
        end

        table.insert(rows, {
            key = v.key,
            mark = on and "☑" or "☐",
            tag = table.concat(tags, " · "),
        })
    end

    ctx.export_vars = json.encode(rows)
    ctx.export_picked_count = tostring(n)
end

local function pick(rule: (v: any) -> boolean): ()
    picked = {}
    for _, v in ipairs(plan.project_env or {}) do
        picked[v.key] = rule(v)
    end
    render()
end

function init(): ()
    local ok, p = pcall(json.decode, ctx.export_plan or "{}")
    plan = (ok and type(p) == "table") and p or {}

    ctx.export_service = plan.service_name or ""
    ctx.export_project = plan.project_name or ""
    ctx.export_blocked = plan.blocked or ""

    local names = {}
    for _, v in ipairs(plan.service_env or {}) do
        table.insert(names, v.key .. (v.is_secret and " 🔒" or ""))
    end
    ctx.export_service_vars = #names > 0 and table.concat(names, ", ") or "(este serviço não tem variáveis próprias)"
    ctx.export_service_count = tostring(#names)
    ctx.export_has_vars = (#(plan.project_env or {}) > 0) and "true" or "false"

    ctx.export_values = "true"
    ctx.export_yaml = ""
    ctx.export_error = ""
    ctx.export_message = ""

    pick(function(v: any): boolean
        return v.suggested == true
    end)
end

function field(key: string?, v: string?): ()
    if key then
        ctx[key] = v or ""
    end
end

function export_toggle(key: string): ()
    picked[key] = not picked[key]
    render()
end

function export_suggested(): ()
    pick(function(v: any): boolean
        return v.suggested == true
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
    for _, v in ipairs(plan.project_env or {}) do
        if picked[v.key] then
            table.insert(keys, v.key)
        end
    end

    ctx.export_error = ""
    ctx.export_message = "gerando…"
    local ok, res = api:rpc_checked{
        ServiceExport = {
            service_id = ctx.export_service_id,
            include_values = ctx.export_values == "true",
            project_env_keys = keys,
        },
    }
    ctx.export_message = ""

    if not ok or type(res) ~= "table" or not res.ServiceBundleYaml then
        ctx.export_error = "erro: " .. tostring(res)
        return nil, nil
    end

    return res.ServiceBundleYaml.yaml, res.ServiceBundleYaml.filename
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

    local okw, werr = write_file(path, yaml)
    if not okw then
        ctx.export_error = "falha ao gravar: " .. tostring(werr)
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
