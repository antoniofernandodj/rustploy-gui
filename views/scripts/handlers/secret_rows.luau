--!strict
-- handlers/secret_rows.luau — o NOME do secret editável no lugar, nas listas de secrets do projeto
-- (shell/project_secrets.component.gv), do serviço (service/environment.component.gv) e do job
-- (components/job_env_panel.component.gv, que também roda na janela Novo/Editar job — por isso este
-- módulo só depende de helpers).
--
-- Igual ao nome do projeto e do serviço: um campo sem borda, sem botão "Renomear". Cada tecla
-- reinicia um timer; meio segundo depois da última, o secret é renomeado (SecretRename — o valor
-- cifrado não passa pela tela). Nome vazio ou igual ao atual não grava; um erro (nome já usado)
-- avisa e devolve o campo ao nome gravado.
--
-- Como um campo de uma linha do `each` se liga ao contexto: o glacier lê o valor de um input numa
-- chave do `ctx`, não num campo do item. Então cada linha ganha a sua chave
-- (`secret_row_<escopo>_<posição>`) e o item carrega o NOME dela em `bind_name`, que o .gv usa em
-- `:value = "@s.bind_name"`. O texto digitado e ainda não gravado mora em `drafts` (por escopo e
-- nome), não no ctx: o snapshot que chega a cada segundo republica a lista sem apagar o que a pessoa
-- está digitando.

local Helpers = require("../helpers")

local M = {}

local SAVE_DELAY_MS = 500

local drafts: { [string]: string } = {}
local timers: { [string]: any } = {}

local function draft_id(scope: string, name: string): string
    return scope .. "\0" .. name
end

-- Recebe o JSON de `format.secret_rows` e devolve o mesmo com `bind_name` em cada linha, depois de
-- gravar no ctx o texto de cada campo (o rascunho, se houver; senão o nome gravado).
function M.bind(scope: string, rows_json: string): string
    local ok, rows = pcall(json.decode, rows_json)
    if not ok or type(rows) ~= "table" then
        return rows_json
    end
    for position, row in ipairs(rows) do
        local key = "secret_row_" .. scope .. "_" .. tostring(position)
        local name = tostring(row.name or "")
        ctx[key] = drafts[draft_id(scope, name)] or name
        row.bind_name = key
    end
    return json.encode(json.array(rows))
end

-- A chave do ctx do campo do secret `name` na lista publicada em `ctx[list_key]`.
local function bind_key_of(list_key: string, name: string): string?
    local ok, rows = pcall(json.decode, tostring(ctx[list_key] or ""))
    if not ok or type(rows) ~= "table" then
        return nil
    end
    for _, row in ipairs(rows) do
        if row.name == name then
            return row.bind_name
        end
    end
    return nil
end

-- `on_change` do campo: guarda o rascunho e (re)agenda a gravação. `list_key` é a chave do ctx com
-- a lista (`project_secrets`…); `rename(from, to)` faz o SecretRename do escopo e devolve se deu
-- certo — quem chama recarrega a lista.
function M.change(
    scope: string,
    list_key: string,
    name: string,
    value: string,
    rename: (from: string, to: string) -> boolean
): ()
    local bind_key = bind_key_of(list_key, name)
    local id = draft_id(scope, name)
    drafts[id] = value
    if bind_key then
        ctx[bind_key] = value
    end
    if timers[id] then
        timers[id]:cancel()
    end
    timers[id] = after(SAVE_DELAY_MS, function(): ()
        timers[id] = nil
        local to = Helpers.trim(drafts[id])
        if to == "" or to == name then
            -- Vazio nunca é gravado; igual ao atual não muda nada. O campo fica como está até o
            -- próximo refresh (vazio volta ao nome gravado).
            if to == name then
                drafts[id] = nil
            end
            return
        end
        if rename(name, to) then
            drafts[id] = nil
            toast {
                message = i18n.tr("Renomeado: ") .. name .. " → " .. to,
                kind = "success",
            }
        else
            drafts[id] = nil
            if bind_key then
                ctx[bind_key] = name
            end
        end
    end)
end

return M
