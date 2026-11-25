--!strict
--!nolint FunctionUnused
-- handlers/routes.luau — rotas próprias na tela Ingress
-- (home/ingress.component.gv): lista, editor num painel e apagar. Uma rota
-- serve um domínio por vários serviços (por caminho), redireciona ou pede
-- senha. Ver docs/arquivo/plano-releases-ambientes-rotas-volumes.md §3.

local State = require("../state")

local M = {}

-- As rotas do último RouteList, por id (o editor parte delas).
local routes_by_id: { [string]: any } = {}
-- As linhas de caminho do editor aberto.
local rule_rows: { any } = {}

local function service_name(service_id: string): string
    local snap = State.snap
    for _, pair in ipairs((snap and snap.services) or {}) do
        if pair.service.id == service_id then
            return pair.service.spec.name
        end
    end
    return service_id
end

local function project_options(): { any }
    local options = {}
    local snap = State.snap
    for _, project in ipairs((snap and snap.projects) or {}) do
        table.insert(options, { id = project.id, name = project.name })
    end
    return options
end

local function service_options(project_id: string): { any }
    local options = {}
    local snap = State.snap
    for _, pair in ipairs((snap and snap.services) or {}) do
        if pair.service.spec.project_id == project_id then
            table.insert(
                options,
                { id = pair.service.id, name = pair.service.spec.name }
            )
        end
    end
    return options
end

-- Um campo de linha do `each` lê o valor de uma chave do ctx (não do item):
-- cada linha ganha as suas (`route_rule_<n>_*`) e o item leva o NOME delas
-- (`bind_*`), como em handlers/env_rows.luau.
local function publish_rules(): ()
    local rows = {}
    for index, rule in ipairs(rule_rows) do
        local base = "route_rule_" .. tostring(index)
        ctx[base .. "_path"] = rule.path_prefix
        ctx[base .. "_service"] = rule.service_id
        ctx[base .. "_port"] = rule.port
        ctx[base .. "_strip"] = rule.strip_prefix == true
        table.insert(rows, {
            index = tostring(index),
            bind_path = base .. "_path",
            bind_service = base .. "_service",
            bind_port = base .. "_port",
            bind_strip = base .. "_strip",
            can_remove = #rule_rows > 1 and "1" or "0",
        })
    end
    ctx.route_form_rules = json.array(rows)
end

local function target_label(route: any): string
    if route.action.Redirect then
        local redirect = route.action.Redirect
        return "↪ "
            .. redirect.to
            .. (redirect.permanent and " (301)" or " (302)")
    end
    local parts = {}
    for _, rule in ipairs((route.action.Forward and route.action.Forward.rules) or {}) do
        local part = rule.path_prefix .. " → " .. service_name(rule.service_id)
        if rule.port then
            part = part .. ":" .. tostring(rule.port)
        end
        if rule.strip_prefix then
            part = part .. i18n.tr(" (sem prefixo)")
        end
        table.insert(parts, part)
    end
    return table.concat(parts, " · ")
end

function M.load(): ()
    local api = State.api
    if not api then
        return
    end
    local list_ok, list_response = api:rpc("RouteList")
    local rows = {}
    routes_by_id = {}
    if list_ok and list_response.Routes then
        for _, route in ipairs(list_response.Routes) do
            routes_by_id[route.id] = route
            table.insert(rows, {
                id = route.id,
                domain = route.domain,
                target = target_label(route),
                tls = route.tls and "TLS ✓" or "TLS —",
                auth = route.basic_auth and i18n.tr("senha") or "",
            })
        end
    end
    ctx.custom_routes = json.array(rows)
    ctx.custom_routes_count = tostring(#rows)
end

local function open_editor(route: any?): ()
    ctx.route_project_options = json.array(project_options())
    ctx.route_editor_error = ""
    if route == nil then
        local options = project_options()
        local project_id = options[1] and options[1].id or ""
        ctx.route_editor_title = i18n.tr("Nova rota")
        ctx.route_form_id = ""
        ctx.route_form_project_id = project_id
        ctx.route_form_domain = ""
        ctx.route_form_tls = true
        ctx.route_form_mode = "forward"
        ctx.route_form_to = ""
        ctx.route_form_permanent = true
        ctx.route_form_auth_enabled = false
        ctx.route_form_auth_user = ""
        ctx.route_form_auth_password = ""
        ctx.route_form_had_password = "0"
        rule_rows = {
            { path_prefix = "/", service_id = "", port = "", strip_prefix = false },
        }
    else
        ctx.route_editor_title = i18n.tr("Editar rota")
        ctx.route_form_id = route.id
        ctx.route_form_project_id = route.project_id
        ctx.route_form_domain = route.domain
        ctx.route_form_tls = route.tls == true
        ctx.route_form_mode = route.action.Redirect and "redirect" or "forward"
        ctx.route_form_to = route.action.Redirect and route.action.Redirect.to or ""
        ctx.route_form_permanent = (
            route.action.Redirect == nil or route.action.Redirect.permanent == true
        )
        ctx.route_form_auth_enabled = route.basic_auth ~= nil
        ctx.route_form_auth_user = route.basic_auth and route.basic_auth.user or ""
        ctx.route_form_auth_password = ""
        ctx.route_form_had_password = route.basic_auth and "1" or "0"
        rule_rows = {}
        for _, rule in ipairs((route.action.Forward and route.action.Forward.rules) or {}) do
            table.insert(rule_rows, {
                path_prefix = rule.path_prefix,
                service_id = rule.service_id,
                port = rule.port and tostring(rule.port) or "",
                strip_prefix = rule.strip_prefix == true,
            })
        end
        if #rule_rows == 0 then
            rule_rows = {
                { path_prefix = "/", service_id = "", port = "", strip_prefix = false },
            }
        end
    end
    ctx.route_service_options =
        json.array(service_options(ctx.route_form_project_id or ""))
    publish_rules()
    ctx.route_editor_open = "1"
end

function route_new(): ()
    open_editor(nil)
end

function route_edit(route_id: string): ()
    local route = routes_by_id[route_id]
    if route then
        open_editor(route)
    end
end

function route_editor_close(): ()
    ctx.route_editor_open = "0"
end

function route_form_project_change(value: string): ()
    ctx.route_form_project_id = value or ""
    ctx.route_service_options = json.array(service_options(value or ""))
    for _, rule in ipairs(rule_rows) do
        rule.service_id = ""
    end
    publish_rules()
end

function route_form_mode_forward(): ()
    ctx.route_form_mode = "forward"
end

function route_form_mode_redirect(): ()
    ctx.route_form_mode = "redirect"
end

function route_rule_add(): ()
    table.insert(
        rule_rows,
        { path_prefix = "", service_id = "", port = "", strip_prefix = false }
    )
    publish_rules()
end

function route_rule_remove(index_text: string): ()
    local index = tonumber(index_text)
    if index and rule_rows[index] and #rule_rows > 1 then
        table.remove(rule_rows, index)
        publish_rules()
    end
end

local function rule_at(index_text: string): any
    return rule_rows[tonumber(index_text) or 0]
end

-- Durante a digitação só o estado local muda: republicar a lista a cada tecla
-- recriaria os inputs e tiraria o foco.
function route_rule_path(index_text: string, value: string): ()
    local rule = rule_at(index_text)
    if rule then
        rule.path_prefix = value or ""
        ctx["route_rule_" .. index_text .. "_path"] = rule.path_prefix
    end
end

function route_rule_service(index_text: string, value: string): ()
    local rule = rule_at(index_text)
    if rule then
        rule.service_id = value or ""
        publish_rules()
    end
end

function route_rule_port(index_text: string, value: string): ()
    local rule = rule_at(index_text)
    if rule then
        rule.port = value or ""
        ctx["route_rule_" .. index_text .. "_port"] = rule.port
    end
end

function route_rule_strip(index_text: string, value: any): ()
    local rule = rule_at(index_text)
    if rule then
        rule.strip_prefix = value == true or value == "true"
        publish_rules()
    end
end

function route_save(): ()
    local api = State.api
    if not api then
        return
    end
    local action: any
    if ctx.route_form_mode == "redirect" then
        action = {
            Redirect = {
                to = (ctx.route_form_to or ""):match("^%s*(.-)%s*$"),
                permanent = ctx.route_form_permanent == true
                    or ctx.route_form_permanent == "true",
            },
        }
    else
        local rules = {}
        for _, rule in ipairs(rule_rows) do
            table.insert(rules, {
                path_prefix = (rule.path_prefix or ""):match("^%s*(.-)%s*$"),
                service_id = rule.service_id,
                port = tonumber(rule.port),
                strip_prefix = rule.strip_prefix == true,
            })
        end
        action = { Forward = { rules = json.array(rules) } }
    end
    local auth_enabled = ctx.route_form_auth_enabled == true
        or ctx.route_form_auth_enabled == "true"
    local route: any = {
        id = ctx.route_form_id or "",
        project_id = ctx.route_form_project_id or "",
        domain = (ctx.route_form_domain or ""):match("^%s*(.-)%s*$"),
        tls = ctx.route_form_tls == true or ctx.route_form_tls == "true",
        action = action,
    }
    if auth_enabled then
        local password = ctx.route_form_auth_password or ""
        -- Senha vazia numa edição = manter a gravada (o campo `password` some do
        -- JSON, que o daemon lê como `None`).
        route.basic_auth = {
            user = (ctx.route_form_auth_user or ""):match("^%s*(.-)%s*$"),
            password = password ~= "" and password or nil,
        }
    end
    local save_ok, save_response = api:rpc_checked { RouteSave = { route = route } }
    if save_ok then
        toast {
            message = string.format(i18n.tr("rota %s salva"), route.domain),
            kind = "success",
        }
        ctx.route_editor_open = "0"
        M.load()
    else
        ctx.route_editor_error = tostring(save_response)
    end
end

function route_delete(route_id: string): ()
    local route = routes_by_id[route_id]
    if not route then
        return
    end
    local confirmed = confirm {
        title = string.format(i18n.tr("Apagar a rota de %s?"), route.domain),
        message = i18n.tr(
            "O domínio passa a responder 404 até outra rota ou serviço assumi-lo."
        ),
        confirm_label = i18n.tr("Apagar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local api = State.api
    if not api then
        return
    end
    local delete_ok, delete_response =
        api:rpc_checked { RouteDelete = { route_id = route_id } }
    if delete_ok then
        toast {
            message = string.format(i18n.tr("rota %s apagada"), route.domain),
            kind = "success",
        }
        M.load()
    else
        toast { message = tostring(delete_response), kind = "error" }
    end
end

return M
