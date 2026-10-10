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

local function choice_label(status_entry: any, choice: string): string
    if choice == "Keep" then
        return status_entry.state == "New" and "criar no projeto" or "manter a do projeto"
    end
    return CHOICE_LABEL[choice] or choice
end

local function options_for(status_entry: any): { string }
    if status_entry.state == "Conflict" then
        return { "Keep", "Overwrite", "ServiceOnly", "Ignore" }
    end
    return { "Keep", "ServiceOnly", "Ignore" }
end

-- "CHAVE=valor" por linha ⇄ tabela. Texto pré-preenchido com as chaves que
-- faltam, o usuário só completa o valor.
local function parse_key_value_lines(text: string?, target: { [string]: string }): ()
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        local key, value = line:match("^%s*([^=%s]+)%s*=(.*)$")
        if key then
            target[key] = Helpers.trim(value)
        end
    end
end

local function key_value_text(keys: { any }, values_by_key: { [string]: string }): string
    local out = {}
    for _, key in ipairs(keys) do
        table.insert(out, tostring(key) .. "=" .. (values_by_key[tostring(key)] or ""))
    end
    return table.concat(out, "\n")
end

local function nonempty(values: { [string]: string }): { [string]: string }?
    local out: { [string]: string } = {}
    local has_any = false
    for key, value in pairs(values) do
        if value ~= "" then
            out[key] = value
            has_any = true
        end
    end
    return has_any and out or nil
end

local function build_import_request(dry_run: boolean): any
    parse_key_value_lines(ctx.import_service_text, service_values)
    parse_key_value_lines(ctx.import_project_text, project_values)
    parse_key_value_lines(ctx.import_secret_text, secret_vals)

    local name = Helpers.trim(ctx.import_name)
    local provider = ctx.import_provider_id or ""
    local project_env: { [string]: string } = {}
    for key, choice in pairs(choices) do
        project_env[key] = choice
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
        dry_run = dry_run,
    }
end

local function load_providers(api: any): ()
    local git_provider_list_ok, git_provider_list_response = api:rpc("GitProviderList")
    local provider_options = json.array{}
    if git_provider_list_ok and type(git_provider_list_response) == "table" and git_provider_list_response.GitProviders then
        for _, git_provider in ipairs(git_provider_list_response.GitProviders) do
            table.insert(provider_options, { id = git_provider.id, label = git_provider.name })
        end
    end
    providers = provider_options
end

local function render_providers(): ()
    local rows = json.array{}
    for _, provider in ipairs(providers or {}) do
        table.insert(rows, {
            id = provider.id,
            label = provider.label,
            mark = (ctx.import_provider_id == provider.id) and "◉" or "○",
        })
    end
    ctx.import_providers = json.encode(rows)
end

local function show_report(report: any): ()
    ctx.import_report = "true"
    ctx.import_conflict = report.name_conflict and "true" or "false"
    if Helpers.trim(ctx.import_name) == "" then
        ctx.import_name = report.service_name
    end

    local warns = json.array{}
    for _, warning in ipairs(report.warnings or {}) do
        table.insert(warns, { text = "• " .. tostring(warning.message) })
    end
    ctx.import_warnings = json.encode(warns)
    ctx.import_has_warnings = #warns > 0 and "true" or "false"

    ctx.import_service_text = key_value_text(report.missing_service_vars or {}, service_values)
    ctx.import_project_text = key_value_text(report.missing_project_vars or {}, project_values)
    ctx.import_secret_text = key_value_text(report.missing_secrets or {}, secret_vals)
    ctx.import_has_service_missing = #(report.missing_service_vars or {}) > 0 and "true" or "false"
    ctx.import_has_project_missing = #(report.missing_project_vars or {}) > 0 and "true" or "false"
    ctx.import_has_secret_missing = #(report.missing_secrets or {}) > 0 and "true" or "false"
    ctx.import_has_missing = (#(report.missing_service_vars or {}) + #(report.missing_project_vars or {}) > 0) and "true" or "false"

    ctx.import_missing_provider = report.missing_git_provider or ""

    status = report.project_env or {}
    local rows = json.array{}
    for _, status_entry in ipairs(status) do
        if not choices[status_entry.key] then
            choices[status_entry.key] = status_entry.choice
        end
        local info = (status_entry.is_secret and "secret · " or "") .. (STATE_LABEL[status_entry.state] or status_entry.state)
        table.insert(rows, {
            key = status_entry.key,
            info = info,
            can_choose = status_entry.state ~= "Same" and "true" or "false",
            choice = choice_label(status_entry, choices[status_entry.key]),
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
    local service_import_ok, service_import_response = api:rpc_checked{ ServiceImport = build_import_request(true) }
    ctx.import_busy = ""
    ctx.import_message = ""

    if not service_import_ok or type(service_import_response) ~= "table" or not service_import_response.ServiceImportReport then
        ctx.import_report = "false"
        ctx.import_error = "erro: " .. tostring(service_import_response)
        return false
    end

    local report = service_import_response.ServiceImportReport
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
    local matched_status: any = nil
    for _, status_entry in ipairs(status) do
        if status_entry.key == key then
            matched_status = status_entry
        end
    end
    if not matched_status then
        return
    end

    local options = options_for(matched_status)
    local current_choice = choices[key] or matched_status.choice
    local current_index = 1
    for index, option in ipairs(options) do
        if option == current_choice then
            current_index = index
        end
    end

    local next_choice = options[(current_index % #options) + 1]
    if next_choice == "Overwrite" then
        local confirmed = confirm{
            title = "Sobrescrever no projeto?",
            message = "Trocar " .. key .. " no projeto altera o valor que os OUTROS serviços do projeto também enxergam.",
            confirm_label = "Sobrescrever",
            destructive = true,
        }
        if not confirmed then
            next_choice = options[((current_index + 1) % #options) + 1]
        end
    end

    choices[key] = next_choice
    analyze_core()
end

function import_use_provider(provider_id: string): ()
    ctx.import_provider_id = (ctx.import_provider_id == provider_id) and "" or provider_id
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
    local service_import_ok, service_import_response = api:rpc_checked{ ServiceImport = build_import_request(false) }
    ctx.import_busy = ""
    ctx.import_message = ""

    if not service_import_ok or type(service_import_response) ~= "table" or not service_import_response.ServiceImportReport then
        ctx.import_error = "erro: " .. tostring(service_import_response)
        return
    end

    local report = service_import_response.ServiceImportReport
    broadcast("service_created", {
        project_id = ctx.selected_project_id or "",
        name = report.service_name,
    })
    close_window()
end
