--!strict
-- format/state_git.luau — a sincronização do estado com o git (Fases 6 e 7 de
-- docs/plano-backup-estado-em-git.md) vista pela GUI: o aviso do topo, os textos
-- da tela Settings → Sync, as listas "removidos no git" e "valores em claro", o
-- selo "mudança pendente de deploy" e o dono do container órfão. Tudo vem do
-- snapshot (`snapshot.state_git`, `snapshot.infra_audit`); nada aqui fala com a
-- rede. A webui faz o mesmo em `webui/app.js` (`stateGit*`) — mude os dois juntos.

local Time = require("time")
local Util = require("util")

local M = {}

type Status = {
    mode: string?,
    remote: string?,
    branch: string?,
    provider_id: string?,
    git_available: boolean?,
    recovery_configured: boolean?,
    last_commit: { sha: string, at: string, subject: string }?,
    last_push_ok: boolean?,
    last_push_at: string?,
    last_fetch_at: string?,
    last_error: string?,
    blocked_by_plaintext: number?,
    ahead: number?,
    behind: number?,
    paused_reason: string?,
    incoming_rejected: { sha: string, reason: string }?,
    removed_in_git: {
        {
            id: string,
            kind: string,
            name: string,
            project: string,
            sha: string,
            at: string,
        }
    }?,
    pending_deploy: { string }?,
}

local function short(sha: string?): string
    return string.sub(sha or "", 1, 7)
end

local function time_label(iso_timestamp: string?): string
    if iso_timestamp == nil or iso_timestamp == "" then
        return "—"
    end
    return Time.date_day_month_hour_minute_second(iso_timestamp)
end
M.time_label = time_label

-- Texto do aviso do topo, ou "" quando está tudo bem (nada a mostrar).
function M.alert_message(status: Status?): string
    if status == nil or status.mode == nil or status.mode == "off" then
        return ""
    end
    if status.paused_reason ~= nil and status.paused_reason ~= "" then
        return i18n.tr(
            "Sincronização com o git pausada: o histórico divergiu. Abra Settings → Sync."
        )
    end
    if status.incoming_rejected ~= nil then
        return string.format(
            i18n.tr(
                "Um commit do repositório foi recusado (%s). Abra Settings → Sync."
            ),
            short(status.incoming_rejected.sha)
        )
    end
    if (status.blocked_by_plaintext or 0) > 0 then
        return string.format(
            i18n.tr(
                "Commits suspensos: %d valor(es) em claro. Abra Settings → Sync."
            ),
            status.blocked_by_plaintext or 0
        )
    end
    return ""
end

-- Conjunto de ids de serviço com "mudança pendente de deploy".
function M.pending_ids(status: Status?): { [string]: boolean }
    local ids = {}
    if status ~= nil then
        for _, service_id in ipairs(status.pending_deploy or {}) do
            ids[service_id] = true
        end
    end
    return ids
end

-- Linhas da lista "Removidos no git" (JSON): quem sumiu e quando.
function M.removed_rows(status: Status?): string
    local rows = {}
    if status ~= nil then
        for _, removal in ipairs(status.removed_in_git or {}) do
            local detail: string = removal.kind
            if removal.project ~= nil and removal.project ~= "" then
                detail = detail .. " · " .. removal.project
            end
            detail = detail
                .. " · "
                .. short(removal.sha)
                .. " · "
                .. time_label(removal.at)
            table.insert(
                rows,
                { id = removal.id, name = removal.name, detail = detail }
            )
        end
    end
    return Util.encode_array(rows)
end

-- Linhas da auditoria de valores em claro (JSON). Nunca traz valores. `index`
-- (1-based) identifica o item para os handlers de "não é segredo".
function M.audit_rows(findings: { any }?): string
    local rows = {}
    for index, finding in ipairs(findings or {}) do
        local kind: string = finding.definite and i18n.tr("certeza")
            or i18n.tr("suspeita")
        local scope: string = tostring(finding.scope or "")
        local project: string = tostring(finding.project or "")
        local detail: string = kind
        if scope ~= "" then
            detail = scope .. " · " .. kind
        end
        if project ~= "" then
            detail = project .. " · " .. detail
        end
        table.insert(rows, {
            index = tostring(index),
            what = finding.what or "",
            detail = detail,
            can_allow = (not finding.definite and not finding.allowed) and "1"
                or "0",
            can_block_again = (not finding.definite and finding.allowed)
                    and "1"
                or "0",
        })
    end
    return Util.encode_array(rows)
end

-- Dono de um container na lista Runtime: o órfão ("removido no git") é dito
-- como tal; senão projeto/serviço, "rustploy" (gerido) ou "—".
function M.container_owner(container: any): string
    local removed_in_git = container.removed_in_git
    if removed_in_git ~= nil and removed_in_git ~= "" then
        return string.format(
            i18n.tr("removido no git (%s)"),
            tostring(removed_in_git)
        )
    end
    if container.project and container.service then
        return tostring(container.project)
            .. " / "
            .. tostring(container.service)
    end
    if container.managed then
        return "rustploy"
    end
    return "—"
end

-- Todos os valores de ctx que a tela precisa, calculados do status. Booleanos
-- viram "true"/"false" (o ctx do glacier só guarda strings). `plain` = sem
-- `Util`/`i18n` quando não há status ainda.
function M.context(status: Status?, findings: { any }?): { [string]: string }
    local s: Status = status or {}
    local mode = s.mode or "off"
    local last_commit = s.last_commit
    local push_label = "—"
    if s.last_push_at ~= nil and s.last_push_at ~= "" then
        push_label = (s.last_push_ok and i18n.tr("ok") or i18n.tr("falhou"))
            .. " · "
            .. time_label(s.last_push_at)
    end
    local flag = function(value: boolean): string
        return value and "true" or "false"
    end
    return {
        state_git_alert_message = M.alert_message(status),
        state_git_mode = mode,
        state_git_is_enabled = flag(mode ~= "off"),
        state_git_is_sync = flag(mode == "sync"),
        state_git_git_missing = flag(
            status ~= nil and s.git_available == false
        ),
        state_git_recovery_missing = flag(
            status ~= nil and s.recovery_configured == false
        ),
        state_git_last_commit_label = last_commit ~= nil and (short(
            last_commit.sha
        ) .. " · " .. last_commit.subject) or "—",
        state_git_last_push_label = push_label,
        state_git_last_fetch_label = time_label(s.last_fetch_at),
        state_git_ahead_behind_label = tostring(s.ahead or 0)
            .. " / "
            .. tostring(s.behind or 0),
        state_git_last_error = s.last_error or "",
        state_git_paused_reason = s.paused_reason or "",
        state_git_is_paused = flag(
            s.paused_reason ~= nil and s.paused_reason ~= ""
        ),
        state_git_rejected_label = s.incoming_rejected ~= nil and (i18n.tr(
            "Commit"
        ) .. " " .. string.sub(s.incoming_rejected.sha, 1, 12)) or "",
        state_git_rejected_reason = s.incoming_rejected ~= nil
                and s.incoming_rejected.reason
            or "",
        state_git_has_rejected = flag(s.incoming_rejected ~= nil),
        state_git_removed = M.removed_rows(status),
        state_git_removed_count = tostring(#(s.removed_in_git or {})),
        state_git_audit = M.audit_rows(findings),
        state_git_audit_count = tostring(#(findings or {})),
    }
end

return M
