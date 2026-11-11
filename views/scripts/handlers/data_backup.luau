--!strict
--!nolint FunctionUnused
-- handlers/data_backup.luau — Settings → Backups: o destino S3 dos backups de dados dos serviços
-- (docs/plano-backup-de-dados-para-s3.md, Fase 1). A webui faz o mesmo em `webui/app.js`
-- (`backupDestination*`): mude os dois juntos.
--
-- A chave secreta NUNCA volta do daemon: `backup_destination_secret_set` só diz se existe uma gravada.
-- O campo da chave fica vazio e, vazio, significa "manter a que já está lá".

local State = require("../state")
local Helpers = require("../helpers")

local M = {}

local function secret_or_nil(): string?
    local secret = ctx.backup_destination_secret_key or ""
    if secret == "" then
        return nil
    end
    return secret
end

-- O que a tela digitou, no formato do `BackupDestination` do protocolo.
local function draft(): { [string]: any }
    return {
        endpoint = Helpers.trim(ctx.backup_destination_endpoint),
        region = Helpers.trim(ctx.backup_destination_region),
        bucket = Helpers.trim(ctx.backup_destination_bucket),
        prefix = Helpers.trim(ctx.backup_destination_prefix),
        path_style = Helpers.is_true(ctx.backup_destination_path_style),
        access_key = Helpers.trim(ctx.backup_destination_access_key),
        secret_key = secret_or_nil(),
    }
end

-- Espalha o que o daemon devolveu (sem a chave secreta) no formulário.
local function apply_view(view: any): ()
    ctx.backup_destination_configured = tostring(view.configured == true)
    ctx.backup_destination_secret_set = tostring(view.secret_set == true)
    ctx.backup_destination_recovery_missing =
        tostring(view.recovery_configured ~= true)
    ctx.backup_destination_secret_key = ""
    if view.configured == true then
        ctx.backup_destination_endpoint = view.endpoint or ""
        ctx.backup_destination_region = view.region or ""
        ctx.backup_destination_bucket = view.bucket or ""
        ctx.backup_destination_prefix = view.prefix or ""
        ctx.backup_destination_path_style = tostring(view.path_style == true)
        ctx.backup_destination_access_key = view.access_key or ""
    end
end

-- Lê o destino gravado (ao abrir Settings).
function M.load(): ()
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("BackupDestinationGet")
    if ok and response.BackupDestination ~= nil then
        apply_view(response.BackupDestination)
    end
end

function backup_destination_load(): ()
    M.load()
end

function backup_destination_save(): ()
    local api = State.api
    if not api then
        return
    end
    ctx.backup_destination_message = i18n.tr("salvando…")
    local ok, response =
        api:rpc_checked { BackupDestinationSet = { destination = draft() } }
    if ok and response.BackupDestination ~= nil then
        apply_view(response.BackupDestination)
        ctx.backup_destination_message = i18n.tr("destino salvo")
        toast {
            message = tostring(i18n.tr("Destino de backup salvo")),
            kind = "success",
        }
    else
        ctx.backup_destination_message = i18n.tr("erro: ")
            .. tostring(response)
        toast { message = tostring(response), kind = "error" }
    end
end

-- Grava, lê e apaga um objeto pequeno no S3, com o que está na tela (não precisa salvar antes).
function backup_destination_test(): ()
    local api = State.api
    if not api then
        return
    end
    ctx.backup_destination_message = i18n.tr("testando a conexão…")
    local ok, response =
        api:rpc_checked { BackupDestinationTest = { destination = draft() } }
    if ok then
        ctx.backup_destination_message = i18n.tr("conexão funcionando")
        toast {
            message = tostring(i18n.tr("Conexão com o S3 funcionando")),
            kind = "success",
        }
    else
        ctx.backup_destination_message = i18n.tr("erro: ")
            .. tostring(response)
        toast { message = tostring(response), kind = "error" }
    end
end

function backup_destination_clear(): ()
    local api = State.api
    if not api then
        return
    end
    local confirmed = confirm {
        title = tostring(i18n.tr("Remover o destino de backup?")),
        message = tostring(
            i18n.tr(
                "Os backups que já estão no S3 continuam lá. Os próximos não serão enviados até você configurar outro destino."
            )
        ),
        confirm_label = tostring(i18n.tr("Remover")),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response = api:rpc_checked("BackupDestinationClear")
    if ok then
        ctx.backup_destination_configured = "false"
        ctx.backup_destination_secret_set = "false"
        ctx.backup_destination_secret_key = ""
        ctx.backup_destination_message = i18n.tr("destino removido")
        toast {
            message = tostring(i18n.tr("Destino de backup removido")),
            kind = "success",
        }
    else
        ctx.backup_destination_message = i18n.tr("erro: ")
            .. tostring(response)
        toast { message = tostring(response), kind = "error" }
    end
end

return M
