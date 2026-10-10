--!strict
--!nolint FunctionUnused
-- handlers/wizard.luau — wizard "Novo serviço". A construção do ServiceSpec
-- (incl. compose de banco/broker e blueprints de template) vive no daemon: o
-- cliente só coleta os campos e delega via Command::WizardCatalog (catálogos)
-- + WizardCreate (montagem+criação).

local State = require("../state")
local Helpers = require("../helpers")

local NS_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
math.randomseed(os.time())
local function token_urlsafe(length: number): string
    local characters = {}
    for index = 1, length do
        local alphabet_index = math.random(1, #NS_ALPHABET)
        characters[index] = string.sub(NS_ALPHABET, alphabet_index, alphabet_index)
    end
    return table.concat(characters)
end

local function new_service_is_broker(kind_id: string): boolean
    return kind_id == "kafka" or kind_id == "rabbitmq" or kind_id == "nats"
end

-- Botão "+ Novo serviço" (cabeçalho do projeto): abre o wizard numa JANELA à
-- parte (motor Glacier próprio). O catálogo (dbs/brokers/templates) é buscado
-- AQUI e passado via `data` — buscar no init da janela NÃO funciona: o `init`
-- roda no register do componente e o glacier descarta o `fetch` disparado por
-- ele (só efeitos/streams de AÇÕES despachadas rodam no executor). Este handler
-- é uma ação despachada, então o `fetch` do WizardCatalog resolve normalmente e
-- a janela abre depois, já com o catálogo. Ao criar, a janela envia
-- broadcast("service_created") e se fecha (ver new_service_create). Substitui o antigo
-- fluxo inline (view=new_service), removido do shell.gvb.
-- `start` opcional ("import"): o ícone de importar do card de serviço abre o
-- wizard direto no passo Importar (`open_new_service_window:import`).
function open_new_service_window(start: string?): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or not api then
        return
    end
    local databases_json, brokers, templates = "[]", "[]", "[]"
    local wizard_catalog_ok, wizard_catalog_response = api:rpc{ WizardCatalog = { search = "" } }
    if wizard_catalog_ok and wizard_catalog_response.WizardCatalog then
        databases_json = wizard_catalog_response.WizardCatalog.dbs or "[]"
        brokers = wizard_catalog_response.WizardCatalog.brokers or "[]"
        templates = wizard_catalog_response.WizardCatalog.templates or "[]"
    end
    open_window{
        component = "new_service", size = "560 700", decorations = false,
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            selected_project_id = project_id,
            project_name = ctx.project_name or "",
            new_service_start = start or "",
            new_service_databases = databases_json,
            new_service_brokers = brokers,
            new_service_templates = templates,
        },
    }
end

-- "Cancelar": fecha a janela do wizard.
function new_service_cancel(): ()
    close_window()
end

-- "‹ Voltar": num passo interno volta à escolha de tipo; no passo inicial
-- (pick_type) fecha a janela.
function new_service_back(): ()
    local step = ctx.new_service_step
    if step == "pick_db" or step == "pick_broker" or step == "app_form"
        or step == "compose_form" or step == "pick_template" or step == "db_form"
        or step == "template_form" or step == "import_form" then
        ctx.new_service_step = "pick_type"
        ctx.new_service_message = ""
    else
        close_window()
    end
end

function new_service_kind(kind_choice: string): ()
    if kind_choice == "application" then
        ctx.new_service_step = "app_form"
    elseif kind_choice == "compose" then
        ctx.new_service_step = "compose_form"
    elseif kind_choice == "database" then
        ctx.new_service_step = "pick_db"
    elseif kind_choice == "broker" then
        ctx.new_service_step = "pick_broker"
    elseif kind_choice == "template" then
        ctx.new_service_step = "pick_template"
    elseif kind_choice == "import" then
        ctx.new_service_step = "import_form"
    end
end

-- Banco escolhido: pré-preenche o formulário (senhas geradas no cliente).
function new_service_database(database_kind: string): ()
    local json_decode_ok, database_options = pcall(json.decode, ctx.new_service_databases or "[]")
    if not json_decode_ok or type(database_options) ~= "table" then
        return
    end
    for _, database_option in ipairs(database_options) do
        if database_option.id == database_kind then
            ctx.new_service_database_kind = database_kind
            ctx.new_service_database_label = database_option.label
            ctx.new_service_image = database_option.image
            ctx.new_service_database_name = database_option.has_db_name and "app" or ""
            ctx.new_service_database_user = database_option.user or ""
            ctx.new_service_database_password = token_urlsafe(22)
            ctx.new_service_database_root_password = token_urlsafe(22)
            ctx.new_service_use_replica = "false"
            ctx.new_service_expose_external = "false"
            ctx.new_service_database_has_dbname = database_option.has_db_name and "true" or "false"
            ctx.new_service_database_has_user = database_option.has_user and "true" or "false"
            ctx.new_service_database_has_rootpw = database_option.has_rootpw and "true" or "false"
            ctx.new_service_database_has_replica = database_option.has_replica and "true" or "false"
            ctx.new_service_name = ""
            ctx.new_service_step = "db_form"
            return
        end
    end
end

-- Broker escolhido: compartilha o passo db_form (mesmas chaves ns_db_*).
function new_service_broker(broker_kind: string): ()
    local json_decode_ok, broker_options = pcall(json.decode, ctx.new_service_brokers or "[]")
    if not json_decode_ok or type(broker_options) ~= "table" then
        return
    end
    for _, broker_option in ipairs(broker_options) do
        if broker_option.id == broker_kind then
            ctx.new_service_database_kind = broker_kind
            ctx.new_service_database_label = broker_option.label
            ctx.new_service_image = broker_option.image
            ctx.new_service_database_name = ""
            ctx.new_service_database_user = broker_option.user or ""
            ctx.new_service_database_password = token_urlsafe(22)
            ctx.new_service_database_root_password = ""
            ctx.new_service_use_replica = "false"
            ctx.new_service_expose_external = "false"
            ctx.new_service_database_has_dbname = "false"
            ctx.new_service_database_has_user = broker_option.has_user and "true" or "false"
            ctx.new_service_database_has_rootpw = "false"
            ctx.new_service_database_has_replica = "false"
            ctx.new_service_name = ""
            ctx.new_service_step = "db_form"
            return
        end
    end
end

-- Template escolhido: carrega nome/slug + variáveis editáveis (do catálogo).
function new_service_pick_template(template_id: string): ()
    for _, template in ipairs(State.new_service_templates_all) do
        if template.id == template_id then
            ctx.new_service_template_id = template_id
            ctx.new_service_template_name = template.name
            ctx.new_service_name = template.slug or ""
            ctx.new_service_template_vars = (
                template.vars and #template.vars > 0
            ) and json.encode(template.vars) or "[]";

            for _, variable in ipairs(template.vars or {}) do
                ctx["new_service_template_variable_value_" .. variable.idx] = ""
            end
            ctx.new_service_step = "template_form"
            return
        end
    end
end

-- Busca do catálogo de templates (filtra o cache no cliente).
function new_service_template_search(search_text: string): ()
    ctx.new_service_template_search = search_text or ""
    local term = string.lower(search_text or "")
    local rows = {}
    for _, template in ipairs(State.new_service_templates_all) do
        if term == ""
            or string.find(string.lower(template.name or ""), term, 1, true)
            or string.find(string.lower(template.description or ""), term, 1, true)
        then
            table.insert(rows, template)
        end
    end
    ctx.new_service_templates = (#rows > 0) and json.encode(rows) or "[]"
end

function new_service_create(): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or not api then
        return
    end
    local step = ctx.new_service_step
    local kind, selected_template_id
    if step == "app_form" then
        kind, selected_template_id = "application", ""
    elseif step == "compose_form" then
        kind, selected_template_id = "compose", ""
    elseif step == "db_form" then
        selected_template_id = ctx.new_service_database_kind or ""
        kind = new_service_is_broker(selected_template_id) and "broker" or "database"
    elseif step == "template_form" then
        kind, selected_template_id = "template", ctx.new_service_template_id or ""
    else
        ctx.new_service_message = "passo inválido";
        return
    end

    -- Nome obrigatório, exceto no template (tem slug default).
    local name = Helpers.trim(ctx.new_service_name)
    if 
        step ~= "template_form" and
        Helpers.trim(ctx.new_service_app_name) == ""
        and name == ""
    then
        ctx.error_new_service_name = "informe um nome";
        return
    end
    ctx.error_new_service_name = ""

    -- Valores das variáveis do template, na ordem declarada.
    local tvals = json.array{}
    if step == "template_form" then
        local json_decode_ok, vars = pcall(json.decode, ctx.new_service_template_vars or "[]")
        if json_decode_ok and type(vars) == "table" then
            for _, variable in ipairs(vars) do
                table.insert(tvals, ctx["new_service_template_variable_value_" .. variable.idx] or "")
            end
        end
    end

    local create_request = {
        kind = kind,
        id = selected_template_id,
        project_id = project_id,
        name = name,
        app_name = Helpers.trim(ctx.new_service_app_name),
        db_name = Helpers.trim(ctx.new_service_database_name),
        user = Helpers.trim(ctx.new_service_database_user),
        password = Helpers.trim(ctx.new_service_database_password),
        root_password = Helpers.trim(ctx.new_service_database_root_password),
        image = Helpers.trim(ctx.new_service_image),
        use_replica = (ctx.new_service_use_replica == "true"),
        template_values = tvals,
        -- Porta externa automática + liberação no firewall (daemon aloca da
        -- faixa [external_ports]; sentinela host_port=0 no build_spec).
        expose_external = (ctx.new_service_expose_external == "true"),
    }
    ctx.new_service_message = "criando…"
    ctx.new_service_busy = "true"
    local wizard_create_ok, wizard_create_response = api:rpc_checked{ WizardCreate = create_request }
    ctx.new_service_busy = ""
    if wizard_create_ok and wizard_create_response.Service then
        -- Sucesso: avisa a janela principal (que atualiza a grade de serviços do
        -- projeto aberto) e fecha esta janela do wizard.
        local display_name = (name ~= "" and name) or Helpers.trim(ctx.new_service_app_name)
        broadcast("service_created", {
            project_id = project_id,
            name = display_name,
        })
        close_window()
    else
        ctx.new_service_message = wizard_create_ok and "resposta inesperada" or ("erro: " .. wizard_create_response)
        toast{ message = tostring(wizard_create_ok and "resposta inesperada do daemon" or wizard_create_response), kind = "error" }
    end
end
