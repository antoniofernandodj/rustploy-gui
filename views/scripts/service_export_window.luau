--!strict
--!nolint FunctionUnused
-- service_export_window.luau — script da JANELA "Exportar serviço", um motor
-- Glacier próprio e ISOLADO do app principal (aberto via open_window por
-- handlers/bundle.luau::open_export_window, que semeia a conexão e o plano:
-- ex_plan = JSON do ServiceExportPlan).
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

    ctx.ex_vars = json.encode(rows)
    ctx.ex_picked_count = tostring(n)
end

local function pick(rule: (v: any) -> boolean): ()
    picked = {}
    for _, v in ipairs(plan.project_env or {}) do
        picked[v.key] = rule(v)
    end
    render()
end

function init(): ()
    local ok, p = pcall(json.decode, ctx.ex_plan or "{}")
    plan = (ok and type(p) == "table") and p or {}

    ctx.ex_service = plan.service_name or ""
    ctx.ex_project = plan.project_name or ""
    ctx.ex_blocked = plan.blocked or ""

    local names = {}
    for _, v in ipairs(plan.service_env or {}) do
        table.insert(names, v.key .. (v.is_secret and " 🔒" or ""))
    end
    ctx.ex_svc_vars = #names > 0 and table.concat(names, ", ") or "(este serviço não tem variáveis próprias)"
    ctx.ex_svc_count = tostring(#names)
    ctx.ex_has_vars = (#(plan.project_env or {}) > 0) and "true" or "false"

    ctx.ex_values = "true"
    ctx.ex_yaml = ""
    ctx.ex_err = ""
    ctx.ex_msg = ""

    pick(function(v: any): boolean
        return v.suggested == true
    end)
end

function field(key: string?, v: string?): ()
    if key then
        ctx[key] = v or ""
    end
end

function ex_toggle(key: string): ()
    picked[key] = not picked[key]
    render()
end

function ex_suggested(): ()
    pick(function(v: any): boolean
        return v.suggested == true
    end)
end

function ex_all(): ()
    pick(function(_v: any): boolean
        return true
    end)
end

function ex_none(): ()
    pick(function(_v: any): boolean
        return false
    end)
end

-- Pede o pacote ao daemon com as escolhas da tela. `(yaml, nome_de_arquivo)`
-- ou `nil` (com ctx.ex_err preenchido).
local function generate(): (string?, string?)
    local api = client()
    if not api then
        ctx.ex_err = "sem conexão — reabra a janela pelo app"
        return nil, nil
    end

    local keys = json.array{}
    for _, v in ipairs(plan.project_env or {}) do
        if picked[v.key] then
            table.insert(keys, v.key)
        end
    end

    ctx.ex_err = ""
    ctx.ex_msg = "gerando…"
    local ok, res = api:rpc_checked{
        ServiceExport = {
            service_id = ctx.ex_service_id,
            include_values = ctx.ex_values == "true",
            project_env_keys = keys,
        },
    }
    ctx.ex_msg = ""

    if not ok or type(res) ~= "table" or not res.ServiceBundleYaml then
        ctx.ex_err = "erro: " .. tostring(res)
        return nil, nil
    end

    return res.ServiceBundleYaml.yaml, res.ServiceBundleYaml.filename
end

function ex_save(): ()
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
        ctx.ex_err = "falha ao gravar: " .. tostring(werr)
        return
    end
    ctx.ex_msg = "salvo em " .. path
end

-- Mostra o pacote como texto (com o botão Copiar) para quem não quer arquivo.
function ex_show(): ()
    local yaml = generate()
    if yaml then
        ctx.ex_yaml = yaml
    end
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
