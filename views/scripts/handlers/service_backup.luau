--!strict
--!nolint FunctionUnused
-- handlers/service_backup.luau — aba Dados → "Backup no S3": os backups dos dados do serviço no S3
-- (docs/plano-backup-de-dados-para-s3.md, Fase 2). O backup e a restauração rodam em segundo plano no
-- daemon; aqui só se dispara e se acompanha `ServiceBackupList(.last_run)` a cada 3 s enquanto roda.
-- A webui faz o mesmo em `webui/screens/service_detail.js` (`loadBackups`…): mude os dois juntos.

local State = require("../state")
local Helpers = require("../helpers")
local format = require("../format")

local M = {}

local POLL_MS = 3000
local poll_timer: any = nil

function M.reset(): ()
    if poll_timer then
        poll_timer:cancel()
        poll_timer = nil
    end
    ctx.data_backups = json.array {}
    ctx.data_backups_count = "0"
    ctx.data_backup_blocked = ""
    ctx.data_backup_list_error = ""
    ctx.data_backup_run_label = ""
    ctx.data_backup_checks = ""
    ctx.data_backup_running = "false"
    ctx.data_backup_ready = "false"
    ctx.data_backup_enabled = "false"
    ctx.data_backup_kind = "daily"
    ctx.data_backup_hours = "6"
    ctx.data_backup_time = "03:00"
    ctx.data_backup_weekday = "0"
    ctx.data_backup_keep = "7"
    ctx.data_backup_stop = "true"
    ctx.data_backup_next = ""
end

--- Uma linha para a última operação: "backup · concluído 11/11 10:00:05 (3 MB)" / "· falhou: …".
function M.run_label(run: any): string
    if run == nil then
        return ""
    end
    local what = if run.op == "restore"
        then i18n.tr("restauração")
        else i18n.tr("backup")
    if run.state == "running" then
        return what .. " · " .. i18n.tr("em andamento…")
    end
    if run.state == "failed" then
        return what
            .. " · "
            .. i18n.tr("falhou: ")
            .. tostring(run.error or "")
    end
    local size = ""
    if run.size_bytes ~= nil then
        size = " (" .. format.format_bytes(run.size_bytes) .. ")"
    end
    local finished = format.date_time_full(run.finished_at)
    return what .. " · " .. i18n.tr("concluído") .. " " .. finished .. size
end

--- O formulário (valores em texto, como moram no `ctx`) a partir da política do daemon. Pura.
function M.form_from_policy(policy: any): { [string]: string }
    local form = {
        enabled = tostring(policy ~= nil and policy.enabled == true),
        keep = tostring((policy and policy.keep) or 7),
        stop = tostring(policy == nil or policy.stop ~= false),
        kind = "daily",
        hours = "6",
        time = "03:00",
        weekday = "0",
    }
    local rec = policy and policy.recurrence
    if rec ~= nil and rec.IntervalHours ~= nil then
        form.kind = "interval"
        form.hours = tostring(rec.IntervalHours)
    elseif rec ~= nil and rec.Weekly ~= nil then
        form.kind = "weekly"
        form.weekday = tostring(rec.Weekly.weekday)
        form.time = format.hour_minute_join(rec.Weekly.hour, rec.Weekly.minute)
    elseif rec ~= nil and rec.Daily ~= nil then
        form.time = format.hour_minute_join(rec.Daily.hour, rec.Daily.minute)
    end
    return form
end

--- O `BackupPolicy` do protocolo (horário em UTC) a partir dos valores do formulário. Pura.
function M.policy_from_values(form: { [string]: string }): any
    local recurrence: any
    if form.kind == "interval" then
        recurrence = { IntervalHours = math.max(1, tonumber(form.hours) or 1) }
    else
        local hour, minute = format.hour_minute_split(form.time)
        if form.kind == "weekly" then
            recurrence = {
                Weekly = {
                    weekday = tonumber(form.weekday) or 0,
                    hour = hour,
                    minute = minute,
                },
            }
        else
            recurrence = { Daily = { hour = hour, minute = minute } }
        end
    end
    return {
        enabled = Helpers.is_true(form.enabled),
        recurrence = recurrence,
        keep = math.max(1, tonumber(form.keep) or 7),
        stop = not Helpers.is_false(form.stop),
    }
end

local function fill_form(policy: any): ()
    local form = M.form_from_policy(policy)
    ctx.data_backup_enabled = form.enabled
    ctx.data_backup_keep = form.keep
    ctx.data_backup_stop = form.stop
    ctx.data_backup_kind = form.kind
    ctx.data_backup_hours = form.hours
    ctx.data_backup_time = form.time
    ctx.data_backup_weekday = form.weekday
end

local function policy_from_form(): any
    return M.policy_from_values({
        enabled = ctx.data_backup_enabled,
        kind = ctx.data_backup_kind,
        hours = ctx.data_backup_hours,
        time = ctx.data_backup_time,
        weekday = ctx.data_backup_weekday,
        keep = ctx.data_backup_keep,
        stop = ctx.data_backup_stop,
    })
end

local function apply(list: any, fill: boolean): ()
    local rows = json.array {}
    for _, entry in ipairs(list.entries or {}) do
        table.insert(rows, {
            key = entry.key,
            when = format.date_time_full(entry.last_modified),
            size = format.format_bytes(entry.size_bytes),
        })
    end
    ctx.data_backups = rows
    ctx.data_backups_count = tostring(#rows)
    ctx.data_backup_blocked = list.blocked or ""
    ctx.data_backup_list_error = list.list_error or ""
    ctx.data_backup_run_label = M.run_label(list.last_run)
    ctx.data_backup_checks =
        table.concat((list.last_run and list.last_run.checks) or {}, "\n")
    ctx.data_backup_running = (
        list.last_run ~= nil and list.last_run.state == "running"
    )
            and "true"
        or "false"
    ctx.data_backup_ready = "true"
    ctx.data_backup_next = if list.next_run_at ~= nil
        then format.date_time_full(list.next_run_at)
        else ""
    if fill then
        fill_form(list.policy)
    end
end

--- Lê os backups e a última operação; enquanto roda (e a aba segue aberta) repolla.
function M.load(fill: boolean?): ()
    if poll_timer then
        poll_timer:cancel()
        poll_timer = nil
    end
    local api = State.api
    local service_id = ctx.selected_service or ""
    if not api or service_id == "" then
        return
    end
    local ok, response =
        api:rpc_checked { ServiceBackupList = { service_id = service_id } }
    if not ok or type(response) ~= "table" or not response.ServiceBackups then
        return
    end
    apply(response.ServiceBackups, fill == true)
    if ctx.data_backup_running == "true" and ctx.tab == "dados" then
        poll_timer = after(POLL_MS, function(): ()
            poll_timer = nil
            if (ctx.selected_service or "") == service_id then
                M.load(false)
            end
        end)
    end
end

function service_backup_refresh(): ()
    M.load(false)
end

function service_backup_now(): ()
    local api = State.api
    local service_id = ctx.selected_service or ""
    if not api or service_id == "" then
        return
    end
    local ok, response =
        api:rpc_checked { ServiceBackupNow = { service_id = service_id } }
    if ok then
        toast {
            message = tostring(i18n.tr("backup iniciado")),
            kind = "success",
        }
        M.load()
    else
        toast { message = tostring(response), kind = "error" }
    end
end

function service_backup_policy_save(): ()
    local api = State.api
    local service_id = ctx.selected_service or ""
    if not api or service_id == "" then
        return
    end
    local ok, response = api:rpc_checked {
        ServiceBackupPolicySet = {
            service_id = service_id,
            policy = M.policy_from_form(),
        },
    }
    if ok and response.ServiceBackups ~= nil then
        apply(response.ServiceBackups, true)
        toast {
            message = tostring(i18n.tr("política de backup salva")),
            kind = "success",
        }
    else
        toast { message = tostring(response), kind = "error" }
    end
end

function service_backup_restore(key: string): ()
    local api = State.api
    local service_id = ctx.selected_service or ""
    if not api or service_id == "" or key == "" then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Restaurar o backup?"),
        message = i18n.tr(
            "Isto SUBSTITUI os dados atuais do serviço pelo backup escolhido."
        ),
        confirm_label = i18n.tr("Restaurar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response = api:rpc_checked {
        ServiceBackupRestore = {
            service_id = service_id,
            key = key,
            confirm = true,
        },
    }
    if ok then
        toast {
            message = tostring(i18n.tr("restauração iniciada")),
            kind = "success",
        }
        M.load()
    else
        toast { message = tostring(response), kind = "error" }
    end
end

function service_backup_delete(key: string): ()
    local api = State.api
    local service_id = ctx.selected_service or ""
    if not api or service_id == "" or key == "" then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Apagar o backup?"),
        message = i18n.tr("Ação irreversível."),
        confirm_label = i18n.tr("Apagar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response = api:rpc_checked {
        ServiceBackupDelete = { service_id = service_id, key = key },
    }
    if ok then
        toast { message = tostring(i18n.tr("backup apagado")), kind = "success" }
        M.load()
    else
        toast { message = tostring(response), kind = "error" }
    end
end

return M
