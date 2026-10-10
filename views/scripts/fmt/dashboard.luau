--!strict
-- fmt/dashboard.luau — builders de lista do dashboard (deployments/projects/
-- services/docker/ingress/monitoring/deploy engine), mesma forma JSON que
-- view.rs produzia. Iterado pelos ForEach dos templates via a fachada fmt.luau.

local Types = require("types")
type ServicePair = Types.ServicePair
type MetricsMap = Types.MetricsMap
type GridCard = Types.GridCard

local Time = require("time")
local Util = require("util")

local M = {}

-- Nº de colunas da grade de cards (services/projects). glacier não reestrutura
-- Row↔Column via @media, então o número de colunas tem que ser decidido aqui
-- (recalculado a cada snapshot, ~2s). O que importa é a largura que SOBRA para a
-- grade, não a da janela: a sidebar-gaveta (264) come espaço enquanto está aberta
-- (`ctx.menu`, o ☰ da topbar) e o `.content` tem padding lateral — contar só a
-- janela dava 3 colunas de ~235px numa janela de 1100px, e o card era esmagado
-- (o `name:`/`id:` do container quebrava em várias linhas). Cada card precisa de
-- CARD_MIN px; cabem os que couberem, entre 1 e 3.
local CARD_MIN = 350
local SIDEBAR = 264
local function grid_cols(): number
    local viewport_width = viewport().width
    local menu = (ctx :: any).menu
    local sidebar = if menu == "true" or menu == true then SIDEBAR else 0
    -- Mesmos breakpoints do app.gss: padding lateral do `.content` e vão entre cards.
    local horizontal_padding, card_gap = 64, 16
    if viewport_width < 560 then
        horizontal_padding, card_gap = 20, 10
    elseif viewport_width < 900 then
        horizontal_padding, card_gap = 36, 10
    end
    local available_width = viewport_width - sidebar - horizontal_padding
    local columns = math.floor((available_width + card_gap) / (CARD_MIN + card_gap))
    return math.max(1, math.min(3, columns))
end

-- Um card VAZIO que preenche a fileira do grid. Os campos vão como string
-- vazia, não `nil`: em Lua um campo `nil` não existe, e o card recebe o item
-- inteiro por `spread` — um campo ausente é uma prop obrigatória faltando, o
-- que o motor recusa. Como um filler serve às DUAS grades (serviços e
-- projetos), ele carrega a união dos dois contratos.
local FILLER: GridCard = {
    filler = "1",
    id = "",
    name = "",
    project = "",
    -- service_card.gvb
    port = "",
    status_label = "",
    status_color = "",
    cpu = "",
    mem = "",
    container_name = "",
    container_id = "",
    container_extra = "",
    -- project_card.gvb
    description = "",
    service_count = "",
    running_count = "",
    can_delete = "",
}

-- Deployments (aba Deployments). `list` = Vec<DeploymentSummary>.
-- Nomes truncados por Util.col_budgets (o filtro `matches` roda antes, sobre o
-- valor completo — a busca continua casando com o que foi cortado).
function M.deployments(deployments: {any}?, term: string?): string
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, deployment_entry in ipairs(deployments or {}) do
        if Util.matches(term, { deployment_entry.service_name, deployment_entry.project_name }) then
            local deployment = deployment_entry.deployment
            local label, _ = Util.state_label_color(deployment.state)
            table.insert(rows, {
                service = Util.ellipsis(deployment_entry.service_name, column_budgets.svc),
                project = Util.ellipsis(deployment_entry.project_name, column_budgets.proj),
                state_label = label,
                state_kind = Util.state_kind(deployment.state),
                duration = Time.fmt_duration(deployment),
                start = Time.date_dm_hms(deployment.started_at),
                start_iso = deployment.started_at or "", -- `sort_key` da coluna INÍCIO
            })
        end
    end
    return Util.enc_array(rows)
end

-- Escolhe o container "primário" de um serviço p/ exibir no card: o live, senão
-- o primeiro em execução, senão o primeiro da lista. Devolve (nome, id_curto,
-- extra) onde extra é "+N" quando há mais de um container.
local function primary_container(service: Types.Service): (string, string, string)
    local containers = service.containers or {}
    if #containers == 0 then return "—", "", "" end
    local chosen = containers[1]
    for _, container in ipairs(containers) do
        if service.live_container_id and container.id == service.live_container_id then chosen = container; break end
        if container.state == "running" and chosen.state ~= "running" then chosen = container end
    end
    local extra = #containers > 1 and string.format("+%d", #containers - 1) or ""
    return chosen.name or "—", string.sub(chosen.id or "", 1, 12), extra
end

-- Card de serviço (com CPU/mem mesclados de `metrics_by_id[svc.id]`).
local function service_card(service: Types.Service, project_name: string, metrics: MetricsMap?)
    local status_label, status_color = Util.status_label_color(service.status)
    local cpu, mem = "—", "—"
    local metrics_point = metrics and metrics[service.id]
    if metrics_point then
        cpu = string.format("%.1f%%", metrics_point.cpu_percent or 0)
        mem = Time.fmt_bytes(metrics_point.mem_used_bytes)
    end
    local container_name, container_id, container_extra = primary_container(service)
    return {
        filler = "0",
        id = service.id,
        name = service.spec.name,
        project = project_name,
        port = tostring(service.spec.port),
        status_label = status_label,
        status_color = status_color,
        cpu = cpu,
        mem = mem,
        container_name = container_name,
        container_id = container_id,
        container_extra = container_extra,
    }
end

-- Array plano de cards de serviço (para seleção/contagem).
function M.services(service_pairs: {ServicePair}, metrics: MetricsMap?, term: string?): string
    local rows = {}
    for _, pair in ipairs(service_pairs) do
        if Util.matches(term, { pair.svc.spec.name, pair.proj }) then
            table.insert(rows, service_card(pair.svc, pair.proj, metrics))
        end
    end
    return Util.enc_array(rows)
end

-- Cards de serviço em linhas de N colunas (grid_cols), com filler (glacier
-- não tem grid).
function M.service_rows(service_pairs: {ServicePair}, metrics: MetricsMap?, term: string?): string
    local filtered: {GridCard} = {}
    for _, pair in ipairs(service_pairs) do
        if Util.matches(term, { pair.svc.spec.name, pair.proj }) then
            table.insert(filtered, service_card(pair.svc, pair.proj, metrics))
        end
    end
    local columns = grid_cols()
    local rows = {}
    local row_start = 1
    while row_start <= #filtered do
        local cards = {}
        for card_index = row_start, math.min(row_start + columns - 1, #filtered) do
            table.insert(cards, filtered[card_index])
        end
        while #cards < columns do table.insert(cards, FILLER) end
        table.insert(rows, { cards = cards })
        row_start = row_start + columns
    end
    return Util.enc_array(rows)
end

-- Card de projeto, agregando contagem de serviços de `pairs_`.
local function project_card(project: any, service_pairs: {ServicePair})
    local count, running = 0, 0
    for _, pair in ipairs(service_pairs) do
        if pair.svc.spec.project_id == project.id then
            count = count + 1
            if pair.svc.status == "Running" then running = running + 1 end
        end
    end
    return {
        filler = "0",
        id = project.id,
        name = project.name,
        description = project.description or "",
        service_count = tostring(count),
        running_count = tostring(running),
        can_delete = (count == 0) and "1" or "0",
    }
end

function M.projects(projects: {any}?, service_pairs: {ServicePair}, term: string?): string
    local rows = {}
    for _, project in ipairs(projects or {}) do
        if Util.matches(term, { project.name, project.description or "" }) then
            table.insert(rows, project_card(project, service_pairs))
        end
    end
    return Util.enc_array(rows)
end

function M.project_rows(projects: {any}?, service_pairs: {ServicePair}, term: string?): string
    local filtered: {GridCard} = {}
    for _, project in ipairs(projects or {}) do
        if Util.matches(term, { project.name, project.description or "" }) then
            table.insert(filtered, project_card(project, service_pairs))
        end
    end
    local columns = grid_cols()
    local rows = {}
    local row_start = 1
    while row_start <= #filtered do
        local cards = {}
        for card_index = row_start, math.min(row_start + columns - 1, #filtered) do
            table.insert(cards, filtered[card_index])
        end
        while #cards < columns do table.insert(cards, FILLER) end
        table.insert(rows, { cards = cards })
        row_start = row_start + columns
    end
    return Util.enc_array(rows)
end

-- Linhas Docker (containers gerenciados) derivadas dos serviços, ordenadas.
function M.docker_rows(service_pairs: {ServicePair}, term: string?): string
    local sorted: {ServicePair} = {}
    for _, pair in ipairs(service_pairs) do table.insert(sorted, pair) end
    table.sort(sorted, function(left: ServicePair, right: ServicePair)
        return left.svc.spec.name < right.svc.spec.name
    end)
    local rows = {}
    for _, item in ipairs(sorted) do
        if Util.matches(term, { item.svc.spec.name, item.proj }) then
            local label, _ = Util.status_label_color(item.svc.status)
            local container_id = "—"
            if item.svc.live_container_id and item.svc.live_container_id ~= "" then
                container_id = string.sub(item.svc.live_container_id :: string, 1, 12)
            end
            table.insert(rows, {
                name = item.svc.spec.name,
                project = item.proj,
                image = Util.source_summary(item.svc.spec.source),
                container = container_id,
                status_label = label,
                status_kind = Util.status_kind(item.svc.status),
            })
        end
    end
    return Util.enc_array(rows)
end

-- `only_used`: o "Somente em uso" da aba — filtrado aqui porque a tabela
-- (tableview) desenha toda linha que recebe.
function M.docker_images(images: {any}?, term: string?, only_used: boolean?): string
    local column_budgets = Util.col_budgets()
    local sorted = {}
    for _, image in ipairs(images or {}) do table.insert(sorted, image) end
    table.sort(sorted, function(left: any, right: any)
        return table.concat(left.tags or {}, ",") < table.concat(right.tags or {}, ",")
    end)
    local rows = {}
    for _, image in ipairs(sorted) do
        local tags_text = table.concat(image.tags or {}, " ")
        local in_use = (image.containers or 0) > 0
        if Util.matches(term, { tags_text, image.project or "", image.service or "" })
            and (in_use or not only_used) then
            -- Trunca por caractere (não por palavra): uma tag sem espaços mais
            -- longa que a coluna estoura e sobrepõe as vizinhas (o Row não clipa
            -- filhos) — mesmo caso do sha256 em docker_containers.
            local tags = (#(image.tags or {}) == 0) and "<none>"
                or Util.ellipsis(table.concat(image.tags, ", "), column_budgets.svc)
            local image_id = image.id or ""
            image_id = string.gsub(image_id, "^sha256:", "")
            table.insert(rows, {
                id = string.sub(image_id, 1, 12),
                id_full = image_id, -- sem "sha256:" (o `:` quebraria a ação nome:sufixo)
                tags = tags,
                size = Time.fmt_bytes(image.size_bytes),
                -- Crus, para o `sort_key` da coluna: "1.2 GB" e "08/10 14:03"
                -- não ordenam como texto.
                size_bytes = image.size_bytes or 0,
                created_iso = image.created or "",
                created = Time.date_dm_hm(image.created),
                project = image.project or "—",
                service = image.service or "—",
                -- "PROJETO / SERVIÇO" já combinado e truncado pra col_proj (o
                -- template exibe {i.owner}; project/service ficam pra ações).
                owner = Util.ellipsis((image.project or "—") .. " / " .. (image.service or "—"), column_budgets.proj),
                in_use_label = in_use and "EM USO" or "SEM USO",
                in_use_kind = Util.in_use_kind(in_use),
            })
        end
    end
    return Util.enc_array(rows)
end

function M.docker_volumes(volumes: {any}?, term: string?, only_used: boolean?): string
    local column_budgets = Util.col_budgets()
    local sorted = {}
    for _, volume in ipairs(volumes or {}) do table.insert(sorted, volume) end
    table.sort(sorted, function(left: any, right: any) return left.name < right.name end)
    local rows = {}
    for _, item in ipairs(sorted) do
        if Util.matches(term, { item.name, item.driver }) and (item.in_use or not only_used) then
            table.insert(rows, {
                -- Nome truncado só pra exibição; a ação de remover usa v.name
                -- completo via `name_full`.
                name = Util.ellipsis(item.name, column_budgets.svc),
                name_full = item.name,
                driver = item.driver,
                mountpoint = item.mountpoint,
                size = (item.size_bytes and item.size_bytes >= 0) and Time.fmt_bytes(item.size_bytes) or "—",
                size_bytes = item.size_bytes or -1,
                in_use_label = item.in_use and "EM USO" or "SEM USO",
                in_use_kind = Util.in_use_kind(item.in_use),
            })
        end
    end
    return Util.enc_array(rows)
end

function M.docker_networks(networks: {any}?, term: string?, only_used: boolean?): string
    local column_budgets = Util.col_budgets()
    local sorted = {}
    for _, network in ipairs(networks or {}) do table.insert(sorted, network) end
    table.sort(sorted, function(left: any, right: any) return left.name < right.name end)
    local rows = {}
    for _, item in ipairs(sorted) do
        if Util.matches(term, { item.name, item.project or "" }) and (item.in_use or not only_used) then
            table.insert(rows, {
                name = Util.ellipsis(item.name, column_budgets.svc),
                id_full = item.id or "",
                driver = item.driver,
                scope = item.scope,
                project = Util.ellipsis(item.project or "—", column_budgets.proj),
                containers = tostring(item.container_count or 0),
                in_use_label = item.in_use and "EM USO" or "SEM USO",
                in_use_kind = Util.in_use_kind(item.in_use),
            })
        end
    end
    return Util.enc_array(rows)
end

-- Containers do host (DockerContainerInfo): todos, rodando + parados. `can_remove`
-- = "1" só nos parados (o Docker recusa remover um rodando sem force). `owner`
-- mostra projeto/serviço quando atribuído (label rustploy.service_id), senão
-- "rustploy" (managed) ou "—".
function M.docker_containers(containers: {any}?, term: string?): string
    local column_budgets = Util.col_budgets()
    local sorted = {}
    for _, container in ipairs(containers or {}) do table.insert(sorted, container) end
    table.sort(sorted, function(left: any, right: any) return (left.name or "") < (right.name or "") end)
    local rows = {}
    for _, item in ipairs(sorted) do
        if Util.matches(term, { item.name, item.image, item.state, item.project or "", item.service or "" }) then
            local label, kind = Util.container_state(item.state)
            local owner: string
            if item.project and item.service then
                owner = tostring(item.project) .. " / " .. tostring(item.service)
            elseif item.managed then
                owner = "rustploy"
            else
                owner = "—"
            end
            -- A referência da imagem vira `sha256:<digest>` quando a tag original
            -- some (imagem removida/reconstruída) — sem espaços, não quebra linha
            -- e, sem truncar, estoura a coluna e sobrepõe as vizinhas (o Row não
            -- clipa filhos). Tira o prefixo redundante (igual a docker_images) e
            -- trunca por caractere (Util.ellipsis, não por palavra).
            local image = item.image or "—"
            image = string.gsub(image, "^sha256:", "")
            table.insert(rows, {
                id_full = item.id or "",
                id = string.sub(item.id or "", 1, 12),
                name = Util.ellipsis(item.name or "—", column_budgets.svc),
                image = Util.ellipsis(image, column_budgets.img),
                owner = Util.ellipsis(owner, column_budgets.state),
                state_label = label,
                state_kind = kind,
                can_remove = Util.container_stopped(item.state) and "1" or "0",
            })
        end
    end
    return Util.enc_array(rows)
end

-- Ingress: uma linha por rota de domínio (não filtrado pela busca). Retorna (json, count).
function M.ingress(service_pairs: {ServicePair}): (string, number)
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, pair in ipairs(service_pairs) do
        local spec = pair.svc.spec
        local port = spec.port
        for _, route in ipairs(Util.domain_routes(spec)) do
            if route.domain and string.gsub(route.domain, "%s", "") ~= "" then
                local scheme = route.tls and "https" or "http"
                local route_port = route.port or port
                table.insert(rows, {
                    domain = Util.ellipsis(route.domain, column_budgets.svc),
                    url = scheme .. "://" .. route.domain,
                    service = Util.ellipsis(spec.name, column_budgets.proj),
                    project = pair.proj,
                    upstream = ":" .. tostring(route_port),
                    tls = route.tls and "TLS" or "—",
                })
            end
        end
    end
    return Util.enc_array(rows), #rows
end

-- Portas TCP de host: uma linha por serviço com `host_port` configurado —
-- exposição direta de porta TCP no host, independente das rotas HTTP de
-- domínio acima (um serviço pode ter as duas, só uma, ou nenhuma). Não
-- filtrado pela busca (mesma convenção de `M.ingress`).
function M.host_ports(service_pairs: {ServicePair}): (string, number)
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, pair in ipairs(service_pairs) do
        local spec = pair.svc.spec
        if spec.host_port ~= nil then
            table.insert(rows, {
                service = Util.ellipsis(spec.name, column_budgets.svc),
                project = Util.ellipsis(pair.proj, column_budgets.proj),
                host_port = tostring(spec.host_port),
                host_port_n = spec.host_port,
                container_port = tostring(spec.port),
            })
        end
    end
    table.sort(rows, function(left: any, right: any) return left.host_port_n < right.host_port_n end)
    return Util.enc_array(rows), #rows
end

-- Monitoring: uma linha por serviço COM métricas vivas.
function M.monitoring(service_pairs: {ServicePair}, metrics: MetricsMap?): string
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, pair in ipairs(service_pairs) do
        local metrics_point = metrics and metrics[pair.svc.id]
        if metrics_point then
            table.insert(rows, {
                name = Util.ellipsis(pair.svc.spec.name, column_budgets.svc),
                project = Util.ellipsis(pair.proj, column_budgets.proj),
                cpu = string.format("%.1f%%", metrics_point.cpu_percent or 0),
                mem = Time.fmt_bytes(metrics_point.mem_used_bytes),
                rx = Time.fmt_bytes(metrics_point.net_rx_bytes),
                tx = Time.fmt_bytes(metrics_point.net_tx_bytes),
                -- Crus, para o `sort_key` das colunas (o texto não ordena).
                cpu_n = metrics_point.cpu_percent or 0,
                mem_n = metrics_point.mem_used_bytes or 0,
                rx_n = metrics_point.net_rx_bytes or 0,
                tx_n = metrics_point.net_tx_bytes or 0,
            })
        end
    end
    return Util.enc_array(rows)
end

local DEPLOY_STEPS = {
    { label = "Fila", states = { "Pending" } },
    { label = "Checks", states = { "PreDeployCheck" } },
    { label = "Deps", states = { "ResolvingDeps" } },
    { label = "Obter", states = { "PullingImage", "CloningRepo", "BuildingImage", "ComposingUp" } },
    { label = "Staging", states = { "Staging" } },
    { label = "Health", states = { "HealthcheckPolling" } },
    { label = "Swap", states = { "SwappingIn", "Draining", "Promoting" } },
    { label = "Live", states = { "Live" } },
}

local STEP_ICON = { done = "✓ ", current = "● ", failed = "✕ ", pending = "○ " }

local function step_of(state: any): number
    for index, step in ipairs(DEPLOY_STEPS) do
        if table.find(step.states, state) then
            return index
        end
    end
    return 0
end

local function deploy_stepper(info: any): {any}
    local state = info.state
    local current_step = step_of(state)
    local failed = 0
    if state == "Live" or state == "Stopped" or state == "Pruning" then
        current_step = #DEPLOY_STEPS + 1
    elseif state == "Failed" or state == "RollingBack" then
        local log = info.states or {}
        for index = #log, 1, -1 do
            local step_index = step_of(log[index].from)
            if step_index > 0 then
                failed = step_index
                break
            end
        end
        current_step = failed
    end
    local out = {}
    for index, step in ipairs(DEPLOY_STEPS) do
        local status = "pending"
        if index == failed then
            status = "failed"
        elseif index < current_step then
            status = "done"
        elseif index == current_step then
            status = "current"
        end
        table.insert(out, { text = STEP_ICON[status] .. step.label, status = status })
    end
    return out
end

local function iso_epoch(iso_timestamp: string?): number
    local year_text, month_text, day_text, hour_text, minute_text, second_text = string.match(iso_timestamp or "", "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year_text then
        return 0
    end
    return os.time({
        year = tonumber(year_text),
        month = tonumber(month_text),
        day = tonumber(day_text),
        hour = tonumber(hour_text),
        min = tonumber(minute_text),
        sec = tonumber(second_text)
    } :: any)
end

function M.deploy_engine_detail(info: any): string
    local log = info.states or {}
    local rows = {}
    for index, transition in ipairs(log) do
        local last = index == #log
        local duration = "—"
        if index < #log then
            duration = Time.fmt_secs(math.max(0, iso_epoch(log[index + 1].at) - iso_epoch(transition.at)))
        elseif not (transition.to == "Failed" or transition.to == "Live" or transition.to == "Stopped") then
            duration = Time.fmt_secs(info.current_state_secs)
        end
        local kind = "ok"
        if transition.to == "Failed" then
            kind = "bad"
        elseif last and info.state == transition.to then
            kind = "info"
        end
        table.insert(rows, {
            label = transition.to,
            kind = kind,
            dur = duration,
            msg = Util.short_reason(transition.message)
        })
    end
    return Util.enc_array(rows)
end

function M.deploy_engine_detail_steps(info: any): string
    return Util.enc_array(deploy_stepper(info))
end

-- Deploy Engine: "Executando agora".
function M.deploy_engine_active(active: {any}?): string
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, info in ipairs(active or {}) do
        local label, _ = Util.state_label_color(info.state)
        table.insert(rows, {
            service = Util.ellipsis(info.service_name, column_budgets.svc),
            project = Util.ellipsis(info.project_name, column_budgets.proj),
            state_label = label,
            state_kind = Util.state_kind(info.state),
            steps = deploy_stepper(info),
            total = Time.fmt_secs(info.elapsed_secs),
            phase = Time.fmt_secs(info.current_state_secs),
            service_id = info.service_id,
        })
    end
    return Util.enc_array(rows)
end

-- Deploy Engine: "Na fila" (deploys esperando; o primeiro é o próximo a rodar).
-- Inclui deployment_id (para cancelar/promover) e uma posição 1-based.
function M.deploy_engine_queued(queued: {any}?): string
    local column_budgets = Util.col_budgets()
    local rows = {}
    for index, info in ipairs(queued or {}) do
        table.insert(rows, {
            deployment_id = info.deployment_id,
            pos = tostring(index),
            service = Util.ellipsis(info.service_name, column_budgets.svc),
            project = Util.ellipsis(info.project_name, column_budgets.proj),
        })
    end
    return Util.enc_array(rows)
end

-- Deploy Engine: "Histórico 24h".
function M.deploy_engine_recent(recent: {any}?): string
    local column_budgets = Util.col_budgets()
    local rows = {}
    for _, info in ipairs(recent or {}) do
        local label, _ = Util.state_label_color(info.state)
        local icon = "○"
        if info.state == "Live" then icon = "✓"
        elseif info.state == "Failed" then icon = "✕" end
        table.insert(rows, {
            icon = icon,
            service = Util.ellipsis(info.service_name, column_budgets.svc),
            project = Util.ellipsis(info.project_name, column_budgets.proj),
            state_label = label,
            state_kind = Util.state_kind(info.state),
            duration = Time.fmt_secs(info.elapsed_secs),
            start = Time.time_hms(info.started_at),
            -- Crus, para o `sort_key` das colunas DURAÇÃO e INÍCIO.
            elapsed_secs = info.elapsed_secs or 0,
            start_iso = info.started_at or "",
        })
    end
    return Util.enc_array(rows)
end

return M
