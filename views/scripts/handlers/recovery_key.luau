--!strict
--!nolint FunctionUnused
-- handlers/recovery_key.luau — Settings → Chave de recuperação
-- (docs/plano-chave-de-recuperacao.md). A webui faz o mesmo em `webui/app.js`
-- (`recoveryKey*`): mude os dois juntos.
--
-- O daemon guarda só a chave PÚBLICA; a privada volta uma única vez, na
-- resposta de `RecoveryKeyGenerate`, dentro do arquivo de recuperação
-- (`.rpkit`, binário) com o repositório da infra, a branch e o token da conta
-- escolhida (docs/plano-arquivo-de-recuperacao.md). O arquivo é gravado em
-- Downloads na hora e fica no `ctx` só até a pessoa dizer "guardei".

local State = require("../state")
local Download = require("../download")
local Helpers = require("../helpers")

local M = {}

local function set_defaults(): ()
    ctx.recovery_key_configured = ctx.recovery_key_configured or "false"
    -- Inverso de `configured`: o `.gv` só confia em `equals = true` para o
    -- botão de gerar (com `equals = false` sobre a string "false" do ctx o
    -- botão sumia quando o servidor não tinha chave).
    ctx.recovery_key_missing = ctx.recovery_key_missing or "true"
    ctx.recovery_key_warn = ctx.recovery_key_warn or "false"
    ctx.recovery_key_generate_label = ctx.recovery_key_generate_label
        or i18n.tr("Gerar e baixar")
    ctx.recovery_key_load_error = ctx.recovery_key_load_error or ""
    ctx.recovery_key_public = ctx.recovery_key_public or ""
    ctx.recovery_key_generated = ctx.recovery_key_generated or "false"
    ctx.recovery_key_private = ctx.recovery_key_private or ""
    ctx.recovery_key_filename = ctx.recovery_key_filename or ""
    ctx.recovery_key_contents = ctx.recovery_key_contents or ""
    ctx.recovery_key_saved_message = ctx.recovery_key_saved_message or ""
    ctx.recovery_key_warning = ctx.recovery_key_warning or ""
    -- O formulário do arquivo começa com o que o Git Sync já usa.
    if (ctx.recovery_key_infra_remote or "") == "" then
        ctx.recovery_key_infra_remote = ctx.state_git_form_remote or ""
    end
    if (ctx.recovery_key_infra_branch or "") == "" then
        ctx.recovery_key_infra_branch = ctx.state_git_form_branch or ""
    end
    if (ctx.recovery_key_provider_id or "") == "" then
        ctx.recovery_key_provider_id = ctx.state_git_form_provider_id or ""
    end
end

--- Deriva do estado (`configured`, `generated`) as flags e o rótulo que a tela
--- usa. A tela só confia em `equals = true` e em elementos soltos (coluna
--- condicional por fora do botão o escondia sem chave).
local function refresh_flags(): ()
    local configured = ctx.recovery_key_configured == "true"
    local generated = ctx.recovery_key_generated == "true"
    ctx.recovery_key_missing = tostring(not configured)
    -- aviso de "trocar" só enquanto a privada NÃO está na tela (depois de
    -- gerar, o aviso de única cópia o substitui)
    ctx.recovery_key_warn = tostring(configured and not generated)
    ctx.recovery_key_generate_label = if configured
        then i18n.tr("Gerar outra chave")
        else i18n.tr("Gerar e baixar")
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
        ctx.recovery_key_configured =
            tostring(response.RecoveryKey.configured == true)
        ctx.recovery_key_public = response.RecoveryKey.public_key or ""
        ctx.recovery_key_load_error = ""
        refresh_flags()
    else
        -- Daemon antigo (sem o comando) ou fora do ar: não deixa a tela muda.
        ctx.recovery_key_load_error = i18n.tr(
            "Não consegui ler a chave de recuperação deste servidor (o daemon "
                .. "é anterior à versão 0.1.57?): "
        ) .. tostring(response)
    end
end

local function save_file_now(): ()
    -- o daemon manda o arquivo binário em base64 (é JSON); grava os bytes
    local bytes, decode_error = base64.decode(ctx.recovery_key_contents)
    if bytes == nil then
        ctx.recovery_key_saved_message = tostring(decode_error)
        toast { message = ctx.recovery_key_saved_message, kind = "error" }
        return
    end
    local saved, where = Download.save(
        ctx.recovery_key_filename,
        bytes,
        i18n.tr("Salvar o arquivo de recuperação")
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

--- O `<select>` da conta Git só escreve na chave via `on_change`.
function recovery_key_provider_pick(provider_id: string): ()
    ctx.recovery_key_provider_id = provider_id or ""
end

--- O que falta para gerar o arquivo, ou `nil` se está tudo lá. O daemon
--- confere de novo (e recusa antes de trocar a chave); isto só poupa a ida.
function M.missing_field(): string?
    local remote = Helpers.trim(ctx.recovery_key_infra_remote)
    if remote == "" then
        return i18n.tr("informe o repositório da infra")
    end
    local local_remote = remote:match("^file://") ~= nil
        or remote:sub(1, 1) == "/"
    if not local_remote and remote:match("^https://") == nil then
        return i18n.tr(
            "o repositório da infra precisa ser https://… (endereços SSH, "
                .. "git@…, não são aceitos)"
        )
    end
    if not local_remote and (ctx.recovery_key_provider_id or "") == "" then
        return i18n.tr("escolha a conta Git cujo token vai no arquivo")
    end
    return nil
end

--- Gera a chave e já baixa o arquivo de recuperação em Downloads. Havendo
--- chave, pede confirmação (a antiga deixa de cifrar).
function recovery_key_generate(): ()
    set_defaults()
    local api = State.api
    if not api then
        return
    end
    local missing = M.missing_field()
    if missing ~= nil then
        toast { message = missing, kind = "error" }
        return
    end
    local replace = ctx.recovery_key_configured == "true"
    if replace then
        local confirmed = confirm {
            title = i18n.tr("Trocar a chave de recuperação?"),
            message = i18n.tr(
                "A chave nova cifra tudo daqui em diante e os segredos de "
                    .. "hoje são recifrados para ela. Mas os backups de dados "
                    .. "que já estão no S3 e o histórico do git NÃO mudam: "
                    .. "continuam abrindo só com a chave antiga. Guarde-a "
                    .. "enquanto precisar deles, ou refaça os backups logo "
                    .. "depois da troca."
            ),
            confirm_label = i18n.tr("Trocar chave"),
            destructive = true,
        }
        if not confirmed then
            return
        end
    end
    local branch = Helpers.trim(ctx.recovery_key_infra_branch)
    local provider_id = ctx.recovery_key_provider_id or ""
    local ok, response = api:rpc_checked {
        RecoveryKeyGenerate = {
            replace = replace,
            infra_remote = Helpers.trim(ctx.recovery_key_infra_remote),
            infra_branch = if branch ~= "" then branch else nil,
            provider_id = if provider_id ~= "" then provider_id else nil,
        },
    }
    if
        not ok
        or type(response) ~= "table"
        or response.RecoveryKeyGenerated == nil
    then
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
    ctx.recovery_key_contents = generated.file_base64 or ""
    ctx.recovery_key_warning = generated.warning or ""
    -- o aviso de "sem chave" das abas Backups e Sincronização some sem esperar
    -- a releitura
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
    if
        not confirm {
            title = i18n.tr("Fechar a chave de recuperação?"),
            message = i18n.tr(
                "A chave privada não será mostrada de novo. Confirme que você já a guardou num lugar seguro."
            ),
            confirm_label = i18n.tr("Já guardei, fechar"),
            destructive = true,
        }
    then
        return
    end
    ctx.recovery_key_generated = "false"
    ctx.recovery_key_private = ""
    ctx.recovery_key_contents = ""
    ctx.recovery_key_saved_message = ""
    ctx.recovery_key_warning = ""
    refresh_flags()
end

return M
