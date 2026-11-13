--!strict
--!nolint FunctionUnused
-- handlers/recovery_key.luau — Settings → Chave de recuperação (docs/plano-chave-de-recuperacao.md).
-- A webui faz o mesmo em `webui/app.js` (`recoveryKey*`): mude os dois juntos.
--
-- O daemon guarda só a chave PÚBLICA; a privada volta uma única vez, na resposta de `RecoveryKeyGenerate`.
-- Ela é gravada em Downloads na hora e fica no `ctx` só até a pessoa dizer "guardei" — nunca é relida.

local State = require("../state")
local Download = require("../download")

local M = {}

local function set_defaults(): ()
    ctx.recovery_key_configured = ctx.recovery_key_configured or "false"
    ctx.recovery_key_public = ctx.recovery_key_public or ""
    ctx.recovery_key_generated = ctx.recovery_key_generated or "false"
    ctx.recovery_key_private = ctx.recovery_key_private or ""
    ctx.recovery_key_filename = ctx.recovery_key_filename or ""
    ctx.recovery_key_contents = ctx.recovery_key_contents or ""
    ctx.recovery_key_saved_message = ctx.recovery_key_saved_message or ""
end

--- Lê se há chave configurada e qual é a pública.
function M.load(): ()
    set_defaults()
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("RecoveryKeyStatus")
    if ok and type(response) == "table" and response.RecoveryKey ~= nil then
        ctx.recovery_key_configured = tostring(response.RecoveryKey.configured == true)
        ctx.recovery_key_public = response.RecoveryKey.public_key or ""
    end
end

local function save_file_now(): ()
    local saved, where = Download.save(
        ctx.recovery_key_filename,
        ctx.recovery_key_contents,
        i18n.tr("Salvar a chave de recuperação")
    )
    if saved then
        ctx.recovery_key_saved_message = i18n.tr("salvo em ") .. where
        toast { message = ctx.recovery_key_saved_message, kind = "success" }
    else
        ctx.recovery_key_saved_message = where
        toast { message = where, kind = "error" }
    end
end

--- Abre a aba (usada pelos avisos de "sem chave" em Backups e Sincronização).
function recovery_key_open(): ()
    ctx.view = "settings"
    ctx.settings_tab = "recoverykey"
    M.load()
end

--- Gera a chave e já a baixa em Downloads. Havendo chave, pede confirmação (a antiga deixa de cifrar).
function recovery_key_generate(): ()
    set_defaults()
    local api = State.api
    if not api then
        return
    end
    local replace = ctx.recovery_key_configured == "true"
    if replace then
        local confirmed = confirm {
            title = i18n.tr("Trocar a chave de recuperação?"),
            message = i18n.tr(
                "O que for exportado daqui em diante só abre com a chave nova. Backups e commits antigos continuam abrindo só com a chave antiga: guarde-a até não precisar mais."
            ),
            confirm_label = i18n.tr("Trocar chave"),
            destructive = true,
        }
        if not confirmed then
            return
        end
    end
    local ok, response = api:rpc_checked { RecoveryKeyGenerate = { replace = replace } }
    if not ok or type(response) ~= "table" or response.RecoveryKeyGenerated == nil then
        toast { message = tostring(response), kind = "error" }
        return
    end
    local generated = response.RecoveryKeyGenerated
    ctx.recovery_key_configured = "true"
    ctx.recovery_key_public = generated.public_key
    ctx.recovery_key_generated = "true"
    ctx.recovery_key_private = generated.private_key
    ctx.recovery_key_filename = generated.suggested_filename
    ctx.recovery_key_contents = generated.file_contents
    -- o aviso de "sem chave" das abas Backups e Sincronização some sem esperar a releitura
    ctx.backup_destination_recovery_missing = "false"
    ctx.state_git_recovery_missing = "false"
    save_file_now()
end

--- "Baixar de novo" (a pessoa moveu/apagou o arquivo antes de guardar).
function recovery_key_save_again(): ()
    if ctx.recovery_key_generated ~= "true" then
        return
    end
    save_file_now()
end

function recovery_key_copy(): ()
    if ctx.recovery_key_generated ~= "true" then
        return
    end
    copy(ctx.recovery_key_private)
    toast { message = i18n.tr("chave copiada"), kind = "success" }
end

--- "Guardei em lugar seguro": esquece a privada.
function recovery_key_dismiss(): ()
    ctx.recovery_key_generated = "false"
    ctx.recovery_key_private = ""
    ctx.recovery_key_contents = ""
    ctx.recovery_key_saved_message = ""
end

return M
