--!strict
--!nolint FunctionUnused
-- job_env_core.luau — a lógica das envs e secrets de UM job, sem depender da janela principal
-- (sem State/Stream/History), para rodar tanto na tela `job_env` do app quanto dentro da janela
-- "Novo/Editar job" (que é um motor Luau isolado). Quem usa chama `setup` com a conexão e o job, e
-- põe nos botões as funções globais finas que chamam estas (handlers/job_env.luau e
-- new_job_window.luau).
--
-- Escopo de job = `job_id` nos comandos de secret/env (SecretSet, SecretMove, EnvKeyRename…). As envs
-- viajam no próprio `Job`; adicionar/remover/colar o .env reenvia o Job inteiro (`JobUpdate`). Depois
-- de cada mudança o job é relido (`JobList`). Toda operação que muda ou expõe uma env pede
-- confirmação (reordenar não).

local Helpers = require("helpers")
local format = require("format")

local Core = {}

local api: any = nil
local project_id = ""
local job_id = ""
local raw: any = nil
local revealed: { [string]: string } = {}
local after_change: (() -> ())? = nil

function Core.setup(opts: { api: any, project_id: string, job_id: string, after_change: (() -> ())? }): ()
    api = opts.api
    project_id = opts.project_id
    job_id = opts.job_id
    after_change = opts.after_change
    raw = nil
    revealed = {}
end

-- O Job cru mais recente (envs atuais), para quem precisa reenviar o JobUpdate.
function Core.job(): any
    return raw
end

local function ask(title: string, message: string, confirm_label: string, destructive: boolean?): boolean
    return confirm {
        title = title,
        message = message,
        confirm_label = confirm_label,
        destructive = destructive == true,
    }
end

local function changed(): ()
    Core.load()
    if after_change then
        after_change()
    end
end

function Core.reset_forms(): ()
    ctx.job_env_text_open = "false"
    ctx.job_env_edit_id = ""
    ctx.job_env_edit_draft = ""
    ctx.job_rename_open = ""
    ctx.job_rename_from = ""
    ctx.job_rename_to = ""
    ctx.job_env_new_key = ""
    ctx.job_env_new_value = ""
    ctx.job_secret_new_name = ""
    ctx.job_secret_new_value = ""
end

-- Relê o job (e os nomes dos secrets dele) e espalha no ctx.
function Core.load(): ()
    if not api or project_id == "" or job_id == "" then
        return
    end
    local job_list_ok, job_list_response = api:rpc { JobList = { project_id = project_id } }
    if not job_list_ok or type(job_list_response) ~= "table" or type(job_list_response.Jobs) ~= "table" then
        return
    end
    local job: any = nil
    for _, candidate in ipairs(job_list_response.Jobs) do
        if candidate.id == job_id then
            job = candidate
            break
        end
    end
    if job == nil then
        toast { message = i18n.tr("Job não encontrado."), kind = "error" }
        return
    end
    raw = job
    ctx.job_env_name = job.name
    ctx.job_env = format.env_json_with_comments(job.env_vars, job.env_comments)
    ctx.job_env_count = tostring(#(job.env_vars or {}))
    local dotenv = format.env_dotenv_with_comments(job.env_vars, job.env_comments)
    ctx.job_env_text = dotenv
    ctx.job_env_text_original = dotenv
    local names: { string } = {}
    local secret_list_ok, secret_list_response = api:rpc {
        SecretList = { project_id = project_id, job_id = job_id },
    }
    if secret_list_ok and type(secret_list_response) == "table" and type(secret_list_response.SecretNames) == "table" then
        names = secret_list_response.SecretNames
    end
    ctx.job_secrets = format.secret_rows(names, "job:" .. job_id, revealed)
    ctx.job_secrets_count = tostring(#names)
end

-- Reenvia o Job inteiro com as envs novas (o daemon não tem PATCH parcial).
local function save_env(vars: any, comments: any, done_message: string): boolean
    local job = raw
    if not api or not job then
        return false
    end
    local job_update_ok, job_update_response = api:rpc_checked {
        JobUpdate = {
            id = job.id,
            name = job.name,
            compose = job.compose,
            git_source = job.git_source,
            main_service = job.main_service,
            env_vars = vars,
            env_comments = comments,
            enabled = job.enabled,
            recurrence = job.recurrence,
        },
    }
    if not job_update_ok then
        toast { message = tostring(job_update_response), kind = "error" }
        return false
    end
    toast { message = done_message, kind = "success" }
    changed()
    return true
end

-- ── Variáveis ───────────────────────────────────────────────────────────────

function Core.show_validation_errors(): ()
    toast { message = i18n.tr("Informe a chave (KEY)"), kind = "warning" }
end

function Core.add(): ()
    local job = raw
    if not job then
        return
    end
    local key = Helpers.trim(ctx.job_env_new_key)
    local raw_value = ctx.job_env_new_value or ""
    local secret = Helpers.parse_secret_ref(raw_value)
    if not Helpers.confirm_env_key(key, ctx.job_env) then
        return
    end
    local kept = json.array {}
    for _, env_var in ipairs(job.env_vars or {}) do
        if env_var.key ~= key then
            table.insert(kept, env_var)
        end
    end
    table.insert(kept, { key = key, value = secret and { Secret = secret } or { Plain = raw_value } })
    if save_env(kept, job.env_comments or json.array {}, i18n.tr("Variável salva")) then
        ctx.job_env_new_key = ""
        ctx.job_env_new_value = ""
    end
end

function Core.delete(key: string): ()
    local job = raw
    if not job then
        return
    end
    if
        not ask(
            i18n.tr("Remover variável?"),
            i18n.tr('A variável "') .. key .. i18n.tr('" será removida deste job.'),
            i18n.tr("Remover"),
            true
        )
    then
        return
    end
    local kept = json.array {}
    for _, env_var in ipairs(job.env_vars or {}) do
        if env_var.key ~= key then
            table.insert(kept, env_var)
        end
    end
    local kept_comments = json.array {}
    for _, comment in ipairs(job.env_comments or {}) do
        if comment.before_key ~= key then
            table.insert(kept_comments, comment)
        end
    end
    save_env(kept, kept_comments, i18n.tr("Variável removida"))
end

function Core.text_toggle(): ()
    ctx.job_env_text_open = Helpers.is_true(ctx.job_env_text_open) and "false" or "true"
end

function Core.text_cancel(): ()
    ctx.job_env_text = ctx.job_env_text_original or ""
    ctx.job_env_text_open = "false"
end

function Core.import(): ()
    local vars, comments, errors = Helpers.parse_dotenv(ctx.job_env_text or "")
    if #errors > 0 then
        toast { message = Helpers.dotenv_errors_message(errors), kind = "error" }
        return
    end
    if
        not ask(
            i18n.tr("Substituir as variáveis?"),
            i18n.tr("Todas as variáveis deste job serão substituídas pelo texto do editor."),
            i18n.tr("Substituir"),
            true
        )
    then
        return
    end
    if save_env(vars, comments, i18n.tr("Variáveis salvas")) then
        ctx.job_env_text_open = "false"
    end
end

-- Reordena (arraste): `reorder_json` é um JSON array de keys na nova ordem (linhas `__c<idx>` são
-- comentários). Não pede confirmação.
function Core.reorder(reorder_json: string?): ()
    local job = raw
    if not reorder_json or not job then
        return
    end
    local decode_ok, keys = pcall(json.decode, reorder_json)
    if not decode_ok or type(keys) ~= "table" then
        return
    end
    local vars = job.env_vars or {}
    local comments = job.env_comments or {}
    local var_keys, by_key = {}, {}
    for _, variable in ipairs(vars) do
        var_keys[variable.key] = true
        by_key[variable.key] = variable
    end
    local seen = {}
    local new_vars = json.array {}
    local new_comments = json.array {}
    for key_position, key in ipairs(keys) do
        local comment_index_text = tostring(key):match("^__c(%d+)$")
        if comment_index_text then
            local comment_index = (tonumber(comment_index_text) or 0) + 1
            local comment = comments[comment_index]
            if comment then
                seen[comment_index] = true
                local anchor = nil
                for key_index = key_position + 1, #keys do
                    if var_keys[keys[key_index]] then
                        anchor = keys[key_index]
                        break
                    end
                end
                table.insert(new_comments, { text = comment.text, before_key = anchor })
            end
        elseif by_key[key] then
            table.insert(new_vars, by_key[key])
            by_key[key] = nil
        end
    end
    for _, variable in ipairs(vars) do
        if by_key[variable.key] then
            table.insert(new_vars, variable)
        end
    end
    for index, comment in ipairs(comments) do
        if not seen[index] then
            table.insert(new_comments, comment)
        end
    end
    save_env(new_vars, new_comments, i18n.tr("Ordem salva"))
end

-- ── Edição no lugar (✏️ chave, ✎ valor) ─────────────────────────────────────

local function env_row(key: string): any?
    local decode_ok, rows = pcall(function()
        return json.decode(ctx.job_env or "[]")
    end)
    for _, row in ipairs(decode_ok and rows or {}) do
        if row.key == key then
            return row
        end
    end
    return nil
end

local function edit_start(field: string, key: string): ()
    local row = env_row(key)
    if row == nil then
        return
    end
    local is_secret = row.kind == "secret"
    local draft = key
    if field == "value" then
        draft = is_secret and ("secret:" .. tostring(row.secret_name)) or tostring(row.value)
    end
    ctx.job_env_edit_id = field .. ":" .. key
    ctx.job_env_edit_draft = draft
    ctx.job_env_edit_was_secret = is_secret and "true" or "false"
end

function Core.edit_key(key: string): ()
    edit_start("key", key)
end

function Core.edit_value(key: string): ()
    edit_start("value", key)
end

function Core.edit_cancel(): ()
    ctx.job_env_edit_id = ""
    ctx.job_env_edit_draft = ""
    ctx.job_env_edit_was_secret = "false"
end

function Core.edit_apply(): ()
    local field, key = (ctx.job_env_edit_id or ""):match("^(%a+):(.+)$")
    if not api or field == nil or key == nil or job_id == "" then
        return
    end
    local draft = ctx.job_env_edit_draft or ""
    local edit_ok, edit_response
    if field == "key" then
        local to = Helpers.trim(draft)
        if to == "" or to == key then
            Core.edit_cancel()
            return
        end
        edit_ok, edit_response = api:rpc_checked {
            EnvKeyRename = { project_id = project_id, job_id = job_id, from = key, to = to },
        }
    else
        edit_ok, edit_response = api:rpc_checked {
            EnvValueSet = {
                project_id = project_id,
                job_id = job_id,
                key = key,
                value = Helpers.env_value_from_draft(draft, Helpers.is_true(ctx.job_env_edit_was_secret)),
            },
        }
    end
    if edit_ok then
        toast {
            message = (field == "key") and (i18n.tr("Renomeado: ") .. key) or (i18n.tr("Valor salvo: ") .. key),
            kind = "success",
        }
        Core.edit_cancel()
        changed()
    else
        -- Fica no modo de edição: o texto digitado não se perde numa recusa do daemon.
        toast { message = tostring(edit_response), kind = "error" }
    end
end

-- ── Renomear (EnvKeyRename / SecretRename), sem o valor passar pela tela ────

function Core.secret_rename_pick(name: string): ()
    ctx.job_rename_open = "job_secret"
    ctx.job_rename_from = name
    ctx.job_rename_to = name
end

function Core.rename_cancel(): ()
    ctx.job_rename_open = ""
    ctx.job_rename_from = ""
    ctx.job_rename_to = ""
end

function Core.rename_apply(): ()
    local from = ctx.job_rename_from or ""
    local to = Helpers.trim(ctx.job_rename_to)
    if not api or job_id == "" or from == "" then
        return
    end
    if to == "" or to == from then
        toast { message = i18n.tr("Digite um nome novo, diferente do atual."), kind = "warning" }
        return
    end
    local body = { project_id = project_id, job_id = job_id, from = from, to = to }
    local rename_ok, rename_response
    if ctx.job_rename_open == "job_secret" then
        rename_ok, rename_response = api:rpc_checked { SecretRename = body }
    else
        rename_ok, rename_response = api:rpc_checked { EnvKeyRename = body }
    end
    if rename_ok then
        toast { message = i18n.tr("Renomeado: ") .. from .. " → " .. to, kind = "success" }
        Core.rename_cancel()
        changed()
    else
        toast { message = tostring(rename_response), kind = "error" }
    end
end

-- ── Movimentos (SecretMove) ─────────────────────────────────────────────────

local function job_move(op: string, name: string, done_message: string): ()
    if not api or job_id == "" or name == "" then
        return
    end
    local move_ok, move_response = api:rpc_checked {
        SecretMove = { project_id = project_id, job_id = job_id, name = name, op = op },
    }
    if move_ok then
        toast { message = done_message .. name, kind = "success" }
        changed()
    else
        toast { message = tostring(move_response), kind = "error" }
    end
end

-- 🔒 numa variável em claro: o valor passa a ser guardado cifrado.
function Core.env_to_secret(key: string): ()
    if
        not ask(
            i18n.tr("Mover para secret?"),
            i18n.tr('O valor de "') .. key .. i18n.tr('" passa a ser guardado cifrado.'),
            i18n.tr("Mover para secret")
        )
    then
        return
    end
    job_move("EnvToSecret", key, i18n.tr("Variável movida para secret: "))
end

-- 🔓: volta a ser variável em claro (o valor deixa de ser cifrado).
function Core.secret_to_env(name: string): ()
    if
        not ask(
            i18n.tr("Voltar para variável em claro?"),
            i18n.tr('O valor de "')
                .. name
                .. i18n.tr('" deixa de ser cifrado e passa a aparecer em claro na variável (e no estado versionado).'),
            i18n.tr("Mover para variável"),
            true
        )
    then
        return
    end
    job_move("SecretToEnv", name, i18n.tr("Secret movido para variável: "))
end

-- ↑ variável em claro do job → variável do projeto.
function Core.env_to_project(key: string): ()
    if
        not ask(
            i18n.tr("Subir para o projeto?"),
            i18n.tr('A variável "') .. key .. i18n.tr('" passa a valer para todo o projeto (serviços e jobs).'),
            i18n.tr("Subir para o projeto")
        )
    then
        return
    end
    job_move("EnvJobToProject", key, i18n.tr("Variável movida para o projeto: "))
end

-- ↑ secret do job → secret do projeto.
function Core.secret_to_project(name: string): ()
    if
        not ask(
            i18n.tr("Subir para o projeto?"),
            i18n.tr('O secret "') .. name .. i18n.tr('" passa a valer para todo o projeto (serviços e jobs).'),
            i18n.tr("Subir para o projeto")
        )
    then
        return
    end
    job_move("JobSecretToProject", name, i18n.tr("Secret movido para o projeto: "))
end

-- ── Secrets do job ──────────────────────────────────────────────────────────

function Core.secret_add_show_validation_errors(): ()
    toast { message = i18n.tr("Preencha nome e valor do secret"), kind = "warning" }
end

function Core.secret_add(): ()
    if not api or job_id == "" then
        return
    end
    local name = Helpers.trim(ctx.job_secret_new_name)
    local secret_set_ok, secret_set_response = api:rpc_checked {
        SecretSet = {
            project_id = project_id,
            job_id = job_id,
            name = name,
            value = ctx.job_secret_new_value or "",
        },
    }
    if secret_set_ok then
        ctx.job_secret_new_name = ""
        ctx.job_secret_new_value = ""
        toast {
            message = i18n.tr('Secret "') .. name .. i18n.tr('" salvo — vale na próxima execução'),
            kind = "success",
        }
        Core.load()
    else
        toast { message = tostring(secret_set_response), kind = "error" }
    end
end

function Core.secret_delete(name: string): ()
    if not api or job_id == "" or name == "" then
        return
    end
    if
        not ask(
            i18n.tr("Remover secret?"),
            i18n.tr('O valor cifrado será apagado e não há como recuperá-lo. Variáveis que referenciam "')
                .. name
                .. i18n.tr('" vão falhar na próxima execução.'),
            i18n.tr("Remover secret"),
            true
        )
    then
        return
    end
    local secret_delete_ok, secret_delete_response = api:rpc_checked {
        SecretDelete = { project_id = project_id, job_id = job_id, name = name },
    }
    if secret_delete_ok then
        toast { message = i18n.tr("Secret removido"), kind = "success" }
        Core.load()
    else
        toast { message = tostring(secret_delete_response), kind = "error" }
    end
end

-- 👁: pede o valor ao daemon (SecretReveal grava auditoria: quem, qual, quando; nunca o valor).
function Core.secret_reveal(name: string): ()
    if not api or job_id == "" or name == "" then
        return
    end
    if
        not ask(
            i18n.tr("Ver o valor do secret?"),
            i18n.tr('O valor de "')
                .. name
                .. i18n.tr('" vai aparecer na tela. O acesso fica registrado na auditoria do servidor (quem, qual secret e quando; nunca o valor).'),
            i18n.tr("Ver valor")
        )
    then
        return
    end
    local reveal_ok, reveal_response = api:rpc {
        SecretReveal = { project_id = project_id, job_id = job_id, name = name },
    }
    if not reveal_ok or type(reveal_response) ~= "table" or reveal_response.SecretValue == nil then
        toast { message = tostring(reveal_response), kind = "error" }
        return
    end
    revealed["job:" .. job_id .. ":" .. name] = reveal_response.SecretValue :: string
    Core.load()
end

function Core.secret_hide(name: string): ()
    revealed["job:" .. job_id .. ":" .. name] = nil
    Core.load()
end

-- Copia o valor já revelado (a chave é "job:<id>:<nome>", a mesma da linha).
function Core.secret_copy(ref: string): ()
    local value = revealed[ref]
    if value == nil then
        return
    end
    copy(value)
    toast { message = i18n.tr("Valor copiado para a área de transferência"), kind = "success" }
end

return Core
