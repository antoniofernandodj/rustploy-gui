--!strict
--!nolint FunctionUnused
-- handlers/bundle_import.luau — passo "Importar" do wizard "Novo serviço": recria
-- aqui um serviço exportado de outro servidor. O destino é SEMPRE o projeto
-- aberto (ctx.selected_project_id), como numa criação qualquer — não há escolha
-- de projeto. Ver docs/plano-copiar-servico-entre-servidores.md.
--
-- Duas fases, como no daemon: `import_analyze` (dry_run: nada é gravado; mostra o
-- que não veio e o que precisa de decisão) e `import_create` (analisa de novo com o
-- que foi digitado e só então cria — sem deploy).

local State = require("../state")
local Helpers = require("../helpers")

-- Escolhas e valores digitados sobrevivem às re-análises (o relatório muda,
-- as decisões do usuário não).
local choices: { [string]: string } = {}
local status: { any } = {}
local service_values: { [string]: string } = {}
local project_values: { [string]: string } = {}
local secret_vals: { [string]: string } = {}
local providers: { any }? = nil -- Git providers deste servidor (carregados sob demanda)

local STATE_LABEL: { [string]: string } = {
    New = "nova",
    Same = "igual",
    Conflict = "em conflito"
}
local CHOICE_LABEL: { [string]: string } = {
    Overwrite = "sobrescrever a do projeto",
    ServiceOnly = "só neste serviço",
    Ignore = "não trazer",
}

local function choice_label(s: any, c: string): string
    if c == "Keep" then
        return s.state == "New" and "criar no projeto" or "manter a do projeto"
    end
    return CHOICE_LABEL[c] or c
end

local function options_for(s: any): { string }
    if s.state == "Conflict" then
        return { "Keep", "Overwrite", "ServiceOnly", "Ignore" }
    end
    return { "Keep", "ServiceOnly", "Ignore" }
end

-- "CHAVE=valor" por linha ⇄ tabela. Texto pré-preenchido com as chaves que
-- faltam, o usuário só completa o valor.
local function parse_kv(text: string?, into: { [string]: string }): ()
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        local k, v = line:match("^%s*([^=%s]+)%s*=(.*)$")
        if k then
            into[k] = Helpers.trim(v)
        end
    end
end

local function kv_text(keys: { any }, vals: { [string]: string }): string
    local out = {}
    for _, k in ipairs(keys) do
        table.insert(out, tostring(k) .. "=" .. (vals[tostring(k)] or ""))
    end
    return table.concat(out, "\n")
end

local function nonempty(m: { [string]: string }): { [string]: string }?
    local out: { [string]: string } = {}
    local any = false
    for k, v in pairs(m) do
        if v ~= "" then
            out[k] = v
            any = true
        end
    end
    return any and out or nil
end

local function build_req(dry: boolean): any
    parse_kv(ctx.import_service_text, service_values)
    parse_kv(ctx.import_project_text, project_values)
    parse_kv(ctx.import_secret_text, secret_vals)

    local name = Helpers.trim(ctx.import_name)
    local provider = ctx.import_provider_id or ""
    local project_env: { [string]: string } = {}
    for k, c in pairs(choices) do
        project_env[k] = c
    end

    -- Mapas vazios ficam de fora: o daemon tem `serde(default)` e o `{}` Lua
    -- seria ambíguo (objeto ou array) no JSON.
    return {
        yaml = ctx.import_text or "",
        project_id = ctx.selected_project_id or "",
        name = name ~= "" and name or nil,
        drop_domains = ctx.import_drop_domains == "true",
        git_provider_id = provider ~= "" and provider or nil,
        vars = nonempty(service_values),
        project_vars = nonempty(project_values),
        secrets = nonempty(secret_vals),
        project_env = next(project_env) ~= nil and project_env or nil,
        deploy = ctx.import_deploy == "true",
        dry_run = dry,
    }
end

local function load_providers(api: any): ()
    local ok, res = api:rpc("GitProviderList")
    local list = json.array{}
    if ok and type(res) == "table" and res.GitProviders then
        for _, p in ipairs(res.GitProviders) do
            table.insert(list, { id = p.id, label = p.name })
        end
    end
    providers = list
end

local function render_providers(): ()
    local rows = json.array{}
    for _, p in ipairs(providers or {}) do
        table.insert(rows, {
            id = p.id,
            label = p.label,
            mark = (ctx.import_provider_id == p.id) and "◉" or "○",
        })
    end
    ctx.import_providers = json.encode(rows)
end

local function show_report(r: any): ()
    ctx.import_report = "true"
    ctx.import_conflict = r.name_conflict and "true" or "false"
    if Helpers.trim(ctx.import_name) == "" then
        ctx.import_name = r.service_name
    end

    local warns = json.array{}
    for _, w in ipairs(r.warnings or {}) do
        table.insert(warns, { text = "• " .. tostring(w.message) })
    end
    ctx.import_warnings = json.encode(warns)
    ctx.import_has_warnings = #warns > 0 and "true" or "false"

    ctx.import_service_text = kv_text(r.missing_service_vars or {}, service_values)
    ctx.import_project_text = kv_text(r.missing_project_vars or {}, project_values)
    ctx.import_secret_text = kv_text(r.missing_secrets or {}, secret_vals)
    ctx.import_has_service_missing = #(r.missing_service_vars or {}) > 0 and "true" or "false"
    ctx.import_has_project_missing = #(r.missing_project_vars or {}) > 0 and "true" or "false"
    ctx.import_has_secret_missing = #(r.missing_secrets or {}) > 0 and "true" or "false"
    ctx.import_has_missing = (#(r.missing_service_vars or {}) + #(r.missing_project_vars or {}) > 0) and "true" or "false"

    ctx.import_missing_provider = r.missing_git_provider or ""

    status = r.project_env or {}
    local rows = json.array{}
    for _, s in ipairs(status) do
        if not choices[s.key] then
            choices[s.key] = s.choice
        end
        local info = (s.is_secret and "secret · " or "") .. (STATE_LABEL[s.state] or s.state)
        table.insert(rows, {
            key = s.key,
            info = info,
            can_choose = s.state ~= "Same" and "true" or "false",
            choice = choice_label(s, choices[s.key]),
        })
    end
    ctx.import_project_env = json.encode(rows)
    ctx.import_has_project_env = #rows > 0 and "true" or "false"
end

-- Pré-visualização (nada é gravado). Devolve se o relatório chegou.
local function analyze_core(): boolean
    local api = State.api
    if not api then
        return false
    end
    if Helpers.trim(ctx.import_text) == "" then
        ctx.import_error = "escolha um arquivo ou cole o texto do pacote"
        return false
    end

    ctx.import_error = ""
    ctx.import_message = "analisando…"
    ctx.import_busy = "true"
    local ok, res = api:rpc_checked{ ServiceImport = build_req(true) }
    ctx.import_busy = ""
    ctx.import_message = ""

    if not ok or type(res) ~= "table" or not res.ServiceImportReport then
        ctx.import_report = "false"
        ctx.import_error = "erro: " .. tostring(res)
        return false
    end

    local report = res.ServiceImportReport
    if report.missing_git_provider and providers == nil then
        load_providers(api)
    end
    show_report(report)
    render_providers()
    return true
end

function import_analyze(): ()
    analyze_core()
end

-- "Escolher arquivo…": lê o .yml e já analisa.
function import_pick_file(): ()
    local path = open_file{
        title = "Importar serviço (.yml)",
        filters = { { name = "YAML", extensions = { "yml", "yaml" } } },
    }
    if not path then
        return
    end

    local read = fetch("file://" .. path)
    if not read.ok then
        ctx.import_error = "erro ao ler o arquivo: " .. tostring(read.error)
        return
    end

    ctx.import_text = read.body
    ctx.import_file = path:match("([^/\\]+)$") or path
    ctx.import_name = ""
    analyze_core()
end

-- "Trocar pacote": volta ao início, sem lixo do pacote anterior.
function import_clear(): ()
    choices = {}
    status = {}
    service_values = {}
    project_values = {}
    secret_vals = {}
    providers = nil
    ctx.import_text = ""
    ctx.import_file = ""
    ctx.import_name = ""
    ctx.import_report = "false"
    ctx.import_error = ""
    ctx.import_message = ""
    ctx.import_provider_id = ""
    ctx.import_drop_domains = "false"
    ctx.import_deploy = "false"
end

-- Passa para a próxima escolha da variável do projeto (ciclo). Sobrescrever
-- mexe no projeto e vale para os outros serviços dele: pede confirmação.
function import_choice(key: string): ()
    local s: any = nil
    for _, x in ipairs(status) do
        if x.key == key then
            s = x
        end
    end
    if not s then
        return
    end

    local opts = options_for(s)
    local cur = choices[key] or s.choice
    local idx = 1
    for i, o in ipairs(opts) do
        if o == cur then
            idx = i
        end
    end

    local nxt = opts[(idx % #opts) + 1]
    if nxt == "Overwrite" then
        local sure = confirm{
            title = "Sobrescrever no projeto?",
            message = "Trocar " .. key .. " no projeto altera o valor que os OUTROS serviços do projeto também enxergam.",
            confirm_label = "Sobrescrever",
            destructive = true,
        }
        if not sure then
            nxt = opts[((idx + 1) % #opts) + 1]
        end
    end

    choices[key] = nxt
    analyze_core()
end

function import_use_provider(id: string): ()
    ctx.import_provider_id = (ctx.import_provider_id == id) and "" or id
    analyze_core()
end

-- Analisa de novo com o que foi digitado e só cria se estiver limpo.
function import_create(): ()
    local api = State.api
    if not api then
        return
    end
    if not analyze_core() then
        return
    end
    if ctx.import_conflict == "true" then
        ctx.import_error = "já existe um serviço com esse nome neste projeto — escolha outro"
        return
    end
    if ctx.import_has_missing == "true" then
        ctx.import_error = "preencha os valores obrigatórios acima"
        return
    end

    ctx.import_error = ""
    ctx.import_message = "criando…"
    ctx.import_busy = "true"
    local ok, res = api:rpc_checked{ ServiceImport = build_req(false) }
    ctx.import_busy = ""
    ctx.import_message = ""

    if not ok or type(res) ~= "table" or not res.ServiceImportReport then
        ctx.import_error = "erro: " .. tostring(res)
        return
    end

    local done = res.ServiceImportReport
    broadcast("service_created", {
        project_id = ctx.selected_project_id or "",
        name = done.service_name,
    })
    close_window()
end
