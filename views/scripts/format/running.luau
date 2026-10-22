--!strict
-- format/running.luau — painel "Em execução". O recorte (só projetos e
-- serviços rodando) e a classificação por tipo vêm prontos do daemon em
-- `snapshot.dashboard` (api/http/dashboard.rs); aqui só se formata para a
-- tela.

local Time = require("time")
local Util = require("util")
local Jobs = require("jobs")

local M = {}

-- Cards por linha: dois, para o painel caber meio a meio na tela.
local COLUMNS = 2

-- Agrupa os cards em linhas de COLUMNS; a última é completada com espaçadores
-- (`filler = "1"`) para os cards não esticarem (glacier não tem grid).
local function in_rows(services: { any }): { any }
    local rows = {}
    for row_start = 1, #services, COLUMNS do
        local cards = {}
        local last_card = math.min(row_start + COLUMNS - 1, #services)
        for card_index = row_start, last_card do
            table.insert(cards, services[card_index])
        end
        while #cards < COLUMNS do
            local filler = {}
            for key in pairs(services[1]) do
                filler[key] = ""
            end
            filler.filler = "1"
            table.insert(cards, filler)
        end
        table.insert(rows, { cards = cards })
    end
    return rows
end

-- `https://host/webhook/<id>/<token>` → `https://host/webhook/<id>/••••••••`.
function M.mask_webhook(url: string): string
    local masked = string.gsub(url, "/[^/]*$", "/••••••••")
    return masked
end

-- Linha especializada por tipo: o que importa de cada um num relance.
local function detail_line(service: any): string
    if service.kind == "git" then
        return tostring(service.repo_url or "")
    elseif service.kind == "registry" then
        return "imagem: " .. tostring(service.image or "")
    elseif service.kind == "database" or service.kind == "broker" then
        return string.format(
            "motor: %s · porta %s",
            tostring(service.engine or "?"),
            tostring(service.port)
        )
    end
    return ""
end

local function checks_text(checks: { any }): string
    if #checks == 0 then
        return "nenhum"
    end
    local lines = {}
    for check_index, check in ipairs(checks) do
        table.insert(
            lines,
            string.format("%d. %s", check_index, tostring(check.name))
        )
    end
    return table.concat(lines, "\n")
end

local function matches(term: string?, texts: { string }): boolean
    return Util.matches(term, texts)
end

-- `dashboard`: `snapshot.dashboard`. `metrics`: service_id →
-- ContainerMetricsPoint. `revealed`: service_id → true quando o usuário pediu
-- para ver o token do webhook.
function M.running(
    dashboard: any,
    metrics: { [string]: any }?,
    term: string?,
    revealed: { [string]: boolean }?
): (string, number)
    local projects = {}
    local total = 0
    for _, project in ipairs(dashboard or {}) do
        local project_matches = matches(term, { project.project_name })
        local services = {}
        for _, service in ipairs(project.services) do
            if project_matches or matches(term, { service.name }) then
                local metrics_point = metrics and metrics[service.service_id]
                local warm = service.warm
                local warm_label, warm_color = "", "muted"
                if warm ~= nil then
                    warm_label, warm_color = Jobs.warm_status(warm)
                end
                local is_revealed = revealed ~= nil
                    and revealed[service.service_id] == true
                local webhook = service.webhook
                local degraded = service.status == "Degraded"
                local domains = table.concat(service.domains, ", ")
                table.insert(services, {
                    filler = "0",
                    id = service.service_id,
                    name = service.name,
                    port = tostring(service.port),
                    status_label = degraded and "degradado" or "rodando",
                    status_color = degraded and "#D29922" or "#3FB950",
                    kind_label = service.kind_label,
                    branch = service.branch or "",
                    detail = detail_line(service),
                    domains = domains == "" and ""
                        or ("domínio: " .. domains),
                    cpu = metrics_point and string.format(
                        "%.1f%%",
                        metrics_point.cpu_percent or 0
                    ) or "—",
                    mem = metrics_point
                            and Time.format_bytes(metrics_point.mem_used_bytes)
                        or "—",
                    checks = checks_text(service.pre_deploy_checks),
                    has_webhook = webhook ~= nil and "true" or "false",
                    webhook = webhook or "",
                    webhook_shown = webhook ~= nil
                            and (is_revealed and webhook or M.mask_webhook(
                                webhook
                            ))
                        or "sem webhook",
                    reveal_label = is_revealed and "Ocultar" or "Mostrar",
                    has_warm = warm ~= nil and "true" or "false",
                    warm_label = warm_label,
                    warm_color = warm_color,
                })
            end
        end
        if #services > 0 then
            total = total + #services
            table.insert(projects, {
                project_id = project.project_id,
                project_name = project.project_name,
                count_label = string.format(
                    "%d %s",
                    #services,
                    #services == 1 and "serviço" or "serviços"
                ),
                rows = in_rows(services),
            })
        end
    end
    return Util.encode_array(projects), total
end

return M
