--!strict
--!nolint FunctionUnused
-- handlers/nav.luau — navegação da sidebar/tabs e busca do topbar.

local State = require("../state")
local Stream = require("stream")
local Registry = require("registry")

local function goto_view(view: string): ()
    ctx.view = view
    ctx.selected_service = ""
end

function nav_deployments(): ()
    goto_view("deployments")
end

function nav_deploy_engine(): ()
    goto_view("deploy_engine")
    if (ctx.deploy_engine_tab or "") == "" then
        ctx.deploy_engine_tab = "fila"
    end
end

function nav_monitoring(): ()
    goto_view("monitoring")
end

function nav_schedules(): ()
    goto_view("schedules")
end

function nav_ingress(): ()
    goto_view("ingress")
end

function nav_docker(): ()
    goto_view("docker")
end

function nav_projects(): ()
    ctx.selected_project_id = ""
    goto_view("projects")
end

function nav_settings(): ()
    goto_view("settings")
    ctx.settings_tab = "web"
    -- Defaults do form de conexão Git (destaca a aba certa e o método OAuth).
    if (ctx.git_provider_kind or "") == "" then
        ctx.git_provider_kind = "gitea"
    end
    if (ctx.git_provider_mode or "") == "" then
        ctx.git_provider_mode = "oauth"
    end
end

function nav_support(): ()
    goto_view("support")
end


-- Genérico p/ NavItem que usa action="nav" com value=target (se algum usar).
function nav(view: string?): () 
    if view then
        goto_view(view)
    end
end


-- Abas (TabButton dispara `project_tab:services`, `docker_tab:images`, …).
function project_tab(tab_name: string): ()
    ctx.project_tab = tab_name
end

function docker_tab(tab_name: string): ()
    ctx.docker_tab = tab_name
    if tab_name == "registry" then
        Registry.refresh_tokens()
    end
end

function deploy_engine_tab(tab_name: string): ()
    ctx.deploy_engine_tab = tab_name
end

function deploy_tab(tab_name: string): ()
    ctx.deploy_tab = tab_name
end


-- Abas do service detail e do healthcheck kind.
function tab(tab_name: string): ()
    ctx.tab = tab_name
end

function prov(tab_name: string): ()
    ctx.provider_tab = tab_name
end

-- Órfão desde que a aba virou <tabbar>: a barra grava `service_form_healthcheck_kind` sozinha.
-- function hckind(k: string): ()
--     ctx.service_form_healthcheck_kind = k
-- end


-- Setter genérico de campo (on_change="field:<chave>").
function field(key: string?, value: string?): ()
    if key then
        ctx[key] = value or ""
    end
end


function search_changed(search_text: string): ()
    ctx.search = search_text or ""
    State.search_term = string.lower(search_text or "")
    Stream.rebuild_lists()
    Stream.update_open_project()
end
