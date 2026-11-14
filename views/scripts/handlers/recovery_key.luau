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
    -- Inverso de `configured`: o `.gv` só confia em `equals = true` para o botão de gerar (com `equals = false`
    -- sobre a string "false" do ctx o botão sumia quando o servidor não tinha chave).
    ctx.recovery_key_missing = ctx.recovery_key_missing or "true"
    ctx.recovery_key_warn = ctx.recovery_key_warn or "false"
    ctx.recovery_key_generate_label = ctx.recovery_key_generate_label or i18n.tr("Gerar e baixar")
    ctx.recovery_key_load_error = ctx.recovery_key_load_error or ""
    ctx.recovery_key_public = ctx.recovery_key_public or ""
    ctx.recovery_key_generated = ctx.recovery_key_generated or "false"
    ctx.recovery_key_private = ctx.recovery_key_private or ""
    ctx.recovery_key_filename = ctx.recovery_key_filename or ""
    ctx.recovery_key_contents = ctx.recovery_key_contents or ""
    ctx.recovery_key_saved_message = ctx.recovery_key_saved_message or ""
end

--- Deriva do estado (`configured`, `generated`) as flags e o rótulo que a tela usa. A tela só confia em
--- `equals = true` e em elementos soltos (coluna condicional por fora do botão o escondia sem chave).
local function refresh_flags(): ()
    local configured = ctx.recovery_key_configured == "true"
    local generated = ctx.recovery_key_generated == "true"
    ctx.recovery_key_missing = tostring(not configured)
    -- aviso de "trocar" só enquanto a privada NÃO está na tela (depois de gerar, o aviso de única cópia o substitui)
    ctx.recovery_key_warn = tostring(configured and not generated)
    ctx.recovery_key_generate_label = if configured then i18n.tr("Gerar outra chave") else i18n.tr("Gerar e baixar")
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
        ctx.recovery_key_load_error = ""
        refresh_flags()
    else
        -- Daemon antigo (sem o comando) ou fora do ar: não deixa a tela muda.
        ctx.recovery_key_load_error = i18n.tr("Não consegui ler a chave de recuperação deste servidor (o daemon é anterior à versão 0.1.57?): ")
            .. tostring(response)
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
                "A chave nova cifra tudo daqui em diante e os segredos de hoje são recifrados para ela. Mas os backups de dados que já estão no S3 e o histórico do git NÃO mudam: continuam abrindo só com a chave antiga. Guarde-a enquanto precisar deles, ou refaça os backups logo depois da troca."
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
    refresh_flags()
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
    refresh_flags()
end

return M
