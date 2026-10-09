--!strict
--!nolint FunctionUnused
-- handlers/bundle_import.luau — passo "Importar" do wizard "Novo serviço": recria
-- aqui um serviço exportado de outro servidor. O destino é SEMPRE o projeto
-- aberto (ctx.selected_project_id), como numa criação qualquer — não há escolha
-- de projeto. Ver docs/plano-copiar-servico-entre-servidores.md.
--
-- Duas fases, como no daemon: `imp_analyze` (dry_run: nada é gravado; mostra o
-- que não veio e o que precisa de decisão) e `imp_create` (analisa de novo com o
-- que foi digitado e só então cria — sem deploy).

local State = require("../state")
local Helpers = require("../helpers")

-- Escolhas e valores digitados sobrevivem às re-análises (o relatório muda,
-- as decisões do usuário não).
local choices: { [string]: string } = {}
local status: { any } = {}
local svc_vals: { [string]: string } = {}
local proj_vals: { [string]: string } = {}
local secret_vals: { [string]: string } = {}
local providers: { any }? = nil -- Git providers deste servidor (carregados sob demanda)

local STATE_LABEL: { [string]: string } = { New = "nova", Same = "igual", Conflict = "em conflito" }
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
    parse_kv(ctx.imp_svc_text, svc_vals)
    parse_kv(ctx.imp_proj_text, proj_vals)
    parse_kv(ctx.imp_secret_text, secret_vals)

    local name = Helpers.trim(ctx.imp_name)
    local provider = ctx.imp_provider_id or ""
    local project_env: { [string]: string } = {}
    for k, c in pairs(choices) do
        project_env[k] = c
    end

    -- Mapas vazios ficam de fora: o daemon tem `serde(default)` e o `{}` Lua
    -- seria ambíguo (objeto ou array) no JSON.
    return {
        yaml = ctx.imp_text or "",
        project_id = ctx.selected_project_id or "",
        name = name ~= "" and name or nil,
        drop_domains = ctx.imp_drop_domains == "true",
        git_provider_id = provider ~= "" and provider or nil,
        vars = nonempty(svc_vals),
        project_vars = nonempty(proj_vals),
        secrets = nonempty(secret_vals),
        project_env = next(project_env) ~= nil and project_env or nil,
        deploy = ctx.imp_deploy == "true",
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
            mark = (ctx.imp_provider_id == p.id) and "◉" or "○",
        })
    end
    ctx.imp_providers = json.encode(rows)
end

local function show_report(r: any): ()
    ctx.imp_report = "true"
    ctx.imp_conflict = r.name_conflict and "true" or "false"
    if Helpers.trim(ctx.imp_name) == "" then
        ctx.imp_name = r.service_name
    end

    local warns = json.array{}
    for _, w in ipairs(r.warnings or {}) do
        table.insert(warns, { text = "• " .. tostring(w.message) })
    end
    ctx.imp_warnings = json.encode(warns)
    ctx.imp_has_warnings = #warns > 0 and "true" or "false"

    ctx.imp_svc_text = kv_text(r.missing_service_vars or {}, svc_vals)
    ctx.imp_proj_text = kv_text(r.missing_project_vars or {}, proj_vals)
    ctx.imp_secret_text = kv_text(r.missing_secrets or {}, secret_vals)
    ctx.imp_has_svc_missing = #(r.missing_service_vars or {}) > 0 and "true" or "false"
    ctx.imp_has_proj_missing = #(r.missing_project_vars or {}) > 0 and "true" or "false"
    ctx.imp_has_secret_missing = #(r.missing_secrets or {}) > 0 and "true" or "false"
    ctx.imp_has_missing = (#(r.missing_service_vars or {}) + #(r.missing_project_vars or {}) > 0) and "true" or "false"

    ctx.imp_missing_provider = r.missing_git_provider or ""

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
    ctx.imp_pe = json.encode(rows)
    ctx.imp_has_pe = #rows > 0 and "true" or "false"
end

-- Pré-visualização (nada é gravado). Devolve se o relatório chegou.
local function analyze_core(): boolean
    local api = State.api
    if not api then
        return false
    end
    if Helpers.trim(ctx.imp_text) == "" then
        ctx.imp_err = "escolha um arquivo ou cole o texto do pacote"
        return false
    end

    ctx.imp_err = ""
    ctx.imp_msg = "analisando…"
    ctx.imp_busy = "true"
    local ok, res = api:rpc_checked{ ServiceImport = build_req(true) }
    ctx.imp_busy = ""
    ctx.imp_msg = ""

    if not ok or type(res) ~= "table" or not res.ServiceImportReport then
        ctx.imp_report = "false"
        ctx.imp_err = "erro: " .. tostring(res)
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

function imp_analyze(): ()
    analyze_core()
end

-- "Escolher arquivo…": lê o .yml e já analisa.
function imp_pick_file(): ()
    local path = open_file{
        title = "Importar serviço (.yml)",
        filters = { { name = "YAML", extensions = { "yml", "yaml" } } },
    }
    if not path then
        return
    end

    local read = fetch("file://" .. path)
    if not read.ok then
        ctx.imp_err = "erro ao ler o arquivo: " .. tostring(read.error)
        return
    end

    ctx.imp_text = read.body
    ctx.imp_file = path:match("([^/\\]+)$") or path
    ctx.imp_name = ""
    analyze_core()
end

-- "Trocar pacote": volta ao início, sem lixo do pacote anterior.
function imp_clear(): ()
    choices = {}
    status = {}
    svc_vals = {}
    proj_vals = {}
    secret_vals = {}
    providers = nil
    ctx.imp_text = ""
    ctx.imp_file = ""
    ctx.imp_name = ""
    ctx.imp_report = "false"
    ctx.imp_err = ""
    ctx.imp_msg = ""
    ctx.imp_provider_id = ""
    ctx.imp_drop_domains = "false"
    ctx.imp_deploy = "false"
end

-- Passa para a próxima escolha da variável do projeto (ciclo). Sobrescrever
-- mexe no projeto e vale para os outros serviços dele: pede confirmação.
function imp_choice(key: string): ()
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

function imp_use_provider(id: string): ()
    ctx.imp_provider_id = (ctx.imp_provider_id == id) and "" or id
    analyze_core()
end

-- Analisa de novo com o que foi digitado e só cria se estiver limpo.
function imp_create(): ()
    local api = State.api
    if not api then
        return
    end
    if not analyze_core() then
        return
    end
    if ctx.imp_conflict == "true" then
        ctx.imp_err = "já existe um serviço com esse nome neste projeto — escolha outro"
        return
    end
    if ctx.imp_has_missing == "true" then
        ctx.imp_err = "preencha os valores obrigatórios acima"
        return
    end

    ctx.imp_err = ""
    ctx.imp_msg = "criando…"
    ctx.imp_busy = "true"
    local ok, res = api:rpc_checked{ ServiceImport = build_req(false) }
    ctx.imp_busy = ""
    ctx.imp_msg = ""

    if not ok or type(res) ~= "table" or not res.ServiceImportReport then
        ctx.imp_err = "erro: " .. tostring(res)
        return
    end

    local done = res.ServiceImportReport
    broadcast("service_created", {
        project_id = ctx.selected_project_id or "",
        name = done.service_name,
    })
    close_window()
end
