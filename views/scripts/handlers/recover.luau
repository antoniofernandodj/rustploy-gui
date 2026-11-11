--!strict
--!nolint FunctionUnused
-- handlers/recover.luau — Settings → Recuperar: recuperar este servidor a partir do git + chave de recuperação +
-- backups no S3 (docs/plano-backup-de-dados-para-s3.md, Fase 4). A webui faz o mesmo em `webui/app.js`
-- (`recover*`): mude os dois juntos.
--
-- A chave e o token só vivem no campo: somem ao enviar, deem certo ou não, e nunca ficam em outro lugar do `ctx`.

local State = require("../state")
local Helpers = require("../helpers")

local M = {}

local POLL_MS = 3000
local poll_timer: any = nil

local STEP_LABELS: { [string]: string } = {
    pending = "aguardando",
    restoring = "restaurando dados",
    starting = "subindo",
    ready = "pronto",
    blocked = "bloqueado",
    failed = "falhou",
}

--- O rótulo de uma etapa. A tradução acontece aqui, no ponto de uso (e não numa tabela de módulo).
function M.step_label(step: string): string
    local source = STEP_LABELS[step]
    if source == nil then
        return step
    end
    return i18n.tr(source)
end

--- A linha de um serviço na tela, a partir do que o daemon devolveu. Pura (recebe o rótulo de cada coisa).
function M.service_row(service: any): { [string]: string }
    local backup = if service.latest_backup ~= nil
        then i18n.tr("backup de ") .. tostring(service.latest_backup)
        else i18n.tr("sem backup: sobe vazio")
    local step = M.step_label(tostring(service.step))
    if service.error ~= nil then
        step = step .. ": " .. tostring(service.error)
    end
    return {
        kind = if service.kind == "database" then "BD" else "VOL",
        who = tostring(service.project) .. " / " .. tostring(service.name),
        backup = backup,
        step = step,
    }
end

local function apply(info: any): ()
    ctx.recover_phase = tostring(info.phase or "idle")
    ctx.recover_projects = tostring(info.projects or 0)
    ctx.recover_destination_error = info.destination_error or ""
    ctx.recover_message = info.message or ""
    local rows = json.array {}
    for _, service in ipairs(info.services or {}) do
        table.insert(rows, M.service_row(service))
    end
    ctx.recover_services = rows
    ctx.recover_services_count = tostring(#rows)
end

--- Lê em que ponto a recuperação está e, enquanto roda, repolla.
function M.load(): ()
    if poll_timer then
        poll_timer:cancel()
        poll_timer = nil
    end
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("ServerRecoverStatus")
    if ok and type(response) == "table" and response.ServerRecover ~= nil then
        apply(response.ServerRecover)
    end
    if ctx.recover_phase == "running" and ctx.settings_tab == "recover" then
        poll_timer = after(POLL_MS, function(): ()
            poll_timer = nil
            M.load()
        end)
    end
end

function recover_refresh(): ()
    M.load()
end

--- Passo 1: traz a infra do git, recifra os segredos e lista o que foi achado. Não toca em dado.
function recover_start(): ()
    local api = State.api
    if not api then
        return
    end
    local branch = Helpers.trim(ctx.recover_branch)
    local ok, response = api:rpc_checked {
        ServerRecoverStart = {
            remote = Helpers.trim(ctx.recover_remote),
            token = Helpers.trim(ctx.recover_token),
            branch = if branch ~= "" then branch else nil,
            recovery_key = Helpers.trim(ctx.recover_key),
        },
    }
    -- a chave e o token saem da tela, deu certo ou não
    ctx.recover_key = ""
    ctx.recover_token = ""
    if ok and type(response) == "table" and response.ServerRecover ~= nil then
        apply(response.ServerRecover)
        toast {
            message = tostring(
                i18n.tr("infraestrutura restaurada; confira o resumo")
            ),
            kind = "success",
        }
    else
        toast { message = tostring(response), kind = "error" }
    end
end

--- Passo 2: restaura os dados e sobe os serviços na ordem das dependências (em segundo plano).
function recover_run(): ()
    local api = State.api
    if not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Restaurar os dados e subir?"),
        message = i18n.tr(
            "Cada serviço tem os dados restaurados do S3 (volumes antes de subir, bancos depois) e sobe na ordem das dependências."
        ),
        confirm_label = i18n.tr("Restaurar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response = api:rpc_checked("ServerRecoverRun")
    if ok then
        toast {
            message = tostring(i18n.tr("recuperação iniciada")),
            kind = "success",
        }
        M.load()
    else
        toast { message = tostring(response), kind = "error" }
    end
end

function recover_cancel(): ()
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("ServerRecoverCancel")
    if ok and type(response) == "table" and response.ServerRecover ~= nil then
        apply(response.ServerRecover)
        toast {
            message = tostring(i18n.tr("recuperação cancelada")),
            kind = "success",
        }
    else
        toast { message = tostring(response), kind = "error" }
    end
end

return M
