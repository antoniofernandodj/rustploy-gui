--!strict
-- format/docker_cleanup.luau — resumo textual da limpeza automática de Docker
-- (Settings → Manutenção). Usado tanto ao carregar a tela (`DockerCleanupConfig`)
-- quanto ao vivo, quando `Event::DockerCleanupCompleted` chega (stream.luau).

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
    return LABELS[name] or name
end

-- `lr`: `DockerCleanupLastRun?` (`{ at, results: { { resource, count,
-- reclaimed_bytes, error } } }`). `nil` = nunca rodou.
function M.last_run_summary(last_run: any): string
    if last_run == nil then
        return "ainda não rodou"
    end
    local total_bytes = 0
    local parts = {}
    local any_error = false
    for _, result in ipairs(last_run.results or {}) do
        total_bytes = total_bytes + (result.reclaimed_bytes or 0)
        if result.error ~= nil then
            any_error = true
            table.insert(parts, M.resource_label(result.resource) .. ": erro")
        else
            table.insert(parts, M.resource_label(result.resource) .. " " .. tostring(result.count or 0))
        end
    end
    local head = Time.date_day_month_hour_minute_second(last_run.at) .. " · " .. Time.format_bytes(total_bytes) .. " liberados"
    if #parts == 0 then
        return head
    end
    local suffix = " (" .. table.concat(parts, ", ") .. ")"
    if any_error then
        suffix = suffix .. " — alguns recursos falharam, ver logs do daemon"
    end
    return head .. suffix
end

return M
