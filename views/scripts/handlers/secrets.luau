--!strict
--!nolint FunctionUnused
-- handlers/secrets.luau — aba "Secrets" do projeto: criar/sobrescrever e
-- apagar valores cifrados, e o atalho "usar secret" da aba Variáveis.
--
-- A UI é write-only DE PROPÓSITO: o daemon só devolve os NOMES (SecretList →
-- Response::SecretNames), nunca o blob cifrado, então não há o que exibir nem
-- como "editar" um valor — sobrescrever é salvar outro com o mesmo nome
-- (o SecretSet do daemon faz ON CONFLICT DO UPDATE). Ver docs/secrets.md.
--
-- A lista em si não é buscada aqui: vem no snapshot (`projects[].secrets`),
-- montada por handlers/stream.luau em
-- ctx.project_secrets/project_secrets_count.

local State = require("../state")
local Helpers = require("../helpers")
local Stream = require("stream")
local Services = require("services")

-- Nomes atualmente conhecidos (do snapshot já renderizado), para saber se um
-- SecretSet cria ou substitui — o daemon não distingue os dois casos.
local function known_names(): { [string]: boolean }
    local names_set = {}
    local json_decode_ok, rows = Helpers.decode_list(ctx.project_secrets)
    if json_decode_ok and type(rows) == "table" then
        for _, row in ipairs(rows) do
            names_set[tostring(row.name)] = true
        end
    end
    return names_set
end

-- on_validation_error do form(name = secret_add) — NOME e valor são
-- `rules="required"` no form(...); o motor publica
-- {error_project_secret_new_name} / {error_project_secret_new_value} e acende
-- o :invalid. Aqui é só o aviso.
function secret_add_show_validation_errors(_erros_json: string?): ()
    toast {
        message = i18n.tr("Preencha nome e valor do secret"),
        kind = "warning",
    }
end

function secret_add(): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or not api then
        return
    end
    -- rules="required" no form(...) garante nome e valor preenchidos aqui.
    local name = Helpers.trim(ctx.project_secret_new_name)
    local value = ctx.project_secret_new_value or ""
    local replacing = known_names()[name] == true
    local secret_set_ok, secret_set_response = api:rpc_checked {
        SecretSet = { project_id = project_id, name = name, value = value },
    }
    if secret_set_ok then
        ctx.project_secret_new_name = ""
        ctx.project_secret_new_value = ""
        local message = i18n.tr('Secret "') .. name .. i18n.tr('" criado')
        if replacing then
            message = i18n.tr('Secret "')
                .. name
                .. i18n.tr(
                    '" substituído — o novo valor vale no próximo deploy'
                )
        end
        toast { message = message, kind = "success" }
        Stream.refresh_now()
    else
        toast { message = tostring(secret_set_response), kind = "error" }
    end
end

function secret_delete(name: string): ()
    local project_id = ctx.selected_project_id or ""
    if project_id == "" or name == "" then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Remover secret?"),
        message = i18n.tr(
            'O valor cifrado será apagado e não há como recuperá-lo. Variáveis que referenciam "'
        )
            .. name
            .. i18n.tr('" passarão a receber valor vazio no próximo deploy.'),
        confirm_label = i18n.tr("Remover secret"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local api = State.api
    if not api then
        return
    end
    local secret_delete_ok, secret_delete_response = api:rpc_checked {
        SecretDelete = { project_id = project_id, name = name },
    }
    if secret_delete_ok then
        toast {
            message = tostring(i18n.tr("Secret removido")),
            kind = "success",
        }
        Stream.refresh_now()
    else
        toast { message = tostring(secret_delete_response), kind = "error" }
    end
end

-- Chip "usar secret" (aba Variáveis): arma o form de adicionar var em modo
-- secret com o nome escolhido. Quem grava é project_env_add
-- (handlers/projects.luau), que nesse modo monta { Secret = nome } em vez de {
-- Plain = valor }.
function secret_use(name: string): ()
    ctx.project_env_new_is_secret = "true"
    ctx.project_env_new_value = name
    if Helpers.trim(ctx.project_env_new_key) == "" then
        ctx.project_env_new_key = name
    end
end

function project_env_secret_toggle(): ()
    local on = Helpers.is_true(ctx.project_env_new_is_secret)
    ctx.project_env_new_is_secret = on and "false" or "true"
    ctx.project_env_new_value = ""
end

-- ── Movimentos (SecretMove) a partir do PROJETO ─────────────────────────────
-- O destino dos "↓ para o serviço" é o serviço escolhido no <select> do topo da aba
-- (ctx.move_target_service_id); os outros movimentos não precisam dele.

function move_target_pick(service_id: string): ()
    ctx.move_target_service_id = service_id or ""
end

local function project_move(
    op: string,
    name: string,
    service_id: string?,
    done_message: string
): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or name == "" or not api then
        return
    end
    local move_ok, move_response = api:rpc_checked {
        SecretMove = {
            project_id = project_id,
            service_id = service_id,
            name = name,
            op = op,
        },
    }
    if move_ok then
        toast { message = done_message .. name, kind = "success" }
        Stream.refresh_now()
    else
        toast { message = tostring(move_response), kind = "error" }
    end
end

-- Devolve o serviço de destino escolhido, ou avisa e devolve nil.
local function target_service(): string?
    local service_id = ctx.move_target_service_id or ""
    if service_id == "" then
        toast {
            message = i18n.tr(
                "Escolha antes o serviço de destino, no seletor do topo."
            ),
            kind = "warning",
        }
        return nil
    end
    return service_id
end

function project_env_to_secret(key: string): ()
    project_move(
        "EnvToSecret",
        key,
        nil,
        i18n.tr("Variável movida para secret: ")
    )
end

function project_secret_to_env(name: string): ()
    local confirmed = confirm {
        title = i18n.tr("Voltar para variável em claro?"),
        message = i18n.tr('O valor de "')
            .. name
            .. i18n.tr(
                '" deixa de ser cifrado e passa a aparecer em claro na variável (e no estado versionado).'
            ),
        confirm_label = i18n.tr("Mover para variável"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    project_move(
        "SecretToEnv",
        name,
        nil,
        i18n.tr("Secret movido para variável: ")
    )
end

function project_secret_to_service(name: string): ()
    local service_id = target_service()
    if service_id == nil then
        return
    end
    project_move(
        "ProjectSecretToService",
        name,
        service_id,
        i18n.tr("Secret movido para o serviço: ")
    )
end

function project_env_to_service(key: string): ()
    local service_id = target_service()
    if service_id == nil then
        return
    end
    project_move(
        "EnvProjectToService",
        key,
        service_id,
        i18n.tr("Variável movida para o serviço: ")
    )
end

-- ── Renomear a chave de uma variável / o nome de um secret ──────────────────
-- EnvKeyRename / SecretRename: o valor nunca passa pela tela (nem pelo agente). O ✏️ da linha só
-- ARMA um mini-formulário (ctx.rename_open = "project_env" | "project_secret" | "service_env" |
-- "service_secret"); quem grava é project_rename_apply / service_rename_apply.

local function rename_pick(tag: string, name: string): ()
    ctx.rename_open = tag
    ctx.rename_from = name
    ctx.rename_to = name
end

function project_env_rename_pick(key: string): ()
    rename_pick("project_env", key)
end

function project_secret_rename_pick(name: string): ()
    rename_pick("project_secret", name)
end

function service_env_rename_pick(key: string): ()
    rename_pick("service_env", key)
end

function service_secret_rename_pick(name: string): ()
    rename_pick("service_secret", name)
end

function rename_cancel(): ()
    ctx.rename_open = ""
    ctx.rename_from = ""
    ctx.rename_to = ""
end

function project_rename_apply(): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    local from = ctx.rename_from or ""
    local to = Helpers.trim(ctx.rename_to)
    if project_id == "" or from == "" or not api then
        return
    end
    if to == "" or to == from then
        toast {
            message = i18n.tr("Digite um nome novo, diferente do atual."),
            kind = "warning",
        }
        return
    end
    local body = { project_id = project_id, from = from, to = to }
    local rename_ok, rename_response
    if ctx.rename_open == "project_secret" then
        rename_ok, rename_response = api:rpc_checked { SecretRename = body }
    else
        rename_ok, rename_response = api:rpc_checked { EnvKeyRename = body }
    end
    if rename_ok then
        toast {
            message = i18n.tr("Renomeado: ") .. from .. " → " .. to,
            kind = "success",
        }
        rename_cancel()
        Stream.refresh_now()
    else
        toast { message = tostring(rename_response), kind = "error" }
    end
end

-- ── Edição no lugar da chave/valor de uma variável ──────────────────────────
-- O ✏️ (chave) e o ✎ (valor) da linha trocam o texto dela por um campo, na própria posição da
-- lista: nada é levado para um formulário no topo (numa lista grande ele ficava fora da tela).
-- Enter ou ✓ grava; ✕ desiste. Chave: EnvKeyRename; valor: EnvValueSet (o valor nunca passa
-- pela lista inteira, só a variável editada). `ctx.env_edit_id` é "key:NOME" | "value:NOME".

local function env_row(raw: any, key: string): any?
    local rows = raw
    if type(raw) == "string" then
        local ok, decoded = pcall(function()
            return json.decode(raw)
        end)
        rows = ok and decoded or {}
    end
    for _, row in ipairs(rows or {}) do
        if row.key == key then
            return row
        end
    end
    return nil
end

local function env_edit_start(scope: string, field: string, key: string): ()
    local raw = (scope == "service") and ctx.service_env or ctx.project_env
    local row = env_row(raw, key)
    if row == nil then
        return
    end
    local is_secret = row.kind == "secret"
    local draft = key
    if field == "value" then
        -- Variável secret: o texto editável é a referência (`secret:NOME`), nunca o valor cifrado.
        draft = is_secret and ("secret:" .. tostring(row.secret_name)) or tostring(row.value)
    end
    ctx.env_edit_scope = scope
    ctx.env_edit_id = field .. ":" .. key
    ctx.env_edit_draft = draft
    ctx.env_edit_was_secret = is_secret and "true" or "false"
end

function env_edit_cancel(): ()
    ctx.env_edit_id = ""
    ctx.env_edit_draft = ""
    ctx.env_edit_scope = ""
    ctx.env_edit_was_secret = "false"
end

function project_env_edit_key(key: string): ()
    env_edit_start("project", "key", key)
end

function project_env_edit_value(key: string): ()
    env_edit_start("project", "value", key)
end

function service_env_edit_key(key: string): ()
    env_edit_start("service", "key", key)
end

function service_env_edit_value(key: string): ()
    env_edit_start("service", "value", key)
end

function env_edit_apply(): ()
    local api = State.api
    local id = ctx.env_edit_id or ""
    local scope = ctx.env_edit_scope or ""
    local field, key = id:match("^(%a+):(.+)$")
    if not api or field == nil or key == nil then
        return
    end
    local is_service = scope == "service"
    local project_id = is_service and (ctx.service_project_id or "")
        or (ctx.selected_project_id or "")
    local service_id = is_service and (ctx.selected_service or "") or nil
    if project_id == "" or (is_service and service_id == "") then
        return
    end
    local draft = ctx.env_edit_draft or ""
    local was_secret = Helpers.is_true(ctx.env_edit_was_secret)
    local ok, response
    if field == "key" then
        local to = Helpers.trim(draft)
        if to == "" or to == key then
            env_edit_cancel()
            return
        end
        ok, response = api:rpc_checked {
            EnvKeyRename = {
                project_id = project_id,
                service_id = service_id,
                from = key,
                to = to,
            },
        }
    else
        ok, response = api:rpc_checked {
            EnvValueSet = {
                project_id = project_id,
                service_id = service_id,
                key = key,
                value = Helpers.env_value_from_draft(draft, was_secret),
            },
        }
    end
    if ok then
        toast {
            message = (field == "key") and (i18n.tr("Renomeado: ") .. key)
                or (i18n.tr("Valor salvo: ") .. key),
            kind = "success",
        }
        env_edit_cancel()
        if is_service then
            Services.fetch_service_detail(service_id)
        end
        Stream.refresh_now()
    else
        -- Fica no modo de edição: o texto digitado não se perde numa recusa do daemon.
        toast { message = tostring(response), kind = "error" }
    end
end

-- ── Ver o valor de um secret do PROJETO ─────────────────────────────────────
-- SecretReveal grava auditoria (quem, qual, quando; nunca o valor) e fica de fora do MCP.

function secret_reveal(name: string): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or name == "" or not api then
        return
    end
    local confirmed = confirm {
        title = i18n.tr("Ver o valor do secret?"),
        message = i18n.tr('O valor de "')
            .. name
            .. i18n.tr(
                '" vai aparecer na tela. O acesso fica registrado na auditoria do servidor (quem, qual secret e quando; nunca o valor).'
            ),
        confirm_label = i18n.tr("Ver valor"),
    }
    if not confirmed then
        return
    end
    local reveal_ok, reveal_response = api:rpc {
        SecretReveal = { project_id = project_id, name = name },
    }
    if
        not reveal_ok
        or type(reveal_response) ~= "table"
        or reveal_response.SecretValue == nil
    then
        toast { message = tostring(reveal_response), kind = "error" }
        return
    end
    State.revealed_secrets["project:" .. name] =
        reveal_response.SecretValue :: string
    Stream.refresh_now()
end

function secret_hide(name: string): ()
    State.revealed_secrets["project:" .. name] = nil
    Stream.refresh_now()
end
