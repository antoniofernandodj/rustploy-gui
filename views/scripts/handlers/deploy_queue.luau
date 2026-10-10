--!strict
--!nolint FunctionUnused
-- handlers/deploy_queue.luau — gerência da fila global de deploys (um por vez)
-- na tela Deploy Engine: cancelar/promover um item enfileirado, reordenar por
-- arraste e pausar/retomar a fila inteira. Tudo via os Commands do daemon; o
-- refresh vem do snapshot (o daemon publica DeployQueueChanged → refresh_now).

local State = require("../state")
local Stream = require("stream")

-- Cancela um deploy que ainda está esperando na fila (não começou). Reaproveita
-- o DeployAbort — no daemon ele remove da fila e devolve o serviço ao repouso.
function queue_cancel(deployment_id: string): ()
    local api = State.api
    if not api or not deployment_id or deployment_id == "" then
        return
    end
    local deploy_abort_ok, deploy_abort_response = api:rpc_checked{ DeployAbort = { deployment_id = deployment_id } }
    if deploy_abort_ok then
        toast{ message = tostring("Deploy removido da fila"), kind = "success" }
    else
        toast{ message = tostring(deploy_abort_response), kind = "error" }
    end
    Stream.refresh_now()
end

-- Move um deploy enfileirado para o topo da fila ("furar fila").
function queue_promote(deployment_id: string): ()
    local api = State.api
    if not api or not deployment_id or deployment_id == "" then
        return
    end
    local deploy_queue_promote_ok, deploy_queue_promote_response = api:rpc_checked{ DeployQueuePromote = { deployment_id = deployment_id } }
    if not deploy_queue_promote_ok then
        toast{ message = tostring(deploy_queue_promote_response), kind = "error" }
    end
    Stream.refresh_now()
end

-- Reordena a fila (arraste): `v` é um JSON array de deployment_ids na nova ordem
-- (mesma forma que o env_reorder — o `reorder_key` do foreach é deployment_id).
function queue_reorder(order_json: string?): ()
    local api = State.api
    if not api or not order_json then
        return
    end
    local json_decode_ok, order = pcall(json.decode, order_json)
    if not json_decode_ok or type(order) ~= "table" then
        return
    end
    local deploy_queue_reorder_ok, deploy_queue_reorder_response = api:rpc_checked{ DeployQueueReorder = { order = order } }
    if not deploy_queue_reorder_ok then
        toast{ message = tostring(deploy_queue_reorder_response), kind = "error" }
    end
    Stream.refresh_now()
end

-- Pausa/retoma a fila. `ctx.deploy_engine_paused` ("true"/"false") reflete o estado atual
-- vindo do snapshot; aqui só invertemos.
function queue_toggle_pause(): ()
    local api = State.api
    if not api then
        return
    end
    local paused = ctx.deploy_engine_paused ~= "true"
    local deploy_queue_pause_ok, deploy_queue_pause_response = api:rpc_checked{ DeployQueuePause = { paused = paused } }
    if deploy_queue_pause_ok then
        toast{ message = tostring(paused and "Fila pausada" or "Fila retomada"), kind = "success" }
    else
        toast{ message = tostring(deploy_queue_pause_response), kind = "error" }
    end
    Stream.refresh_now()
end

function deploy_engine_open_detail(service_id: string): ()
    local snap = State.snap
    ctx.deploy_engine_detail_id = service_id
    ctx.deploy_engine_detail_open = "true"
    Stream.refresh_deploy_engine_detail(snap and snap.engine and snap.engine.active)
end

function deploy_engine_close_detail(): ()
    ctx.deploy_engine_detail_id = ""
    ctx.deploy_engine_detail_open = "false"
end
