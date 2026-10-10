--!strict
--!nolint FunctionUnused
-- handlers/stream.luau — consumidor do SSE de /api/events: aplica o snapshot
-- periódico (2s) e os eventos vivos do bus (métricas, logs, deploy). Exporta
-- open_stream/rebuild_lists/update_open_project/refresh_now para os demais
-- handlers (login, busca, abrir projeto, mutações que refletem na hora).

local State = require("../state")
local fmt = require("../fmt")
local Api = require("../net/api")
local Services = require("services")

local M = {}

-- Reconstrói as listas filtradas pela busca a partir do último snapshot — sem
-- rede, para a busca filtrar na hora (equivalente ao antigo search_pairs).
local function rebuild_lists(): ()
    local snap = State.snap
    if not snap then
        return
    end
    local term = State.search_term
    ctx.deployments = fmt.deployments(snap.deployments, term)
    ctx.projects = fmt.projects(snap.projects, State.last_pairs, term)
    ctx.project_rows = fmt.project_rows(snap.projects, State.last_pairs, term)
    ctx.services = fmt.services(State.last_pairs, State.metrics_by_id, term)
    ctx.service_rows = fmt.service_rows(State.last_pairs, State.metrics_by_id, term)
    -- ctx.docker_rows: a antiga sub-aba Containers (só serviços rustploy) foi
    -- substituída pela lista host-wide (docker_containers). fmt.docker_rows fica
    -- disponível para reuso; não recalculamos aqui à toa.
    -- ctx.docker_rows = fmt.docker_rows(State.last_pairs, term)
    ctx.docker_containers = fmt.docker_containers(snap.docker_containers, term)
    ctx.docker_images = fmt.docker_images(
        snap.docker_images, term, ctx.docker_images_only_used == "true")
    ctx.docker_volumes = fmt.docker_volumes(
        snap.docker_volumes, term, ctx.docker_volumes_only_used == "true")
    ctx.docker_networks = fmt.docker_networks(
        snap.docker_networks, term, ctx.docker_networks_only_used == "true")
    ctx.registry_repos = fmt.registry_repos(snap.registry_repos, term)
end
M.rebuild_lists = rebuild_lists

-- Cabeçalho + grade de serviços do projeto aberto (view=project_services).
local function update_open_project(): ()
    local snap = State.snap
    if not snap then
        return
    end
    local project_id = ctx.selected_project_id or ""
    if project_id == "" then
        return
    end
    local found_project
    for _, project in ipairs(snap.projects or {}) do
        if project.id == project_id then
            found_project = project;
            break
        end
    end
    if not found_project then
        return
    end
    local project_pairs = {}
    for _, last_pair in ipairs(State.last_pairs) do
        if last_pair.svc.spec.project_id == project_id then
            table.insert(project_pairs, last_pair)
        end
    end
    ctx.project_name = found_project.name
    ctx.project_description = found_project.description or ""
    ctx.project_can_delete = (#project_pairs == 0) and "1" or "0"
    ctx.project_loading = "false"
    ctx.project_services = fmt.service_rows(
        project_pairs,
        State.metrics_by_id,
        State.search_term
    )
    -- Variáveis de ambiente do projeto (aba "Variáveis (N)"). Sem isto, a aba
    -- nasce "Variáveis ()" até a primeira edição.
    local project_env_vars = found_project.env_vars or {}
    local project_comments = found_project.env_comments or {}
    ctx.project_env = fmt.env_json_with_comments(project_env_vars, project_comments)
    ctx.project_env_count = tostring(#project_env_vars)
    -- O snapshot chega ~1x/s; se reescrevêssemos project_env_text (o value do
    -- textarea) toda vez, o que o usuário digita seria resetado. Só
    -- ressincroniza o editor .env quando ele está fechado.
    if ctx.project_env_text_open ~= "true" then
        local project_dotenv = fmt.env_dotenv_with_comments(project_env_vars, project_comments)
        ctx.project_env_text = project_dotenv
        ctx.project_env_text_original = project_dotenv
    end

    -- Aba "Secrets (N)": só os nomes — `projects[].secrets` vem do snapshot
    -- (ver http_api.rs::snapshot), nunca o valor. A mesma lista alimenta os
    -- chips de "usar secret" da aba Variáveis.
    local secrets = found_project.secrets or {}
    ctx.project_secrets = fmt.secret_rows(secrets)
    ctx.project_secrets_count = tostring(#secrets)

    -- Aba "Jobs (N)": jobs deste projeto (filtrados do `msg.jobs` global —
    -- já busca tudo a cada snapshot, sem RPC extra).
    local project_jobs = {}
    for _, job in ipairs(snap.jobs or {}) do
        if job.job.project_id == project_id then
            table.insert(project_jobs, job)
        end
    end
    local jobs_json, jobs_count = fmt.job_summaries(project_jobs, State.jobs_inflight)
    ctx.project_jobs = jobs_json
    ctx.project_jobs_count = tostring(jobs_count)
end

M.update_open_project = update_open_project

-- Recomputa SÓ `ctx.jobs_summary`/`ctx.jobs_count` (tela global "Schedules")
-- a partir do último snapshot em cache — sem RPC. Chamada por
-- handlers/jobs.luau::job_run_now logo após tocar `State.jobs_inflight`,
-- pra o botão desabilitar na hora, sem esperar o round-trip do
-- `JobRunNow`/`refresh_now()`.
local function refresh_jobs_summary_local(): ()
    local snap = State.snap
    if not snap then
        return
    end
    local jobs_summary, jobs_count = fmt.job_summaries(snap.jobs, State.jobs_inflight)
    ctx.jobs_summary = jobs_summary
    ctx.jobs_count = tostring(jobs_count)
end
M.refresh_jobs_summary_local = refresh_jobs_summary_local

local function refresh_deploy_engine_detail(active: {any}?): ()
    local detail_deployment_id = (ctx :: any).deploy_engine_detail_id
    if detail_deployment_id == nil or detail_deployment_id == "" then
        return
    end
    for _, info in ipairs(active or {}) do
        if info.service_id == detail_deployment_id then
            ctx.deploy_engine_detail_title = info.service_name
            ctx.deploy_engine_detail_steps = fmt.deploy_engine_detail_steps(info)
            ctx.deploy_engine_detail_rows = fmt.deploy_engine_detail(info)
            return
        end
    end
    ctx.deploy_engine_detail_id = ""
    ctx.deploy_engine_detail_open = "false"
end
M.refresh_deploy_engine_detail = refresh_deploy_engine_detail

local function apply_snapshot(snapshot: any): ()
    State.snap = snapshot
    State.last_pairs = fmt.pair_list(snapshot.services)

    -- Status do daemon.
    local daemon_status = snapshot.status
    if daemon_status then
        ctx.daemon_version = daemon_status.version or ""
        ctx.daemon_uptime = fmt.fmt_uptime(daemon_status.uptime_secs)
        ctx.services_running = tostring(daemon_status.services_running or 0)
        ctx.services_total = tostring(daemon_status.services_total or 0)
        ctx.services_label = (
            tostring(daemon_status.services_running or 0) .. "/" .. tostring(daemon_status.services_total or 0)
        )
    end

    -- Deploy Engine (inline, não filtrado pela busca).
    local engine = snapshot.engine
    if engine then
        ctx.deploy_engine_active_count = tostring(#(engine.active or {}))
        ctx.deploy_engine_success_24h = tostring(engine.successful_24h or 0)
        ctx.deploy_engine_failed_24h = tostring(engine.failed_24h or 0)
        ctx.deploy_engine_total_24h = tostring(engine.total_24h or 0)
        ctx.deploy_engine_uptime = fmt.fmt_uptime(engine.uptime_secs)
        ctx.deploy_engine_active = fmt.deploy_engine_active(engine.active)
        M.refresh_deploy_engine_detail(engine.active)
        ctx.deploy_engine_recent = fmt.deploy_engine_recent(engine.recent)
        ctx.deploy_engine_recent_count = tostring(#(engine.recent or {}))
        -- Fila global (um por vez): itens esperando + estado pausado.
        ctx.deploy_engine_queued = fmt.deploy_engine_queued(engine.queued)
        ctx.deploy_engine_queued_count = tostring(#(engine.queued or {}))
        ctx.deploy_engine_paused = (engine.paused and "true" or "false")

        -- Timer decorrido do deploy em voo do serviço aberto (granularidade de
        -- 2s — sem timer no Luau, vem do próprio snapshot; ver o plano de
        -- migração). O desfecho terminal vem por DeployStateChanged (apply_bus).
        if
            State.deploy_track.running and
            ctx.selected_service == State.deploy_track.service_id
        then
            for _, active_deployment in ipairs(engine.active or {}) do
                if active_deployment.service_id == State.deploy_track.service_id then
                    ctx.service_deploy_running = "true"
                    ctx.service_deploy_elapsed = fmt.fmt_secs(active_deployment.elapsed_secs)
                    break
                end
            end
        end
    end

    -- Contagens.
    ctx.deployments_count = tostring(#(snapshot.deployments or {}))
    ctx.projects_count = tostring(#(snapshot.projects or {}))
    ctx.services_count = tostring(#State.last_pairs)
    ctx.docker_images_count = tostring(#(snapshot.docker_images or {}))
    ctx.docker_volumes_count = tostring(#(snapshot.docker_volumes or {}))
    ctx.docker_networks_count = tostring(#(snapshot.docker_networks or {}))
    ctx.docker_containers_count = tostring(#(snapshot.docker_containers or {}))

    -- Registry OCI embutido: status/config vem sempre; tags de um repo
    -- específico são buscadas sob demanda (ver handlers/registry.luau), não
    -- fazem parte do snapshot.
    local registry_status = snapshot.registry_status
    if registry_status then
        ctx.registry_status_enabled = tostring(registry_status.enabled)
        ctx.registry_host = (registry_status.domain and registry_status.domain ~= "") and registry_status.domain or ("127.0.0.1:" .. tostring(registry_status.port))
        ctx.registry_status_label = registry_status.enabled and ("ativo em " .. ctx.registry_host) or "desabilitado"
        ctx.registry_storage_human = fmt.fmt_bytes(registry_status.storage_bytes or 0)
    end
    ctx.registry_repos_count = tostring(#(snapshot.registry_repos or {}))

    -- Ingress + Monitoring (não filtrados pela busca).
    local ingress, ingress_count = fmt.ingress(State.last_pairs)
    ctx.ingress = ingress
    ctx.ingress_count = tostring(ingress_count)
    local host_ports, host_ports_count = fmt.host_ports(State.last_pairs)
    ctx.host_ports = host_ports
    ctx.host_ports_count = tostring(host_ports_count)
    ctx.monitoring = fmt.monitoring(State.last_pairs, State.metrics_by_id)

    -- Jobs one-shot (tela global "Schedules"): guarda o Job cru por id
    -- (job_toggle precisa do compose/name/main_service completos pra
    -- reenviar o JobUpdate) e formata as linhas de exibição.
    local jobs_by_id = {}
    for _, job in ipairs(snapshot.jobs or {}) do
        jobs_by_id[job.job.id] = job.job
    end
    State.jobs_by_id = jobs_by_id
    local jobs_summary, jobs_count = fmt.job_summaries(snapshot.jobs, State.jobs_inflight)
    ctx.jobs_summary = jobs_summary
    ctx.jobs_count = tostring(jobs_count)

    rebuild_lists()
    update_open_project()
    ctx.data_loading = "false"
end

-- Refresh imediato após uma mutação: pega o snapshot completo num único RPC (o
-- mesmo builder do SSE) e aplica, para a tela refletir na hora sem esperar o
-- tick de 2s. Chamado pelos handlers de criar/remover projeto/serviço.
local function refresh_now(): ()
    local api = State.api
    if not api then
        return
    end
    local snapshot_ok, snapshot_response = api:rpc("Snapshot")
    if snapshot_ok and snapshot_response.Snapshot then
        local json_decode_ok, decoded = pcall(json.decode, snapshot_response.Snapshot)
        if json_decode_ok and type(decoded) == "table" then
            apply_snapshot(decoded)
        end
    end
end
M.refresh_now = refresh_now

-- Limpeza em massa da tela Deployments: apaga (DeployDelete) todo deployment
-- em estado terminal Stopped/Failed do último snapshot recebido — em
-- andamento (Live e os estados intermediários) nunca são tocados, e o próprio
-- handler do daemon recusa apagar um deployment não-terminal como segunda
-- trava.
function deployments_clear_finished(): ()
    local confirmed = confirm{
        title = "Limpar deployments parados/falhos?",
        message = "Remove do histórico todo deployment em estado Stopped ou Failed, e seus build logs. Deployments em andamento não são afetados. Ação irreversível.",
        confirm_label = "Limpar",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    local snap = State.snap
    if not api or not snap then
        return
    end
    local deployment_ids = {}
    for _, deployment in ipairs(snap.deployments or {}) do
        local deployment_info = deployment.deployment
        if deployment_info and (deployment_info.state == "Stopped" or deployment_info.state == "Failed") then
            table.insert(deployment_ids, deployment_info.id)
        end
    end
    if #deployment_ids == 0 then
        ctx.deployments_message = "nada para limpar"
        return
    end
    ctx.deployments_message = string.format("removendo %d deployment(s)…", #deployment_ids)
    local removed = 0
    local failed = 0
    for _, deployment_id in ipairs(deployment_ids) do
        local deleted = api:rpc_checked{ DeployDelete = { deployment_id = deployment_id } }
        if deleted then
            removed = removed + 1
        else
            failed = failed + 1
        end
    end
    if failed == 0 then
        ctx.deployments_message = string.format("%d removido(s)", removed)
    else
        ctx.deployments_message = string.format("%d removido(s), %d falharam", removed, failed)
        toast{
            message = tostring(
                string.format("%d deployment(s) não puderam ser removidos", failed)
            ),
            kind = "error"
        }
    end
    refresh_now()
end


-- Eventos vivos do bus: métricas e transições de deploy. Logs (runtime/build)
-- NÃO passam mais aqui — o daemon os tirou do firehose `/api/events` e os serve
-- por endpoints dedicados, consumidos só pelas janelas de log isoladas (ver
-- log_window.luau; open_logs_window / deployment_logs em handlers/services.luau). Assim
-- a janela principal não reprocessa (reavalia) sua árvore inteira por linha.
local function apply_bus(bus_event: any): ()
    -- Eventos unit-variant chegam como string JSON (ex.: "DeployQueueChanged"),
    -- não table — tratados antes do guard de table abaixo.
    if bus_event == "DeployQueueChanged" then
        -- A fila global mudou: busca um snapshot fresco na hora, sem esperar o
        -- tick de 2s.
        refresh_now()
        return
    end
    if type(bus_event) ~= "table" then
        return
    end
    if bus_event.DockerCleanupCompleted then
        -- Settings.luau não é `require`ado aqui de propósito: ele já requer
        -- este arquivo (`Stream = require("stream")`), e um require cíclico
        -- devolveria um módulo incompleto. Atualiza os 3 campos direto.
        local cleanup_event = bus_event.DockerCleanupCompleted
        ctx.docker_cleanup_running = "false"
        ctx.docker_cleanup_last_run_text = fmt.docker_cleanup_last_run_summary({
            at = cleanup_event.at, results = cleanup_event.results
        })
        State.docker_cleanup_last_run_at_raw = cleanup_event.at
    elseif bus_event.ContainerMetrics then
        local container_metrics = bus_event.ContainerMetrics
        if container_metrics.service_id then
            State.metrics_by_id[container_metrics.service_id] = container_metrics
        end
    elseif bus_event.SystemMetrics then
        local system_metrics = bus_event.SystemMetrics
        ctx.host_cpu = string.format("%.0f%%", system_metrics.cpu_percent or 0)
        ctx.host_memory = (
            fmt.fmt_bytes(system_metrics.mem_used_bytes) .. " / " .. fmt.fmt_bytes(system_metrics.mem_total_bytes)
        )
        ctx.host_disk = (
            fmt.fmt_bytes(system_metrics.disk_used_bytes) .. " / " .. fmt.fmt_bytes(system_metrics.disk_total_bytes)
        )
        ctx.host_load = string.format(
            "%.2f %.2f %.2f",
            system_metrics.load_avg_1 or 0,
            system_metrics.load_avg_5 or 0,
            system_metrics.load_avg_15 or 0
        )
    elseif bus_event.DeployStateChanged then
        local deploy_event = bus_event.DeployStateChanged
        if deploy_event.service_id == State.deploy_track.service_id then
            local terminal = deploy_event.state == "Live" or deploy_event.state == "Failed" or deploy_event.state == "Stopped"
            if terminal then
                State.deploy_track.running = false
                local live = deploy_event.state == "Live"
                -- Notificação NATIVA DO SO no desfecho: o usuário disparou o deploy
                -- e provavelmente foi fazer outra coisa — o toast (dentro da janela)
                -- não seria visto. Emitida sempre, independente da tela/serviço
                -- selecionado (por isso fora do gate de selected_service abaixo).
                -- app_name = "Rustploy" (não o nome do binário "rustploy-gui"): há
                -- desktops (ex.: certos GNOME/extensões) que descartam a notificação
                -- quando o app_name casa com um .desktop instalado — o nome de
                -- exibição evita isso. Ver glacier-ui 0.43 e docs/notificacao-so.md.
                local service_name = State.deploy_track.name
                if service_name == "" then
                    service_name = "serviço"
                end
                -- `d.message` é o MOTIVO da falha (o texto do Docker, o
                -- healthcheck que não passou…). O evento sempre o carregou; era
                -- este consumidor que o descartava, e a notificação dizia só
                -- "Failed" — o usuário ficava sem hipótese nenhuma. Ver
                -- docs/plano-erro-de-deploy-invisivel.md.
                local failure_reason = fmt.short_reason(deploy_event.message)
                if live then
                    notify{
                        title = "Deploy concluído",
                        body = service_name .. " está no ar e recebendo tráfego.",
                        app_name = "Rustploy",
                        icon = "rustploy-gui",
                    }
                else
                    notify{
                        title = "Deploy falhou",
                        body = (
                            failure_reason ~= ""
                                and (service_name .. ": " .. failure_reason)
                                or (service_name .. ": " .. tostring(deploy_event.state) .. ".")
                        ),
                        app_name = "Rustploy",
                        icon = "rustploy-gui",
                    }
                    -- Toast além da notificação do SO: quem está com a janela
                    -- aberta olhando o deploy não recebe notificação em alguns
                    -- desktops, e é justamente quem mais quer ver o motivo.
                    toast{
                        message = service_name .. ": " .. (
                            failure_reason ~= "" and failure_reason or ("deploy " .. tostring(deploy_event.state))
                        ),
                        kind = "error",
                    }
                end
                if deploy_event.service_id == ctx.selected_service then
                    ctx.service_deploy_running = "false"
                    ctx.service_action_message = (
                        live and "deploy concluído"
                            or (
                                failure_reason ~= ""
                                    and ("deploy falhou: " .. failure_reason)
                                    or ("deploy: " .. tostring(deploy_event.state))
                            )
                    )
                    ctx.service_action_color = live and "#3FB950" or "#F85149"
                    Services.fetch_service_detail(deploy_event.service_id)
                end
            elseif deploy_event.service_id == ctx.selected_service then
                ctx.service_deploy_running = "true"
                ctx.service_action_message = "deploy · " .. tostring(deploy_event.state)
                ctx.service_action_color = "#58A6FF"
            end
        end
    end
end

-- Abre a conexão SSE (chamado por connect(), em handlers/connection.luau,
-- após a autenticação inicial dar certo). Os callbacks vão inline: cada um é
-- usado num lugar só, e a assinatura dos três continua conferida contra o que o
-- motor entrega sem precisar anotar variável nenhuma — `glacier.d.luau` declara
-- `sse(url, opts: StreamOptions?)`, então é a própria chamada que checa a
-- tabela literal contra `StreamOptions`.

function M.open_stream(): ()
    if State.state_conn then
        return
    end

    local sse_url = ctx.api_url .. "/api/events"

    State.state_conn = sse(sse_url, {
        -- Cada evento SSE traz um `data:` JSON auto-descritivo com `kind`.
        -- Nota: o firehose /api/events não manda mais `bus_batch` (era só p/
        -- logs, que saíram daqui — ver apply_bus). Os lotes de log vivem no
        -- endpoint dedicado consumido pela janela isolada (log_window.luau).
        headers = Api.auth_headers(ctx.api_token),

        on_message = function(data: string): ()
            local json_decode_ok, decoded = pcall(json.decode, data)
            if not json_decode_ok or type(decoded) ~= "table" then
                return
            end
            if decoded.kind == "snapshot" then
                apply_snapshot(decoded)
            elseif decoded.kind == "bus" then
                apply_bus(decoded.event)
            end
        end,

        on_error = function(error_message: string): ()
            ctx.status_line = "stream: " .. tostring(error_message)
        end,

        on_close = function(): ()
            State.state_conn = nil
            if ctx.connected == "true" then
                ctx.status_line = "conexão encerrada"
                ctx.connected = "false"
                ctx.screen = "login"
            end
        end,
    })
end

return M
