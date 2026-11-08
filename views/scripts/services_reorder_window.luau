--!strict
--!nolint FunctionUnused
-- services_reorder_window.luau — script da JANELA "Reordenar serviços", um motor
-- Glacier próprio e ISOLADO do app principal (aberto via open_window por
-- handlers/projects.luau::open_services_reorder_window, que semeia a conexão, o
-- projeto e a lista atual: reorder_items = JSON [{id, name}]).
--
-- O usuário arrasta as linhas (mesmo drag-and-drop das variáveis) e "Reordenar"
-- grava a ordem no daemon (ProjectServicesReorder → `service_order` do
-- project.yml); "Cancelar" só fecha.

local Api = require("net/api")

local function client(): Api.Client?
    local url = ctx.api_url or ""
    if url == "" then
        return nil
    end
    return Api.new(url, ctx.api_token)
end

-- Ordem em edição: lista de {id, name}.
local items: { any } = {}

local function render(): ()
    local rows = json.array {}
    for position, item in ipairs(items) do
        table.insert(rows, { id = item.id, name = item.name, index = tostring(position) })
    end
    ctx.reorder_rows = json.encode(rows)
end

function init(): ()
    local decode_ok, decoded = pcall(json.decode, ctx.reorder_items or "[]")
    items = (decode_ok and type(decoded) == "table") and decoded or {}
    ctx.reorder_error = ""
    ctx.reorder_busy = ""
    render()
end

-- Arraste: `reorder_json` é um JSON array de ids na nova ordem (o `reorder_key`
-- do foreach é `id`). Reescreve a lista para as linhas refluírem ao vivo.
function services_reorder_drag(reorder_json: string?): ()
    if not reorder_json then
        return
    end
    local decode_ok, ids = pcall(json.decode, reorder_json)
    if not decode_ok or type(ids) ~= "table" then
        return
    end
    local by_id: { [string]: any } = {}
    for _, item in ipairs(items) do
        by_id[item.id] = item
    end
    local reordered = {}
    for _, id in ipairs(ids) do
        if by_id[id] then
            table.insert(reordered, by_id[id])
            by_id[id] = nil
        end
    end
    -- Rede de segurança: o que o arraste não citou segue no fim.
    for _, item in ipairs(items) do
        if by_id[item.id] then
            table.insert(reordered, item)
        end
    end
    items = reordered
    render()
end

-- Botão "Reordenar": grava no daemon, avisa a janela principal e fecha.
function services_reorder_apply(): ()
    local api = client()
    if not api then
        ctx.reorder_error = i18n.tr("sem conexão — reabra a janela pelo app")
        return
    end
    local ids = json.array {}
    for _, item in ipairs(items) do
        table.insert(ids, item.id)
    end
    ctx.reorder_busy = "true"
    local reorder_ok, reorder_response = api:rpc_checked {
        ProjectServicesReorder = {
            project_id = ctx.reorder_project_id,
            service_ids = ids,
        },
    }
    ctx.reorder_busy = ""
    if not reorder_ok then
        ctx.reorder_error = "erro: " .. tostring(reorder_response)
        return
    end
    broadcast("services_reordered", { project_id = ctx.reorder_project_id })
    close_window()
end

-- Botão "Cancelar": fecha ESTA janela sem gravar.
function cancel(): ()
    close_window()
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções
-- já definidas.
require("busy").install(require("busy_actions"))
