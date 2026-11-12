--!strict
--!nolint FunctionUnused
-- handlers/state_git.luau — Settings → Sync: a sincronização do estado de infra com
-- um repositório git (Fases 6 e 7 de docs/plano-backup-estado-em-git.md).
--
-- O STATUS não é buscado aqui: vem no snapshot (`snapshot.state_git`,
-- `snapshot.infra_audit`) e handlers/stream.luau o espalha no `ctx` via
-- format/state_git.luau. Aqui só ficam as AÇÕES e o formulário. A webui faz o
-- mesmo em `webui/app.js` (`stateGit*`): mude os dois juntos.

local State = require("../state")
local Helpers = require("../helpers")
local Stream = require("stream")

local function finish(
    ok: boolean,
    response: any,
    success_message: string
): boolean
    if ok then
        ctx.state_git_message = success_message
        toast { message = success_message, kind = "success" }
    else
        ctx.state_git_message = i18n.tr("erro: ") .. tostring(response)
        toast { message = ctx.state_git_message, kind = "error" }
    end
    Stream.refresh_now()
    return ok
end

-- O <select> da conta Git só escreve na chave via on_change.
function state_git_provider_pick(provider_id: string): ()
    ctx.state_git_form_provider_id = provider_id or ""
end

-- Liga/desliga/configura. O daemon RECUSA ligar com valor em claro no estado
-- (a lista da auditoria, mais abaixo, diz quais).
function state_git_save(): ()
    local api = State.api
    if not api then
        return
    end
    local remote = Helpers.trim(ctx.state_git_form_remote)
    local branch = Helpers.trim(ctx.state_git_form_branch)
    local provider_id = ctx.state_git_form_provider_id or ""
    local ok, response = api:rpc_checked {
        StateGitConfigure = {
            mode = ctx.state_git_form_mode or "off",
            remote = (remote ~= "" and remote or nil),
            branch = (branch ~= "" and branch or nil),
            provider_id = (provider_id ~= "" and provider_id or nil),
        },
    }
    finish(ok, response, i18n.tr("sincronização configurada"))
end

-- Limpa a configuração do sync: modo `off` e sem repositório, branch nem conta. O
-- daemon apaga as chaves (`StateGitConfigure` com tudo vazio) e para de commitar/empurrar;
-- a pasta local do histórico e o repositório remoto ficam como estão. Era a única saída
-- de uma configuração errada (ex.: servidor local apontando para o repositório de prod).
function state_git_clear(): ()
    local api = State.api
    if not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Limpar a configuração da sincronização?"),
        message = i18n.tr(
            "O servidor deixa de commitar e de empurrar o estado. O repositório remoto e o histórico já gravado não são apagados; dá para configurar de novo depois."
        ),
        confirm_label = i18n.tr("Limpar"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response = api:rpc_checked {
        StateGitConfigure = { mode = "off" },
    }
    if ok then
        ctx.state_git_form_mode = "off"
        ctx.state_git_form_remote = ""
        ctx.state_git_form_branch = "main"
        ctx.state_git_form_provider_id = ""
    end
    finish(ok, response, i18n.tr("configuração da sincronização limpa"))
end

-- "Sincronizar agora": commit pendente, fetch, aplicação do que veio de fora e push.
function state_git_sync_now(): ()
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("StateGitSyncNow")
    finish(ok, response, i18n.tr("sincronizado"))
end

-- Depois de resolver à mão (por SSH): o daemon RELÊ a pasta e valida antes de voltar
-- a andar. Se o histórico continua divergido, pausa de novo — e o aviso diz isso.
function state_git_resume(): ()
    local api = State.api
    if not api then
        return
    end
    local ok, response = api:rpc_checked("StateGitResume")
    local status = ok and response.StateGit or nil
    if status ~= nil and status.paused_reason ~= nil then
        ctx.state_git_message = i18n.tr("o histórico continua divergido")
        toast { message = ctx.state_git_message, kind = "warning" }
        Stream.refresh_now()
        return
    end
    finish(ok, response, i18n.tr("sincronização retomada"))
end

local function resolve(choice: string, question: string): ()
    local api = State.api
    if not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Resolver a divergência?"),
        message = question,
        confirm_label = i18n.tr("Resolver"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local ok, response =
        api:rpc_checked { StateGitResolve = { choice = choice } }
    finish(ok, response, i18n.tr("divergência resolvida"))
end

function state_git_resolve_remote(): ()
    resolve(
        "UseRemote",
        i18n.tr(
            "Usar o do repositório? O que só o servidor tem será descartado (fica salvo numa branch rustploy-backup/local-… no servidor)."
        )
    )
end

function state_git_resolve_local(): ()
    resolve(
        "UseLocal",
        i18n.tr(
            "Usar o do servidor? O que só o repositório tem será sobrescrito (fica salvo numa branch rustploy-backup/remote-… no próprio repositório)."
        )
    )
end

-- Esquece a marca "removido no git" (a pessoa decidiu manter o que ainda roda, ou já limpou).
function state_git_dismiss_removal(removal_id: string): ()
    local api = State.api
    if not api then
        return
    end
    local ok, response =
        api:rpc_checked { StateGitDismissRemoval = { id = removal_id } }
    if ok then
        Stream.refresh_now()
    else
        toast {
            message = i18n.tr("erro: ") .. tostring(response),
            kind = "error",
        }
    end
end

local function set_allowed(index: string, allowed: boolean): ()
    local api = State.api
    local snap = State.snap
    if not api or not snap then
        return
    end
    local finding = (snap.infra_audit or {})[tonumber(index) or 0]
    if finding == nil then
        return
    end
    local ok, response = api:rpc_checked {
        InfraAuditAllow = {
            project = finding.project,
            scope = finding.scope,
            what = finding.what,
            allowed = allowed,
        },
    }
    if ok then
        Stream.refresh_now()
    else
        toast {
            message = i18n.tr("erro: ") .. tostring(response),
            kind = "error",
        }
    end
end

-- Marca uma SUSPEITA da auditoria como "não é segredo" (certezas não podem).
function state_git_allow_finding(index: string): ()
    set_allowed(index, true)
end

function state_git_block_again(index: string): ()
    set_allowed(index, false)
end
