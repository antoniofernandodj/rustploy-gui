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
local function token_urlsafe(n: number): string
    local t = {}
    for i = 1, n do
        local idx = math.random(1, #NS_ALPHABET)
        t[i] = string.sub(NS_ALPHABET, idx, idx)
    end
    return table.concat(t)
end

local function new_service_is_broker(id: string): boolean
    return id == "kafka" or id == "rabbitmq" or id == "nats"
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
    local pid = ctx.selected_project_id or ""
    local api = State.api
    if pid == "" or not api then
        return
    end
    local dbs, brokers, templates = "[]", "[]", "[]"
    local ok, res = api:rpc{ WizardCatalog = { search = "" } }
    if ok and res.WizardCatalog then
        dbs = res.WizardCatalog.dbs or "[]"
        brokers = res.WizardCatalog.brokers or "[]"
        templates = res.WizardCatalog.templates or "[]"
    end
    open_window{
        component = "new_service", size = "560 700", decorations = false,
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            selected_project_id = pid,
            project_name = ctx.project_name or "",
            new_service_start = start or "",
            new_service_databases = dbs,
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

function new_service_kind(k: string): ()
    if k == "application" then
        ctx.new_service_step = "app_form"
    elseif k == "compose" then
        ctx.new_service_step = "compose_form"
    elseif k == "database" then
        ctx.new_service_step = "pick_db"
    elseif k == "broker" then
        ctx.new_service_step = "pick_broker"
    elseif k == "template" then
        ctx.new_service_step = "pick_template"
    elseif k == "import" then
        ctx.new_service_step = "import_form"
    end
end

-- Banco escolhido: pré-preenche o formulário (senhas geradas no cliente).
function new_service_database(id: string): ()
    local ok, list = pcall(json.decode, ctx.new_service_databases or "[]")
    if not ok or type(list) ~= "table" then
        return
    end
    for _, d in ipairs(list) do
        if d.id == id then
            ctx.new_service_database_kind = id
            ctx.new_service_database_label = d.label
            ctx.new_service_image = d.image
            ctx.new_service_database_name = d.has_db_name and "app" or ""
            ctx.new_service_database_user = d.user or ""
            ctx.new_service_database_password = token_urlsafe(22)
            ctx.new_service_database_root_password = token_urlsafe(22)
            ctx.new_service_use_replica = "false"
            ctx.new_service_expose_external = "false"
            ctx.new_service_database_has_dbname = d.has_db_name and "true" or "false"
            ctx.new_service_database_has_user = d.has_user and "true" or "false"
            ctx.new_service_database_has_rootpw = d.has_rootpw and "true" or "false"
            ctx.new_service_database_has_replica = d.has_replica and "true" or "false"
            ctx.new_service_name = ""
            ctx.new_service_step = "db_form"
            return
        end
    end
end

-- Broker escolhido: compartilha o passo db_form (mesmas chaves ns_db_*).
function new_service_broker(id: string): ()
    local ok, list = pcall(json.decode, ctx.new_service_brokers or "[]")
    if not ok or type(list) ~= "table" then
        return
    end
    for _, b in ipairs(list) do
        if b.id == id then
            ctx.new_service_database_kind = id
            ctx.new_service_database_label = b.label
            ctx.new_service_image = b.image
            ctx.new_service_database_name = ""
            ctx.new_service_database_user = b.user or ""
            ctx.new_service_database_password = token_urlsafe(22)
            ctx.new_service_database_root_password = ""
            ctx.new_service_use_replica = "false"
            ctx.new_service_expose_external = "false"
            ctx.new_service_database_has_dbname = "false"
            ctx.new_service_database_has_user = b.has_user and "true" or "false"
            ctx.new_service_database_has_rootpw = "false"
            ctx.new_service_database_has_replica = "false"
            ctx.new_service_name = ""
            ctx.new_service_step = "db_form"
            return
        end
    end
end

-- Template escolhido: carrega nome/slug + variáveis editáveis (do catálogo).
function new_service_pick_template(id: string): ()
    for _, t in ipairs(State.new_service_templates_all) do
        if t.id == id then
            ctx.new_service_template_id = id
            ctx.new_service_template_name = t.name
            ctx.new_service_name = t.slug or ""
            ctx.new_service_template_vars = (
                t.vars and #t.vars > 0
            ) and json.encode(t.vars) or "[]";

            for _, vv in ipairs(t.vars or {}) do
                ctx["new_service_template_variable_value_" .. vv.idx] = ""
            end
            ctx.new_service_step = "template_form"
            return
        end
    end
end

-- Busca do catálogo de templates (filtra o cache no cliente).
function new_service_template_search(v: string): ()
    ctx.new_service_template_search = v or ""
    local term = string.lower(v or "")
    local rows = {}
    for _, t in ipairs(State.new_service_templates_all) do
        if term == ""
            or string.find(string.lower(t.name or ""), term, 1, true)
            or string.find(string.lower(t.description or ""), term, 1, true)
        then
            table.insert(rows, t)
        end
    end
    ctx.new_service_templates = (#rows > 0) and json.encode(rows) or "[]"
end

function new_service_create(): ()
    local pid = ctx.selected_project_id or ""
    local api = State.api
    if pid == "" or not api then
        return
    end
    local step = ctx.new_service_step
    local kind, id
    if step == "app_form" then
        kind, id = "application", ""
    elseif step == "compose_form" then
        kind, id = "compose", ""
    elseif step == "db_form" then
        id = ctx.new_service_database_kind or ""
        kind = new_service_is_broker(id) and "broker" or "database"
    elseif step == "template_form" then
        kind, id = "template", ctx.new_service_template_id or ""
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
        local okv, vars = pcall(json.decode, ctx.new_service_template_vars or "[]")
        if okv and type(vars) == "table" then
            for _, vv in ipairs(vars) do
                table.insert(tvals, ctx["new_service_template_variable_value_" .. vv.idx] or "")
            end
        end
    end

    local req = {
        kind = kind,
        id = id,
        project_id = pid,
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
    local ok, res = api:rpc_checked{ WizardCreate = req }
    ctx.new_service_busy = ""
    if ok and res.Service then
        -- Sucesso: avisa a janela principal (que atualiza a grade de serviços do
        -- projeto aberto) e fecha esta janela do wizard.
        local disp = (name ~= "" and name) or Helpers.trim(ctx.new_service_app_name)
        broadcast("service_created", {
            project_id = pid,
            name = disp,
        })
        close_window()
    else
        ctx.new_service_message = ok and "resposta inesperada" or ("erro: " .. res)
        toast{ message = tostring(ok and "resposta inesperada do daemon" or res), kind = "error" }
    end
end
