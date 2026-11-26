--!strict
-- format/docker_cleanup.luau — resumo textual da limpeza automática de Docker
-- (Settings → Manutenção). Usado tanto ao carregar a tela
-- (`DockerCleanupConfig`) quanto ao vivo, quando
-- `Event::DockerCleanupCompleted` chega (stream.luau).

local Time = require("time")

local M = {}

local LABELS: { [string]: string } = {
    containers = "containers",
    images = "imagens",
    volumes = "volumes",
    networks = "redes",
    build_cache = "cache de build",
}

function M.resource_label(name: string): string
    return i18n.tr(LABELS[name] or name)
end

-- `lr`: `DockerCleanupLastRun?` (`{ at, results: { { resource, count,
-- reclaimed_bytes, error } } }`). `nil` = nunca rodou.
function M.last_run_summary(last_run: any): string
    if last_run == nil then
        return i18n.tr("ainda não rodou")
    end
    local total_bytes = 0
    local parts = {}
    local any_error = false
    for _, result in ipairs(last_run.results or {}) do
        total_bytes = total_bytes + (result.reclaimed_bytes or 0)
        if result.error ~= nil then
            any_error = true
            table.insert(
                parts,
                M.resource_label(result.resource) .. i18n.tr(": erro")
            )
        else
            table.insert(
                parts,
                M.resource_label(result.resource)
                    .. " "
                    .. tostring(result.count or 0)
            )
        end
    end
    local head = Time.date_day_month_hour_minute_second(last_run.at)
        .. " · "
        .. Time.format_bytes(total_bytes)
        .. " liberados"
    if #parts == 0 then
        return head
    end
    local suffix = " (" .. table.concat(parts, ", ") .. ")"
    if any_error then
        suffix = suffix
            .. i18n.tr(" — alguns recursos falharam, ver logs do daemon")
    end
    return head .. suffix
end

-- ── Lista "aquecer depois da limpeza" (Command::WarmAfterCleanupTargets) ──

-- Linhas da lista da Manutenção: um cabeçalho por projeto (`kind = "project"`)
-- e, embaixo, cada serviço e job dele (`kind = "item"`), na ordem do daemon.
-- `pending`: id → escolha ainda não salva, que vence a do daemon. Devolve a
-- tabela (o handler liga cada checkbox a uma chave do ctx antes de codificar).
function M.warm_target_rows(targets: { any }?, pending: { [string]: boolean }?): { any }
    local rows = {}
    local current_project: string? = nil
    for _, target in ipairs(targets or {}) do
        if target.project_id ~= current_project then
            current_project = target.project_id
            table.insert(rows, {
                kind = "project",
                id = "project:" .. tostring(target.project_id),
                label = tostring(target.project_name),
                checked = "false",
                pre_deploy = "false",
            })
        end
        local warm = target.warm == true
        if pending ~= nil and pending[target.id] ~= nil then
            warm = pending[target.id] :: boolean
        end
        local label = tostring(target.name)
        if target.kind == "Job" then
            label = i18n.tr("Job:") .. " " .. label
        end
        table.insert(rows, {
            kind = "item",
            id = tostring(target.id),
            label = label,
            checked = warm and "true" or "false",
            pre_deploy = target.pre_deploy == true and "true" or "false",
        })
    end
    return rows
end

-- O toggle da aba Advanced de um serviço: se ele está na lista (só serviço com
-- build está), o valor e se dá para escolher agora. `response`:
-- `WarmAfterCleanupTargets` (nil antes do primeiro load).
function M.service_warm_choice(response: any, service_id: string): { [string]: string }
    local target = nil
    for _, candidate in ipairs(response and response.targets or {}) do
        if candidate.id == service_id then
            target = candidate
            break
        end
    end
    local cleanup_enabled = response ~= nil and response.cleanup_enabled == true
    local warm_after = response ~= nil and response.warm_after_cleanup == true
    local editable = cleanup_enabled and warm_after
    local locked_reason = ""
    if not cleanup_enabled then
        locked_reason = i18n.tr(
            "A limpeza automática do Docker está desligada (Settings → Manutenção): não há o que aquecer depois dela."
        )
    elseif not warm_after then
        locked_reason = i18n.tr(
            "O aquecimento depois da limpeza está desligado em Settings → Manutenção."
        )
    end
    return {
        present = target ~= nil and "true" or "false",
        checked = (editable and target ~= nil and target.warm == true) and "true" or "false",
        editable = editable and "true" or "false",
        locked = editable and "false" or "true",
        locked_reason = locked_reason,
    }
end

return M
