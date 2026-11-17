--!strict
-- handlers/env_rows.luau — a linha de variável editável no lugar, na aba
-- Variáveis do projeto (shell/project_env.component.gv), na Environment do
-- serviço (service/environment.component.gv) e no painel das envs de um job
-- (components/job_env_panel.component.gv, que também roda dentro da janela
-- Novo/Editar job — por isso este módulo só depende de State, que é uma tabela
-- pura). A webui tem o mesmo desenho em webui/env_rows.js.
--
-- A chave e o valor são campos sem borda: clicar já edita. Nada grava sozinho
-- — digitar só muda um RASCUNHO da linha; aí aparecem o OK e o ✕ (desfazer). O
-- OK pede confirmação e grava (os handlers `*_env_row_*` em
-- handlers/secrets.luau): EnvValueSet para o valor, EnvKeyRename para a chave.
-- O "usar secret" troca o campo do valor por uma lista com os secrets que a
-- variável pode usar (no serviço: os dele e os do projeto; no projeto: os do
-- projeto; no job: os dele, os do serviço gatilho e os do projeto).
--
-- Como um campo de uma linha do ForEach se liga ao contexto: o glacier lê o
-- valor de um input numa chave do `ctx` (não num campo do item). Então cada
-- linha ganha as suas chaves —
-- `env_row_<escopo>_<posição>_key|value|use_secret|secret` — e o item da lista
-- carrega o NOME delas (`bind_*`), que o .gv interpola em `value =
-- "@e.bind_key"`. A posição (e não a chave da variável) dá nome às chaves para
-- que elas não mudem quando a variável é renomeada.
--
-- O rascunho mora em `State.env_drafts`, por escopo + projeto/serviço + chave,
-- e não no ctx: o snapshot que chega a cada segundo republica a lista sem
-- apagar o que a pessoa está digitando. Este módulo não fala com o daemon
-- (quem grava é secrets.luau): só monta a lista.

local State = require("../state")
local Helpers = require("../helpers")
local Util = require("../format/util")

local M = {}

export type Draft = {
    key: string,
    value: string,
    use_secret: boolean,
    secret: string,
}

-- Chave do ctx que o ForEach de cada escopo lê, e a da lista de secrets do
-- select.
local LIST_KEY: { [string]: string } = {
    project = "project_env",
    service = "service_env",
    job = "job_env",
}
local OPTIONS_KEY: { [string]: string } = {
    project = "project_env_secret_options",
    service = "service_env_secret_options",
    job = "job_env_secret_options",
}

-- Projeto (e serviço) a que a lista do escopo pertence: o rascunho de uma
-- variável de um serviço não pode aparecer na variável homônima de outro.
local function owner_id(scope: string): string
    if scope == "service" then
        return tostring(ctx.service_project_id or "")
            .. "|"
            .. tostring(ctx.selected_service or "")
    end
    if scope == "job" then
        return tostring(ctx.job_env_project_id or "")
            .. "|job:"
            .. tostring(ctx.job_env_job_id or "")
    end
    return tostring(ctx.selected_project_id or "") .. "|"
end

local function draft_id(scope: string, key: string): string
    return scope .. "|" .. owner_id(scope) .. "|" .. key
end

local function is_secret_row(row: any): boolean
    return row.kind == "secret"
end

-- O que está gravado, na forma do rascunho.
local function saved_state(row: any): Draft
    local is_secret = is_secret_row(row)
    return {
        key = tostring(row.key),
        value = is_secret and "" or tostring(row.value or ""),
        use_secret = is_secret,
        secret = is_secret and tostring(row.secret_name or "") or "",
    }
end

-- As linhas cruas do escopo (as de format.env_json_with_comments),
-- decodificadas.
local function raw_rows(scope: string): { any }
    local ok, rows = Helpers.decode_list(State.env_rows_raw[scope])
    if ok and type(rows) == "table" then
        return rows
    end
    return {}
end

-- A linha crua da variável `key` (nil se ela não existe mais).
function M.row(scope: string, key: string): any?
    for _, row in ipairs(raw_rows(scope)) do
        if row.kind ~= "comment" and row.key == key then
            return row
        end
    end
    return nil
end

-- O que a linha mostra: o rascunho, se houver, senão o que está gravado.
function M.row_state(scope: string, row: any): Draft
    return State.env_drafts[draft_id(scope, tostring(row.key))]
        or saved_state(row)
end

-- O que mudou em relação ao gravado: a chave nova (ou nil) e o EnvVarValue
-- novo (ou nil).
function M.changes(row: any, state: Draft): (string?, any?)
    local key = Helpers.trim(state.key)
    local rename_to: string? = nil
    if key ~= row.key then
        rename_to = key
    end
    local new_value: any = nil
    if state.use_secret then
        if not is_secret_row(row) or state.secret ~= row.secret_name then
            new_value = { Secret = state.secret }
        end
    elseif is_secret_row(row) or state.value ~= tostring(row.value or "") then
        new_value = { Plain = state.value }
    end
    return rename_to, new_value
end

-- Republica a lista do escopo no ctx: as linhas cruas + as chaves de cada
-- campo + `dirty`. Com `rows_json`, troca antes as linhas cruas (é o que
-- stream/services/projects chamam no lugar do antigo `ctx.<escopo>_env =
-- ...`); sem, só reaplica os rascunhos (a cada tecla).
function M.publish(scope: string, rows_json: string?): ()
    if rows_json ~= nil then
        State.env_rows_raw[scope] = rows_json
    end
    local options = State.env_secret_options[scope] or {}
    local known: { [string]: boolean } = {}
    for _, option in ipairs(options) do
        known[option.name] = true
    end
    local missing: { any } = {}
    local rows = raw_rows(scope)
    for position, row in ipairs(rows) do
        if row.kind ~= "comment" then
            local state = M.row_state(scope, row)
            local base = "env_row_" .. scope .. "_" .. tostring(position)
            ctx[base .. "_key"] = state.key
            ctx[base .. "_value"] = state.value
            ctx[base .. "_use_secret"] = state.use_secret and "true" or "false"
            ctx[base .. "_secret"] = state.secret
            row.bind_key = base .. "_key"
            row.bind_value = base .. "_value"
            row.bind_use_secret = base .. "_use_secret"
            row.bind_secret = base .. "_secret"
            row.use_secret = state.use_secret and "true" or "false"
            local rename_to, new_value = M.changes(row, state)
            row.dirty = (rename_to ~= nil or new_value ~= nil) and "true"
                or "false"
            -- Um secret que a variável usa mas que sumiu continua na lista,
            -- marcado, para a pessoa ver o que está gravado.
            if state.secret ~= "" and not known[state.secret] then
                known[state.secret] = true
                table.insert(missing, {
                    name = state.secret,
                    label = state.secret .. i18n.tr(" (não encontrado)"),
                })
            end
        end
    end
    local all_options = table.clone(options)
    for _, option in ipairs(missing) do
        table.insert(all_options, option)
    end
    ctx[OPTIONS_KEY[scope]] = Util.encode_array(all_options)
    ctx[LIST_KEY[scope]] = Util.encode_array(rows)
end

-- Os secrets que uma variável do escopo pode usar ({name, label}); republica a
-- lista.
function M.set_secret_options(scope: string, options: { any }): ()
    State.env_secret_options[scope] = options
    M.publish(scope)
end

-- Um campo da linha mudou (tecla, checkbox ou select): grava no rascunho e
-- republica.
function M.set_draft(scope: string, row: any, field: string, value: any): ()
    local id = draft_id(scope, tostring(row.key))
    local current = M.row_state(scope, row)
    local next_state: Draft = {
        key = current.key,
        value = current.value,
        use_secret = current.use_secret,
        secret = current.secret,
    }
    if field == "key" then
        next_state.key = tostring(value or "")
    elseif field == "value" then
        next_state.value = tostring(value or "")
    elseif field == "use_secret" then
        next_state.use_secret = Helpers.is_true(value)
    elseif field == "secret" then
        next_state.secret = tostring(value or "")
    end
    State.env_drafts[id] = next_state
    M.publish(scope)
end

-- Antes do OK gravar: recusa chave inválida e "usar secret" sem secret
-- escolhido, e pede confirmação listando o que muda. `footer` fecha a mensagem
-- ("Vale no próximo deploy.").
function M.confirm_save(
    key: string,
    row: any,
    rename_to: string?,
    new_value: any?,
    footer: string
): boolean
    if rename_to ~= nil and not Helpers.valid_env_key(rename_to) then
        toast {
            message = i18n.tr('Nome inválido: "')
                .. rename_to
                .. i18n.tr(
                    '" — use letras, dígitos e _, sem começar por dígito'
                ),
            kind = "error",
        }
        return false
    end
    if
        new_value ~= nil
        and new_value.Secret ~= nil
        and new_value.Secret == ""
    then
        toast { message = i18n.tr("escolha um secret"), kind = "warning" }
        return false
    end
    local lines = {}
    if new_value ~= nil and new_value.Secret ~= nil then
        table.insert(
            lines,
            i18n.tr('passa a usar o secret "') .. new_value.Secret .. '"'
        )
    elseif new_value ~= nil and row.kind == "secret" then
        table.insert(
            lines,
            i18n.tr('deixa de usar o secret "')
                .. tostring(row.secret_name)
                .. i18n.tr('" e passa a ter o valor digitado')
        )
    elseif new_value ~= nil then
        table.insert(lines, i18n.tr("o valor muda para o que foi digitado"))
    end
    if rename_to ~= nil then
        table.insert(
            lines,
            i18n.tr('a chave muda de "')
                .. key
                .. i18n.tr('" para "')
                .. rename_to
                .. '"'
        )
    end
    return confirm {
        title = i18n.tr("Salvar a variável?"),
        message = '"'
            .. key
            .. '":\n\n• '
            .. table.concat(lines, "\n• ")
            .. "\n\n"
            .. footer,
        confirm_label = i18n.tr("Salvar"),
    }
end

-- Desfaz o rascunho da linha (✕, ou depois de gravar).
function M.reset(scope: string, key: string): ()
    State.env_drafts[draft_id(scope, key)] = nil
    M.publish(scope)
end

return M
