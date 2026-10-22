--!strict
-- handlers/history.luau — a pilha do "voltar" (Backspace, Alt+← e o botão
-- "voltar" do mouse; o motor chama `on_back()`, em nav.luau).
--
-- O app tem UMA tela: a visão, o serviço, o projeto e as abas são chaves do
-- `ctx`, e a pilha de telas do motor fica sempre vazia. Quem sabe o caminho
-- percorrido é este módulo: cada troca de visão empilha um retrato dessas
-- chaves ANTES de mudá-las, e voltar desempilha e restaura.
--
-- Telas com dados buscados (o detalhe de um serviço, a lista de um projeto)
-- não se restauram só pelas chaves — o `ctx` ainda guarda o detalhe do ÚLTIMO
-- serviço aberto. Quem as abre registra um `register(view, restaurar)` que as
-- reabre pelo mesmo caminho do clique; durante o voltar `replaying` impede que
-- essa reabertura empilhe de novo.

local History = {}

type Snapshot = { [string]: string }

local KEYS = {
    "view",
    "selected_service",
    "selected_project_id",
    "tab",
    "project_tab",
    "docker_tab",
    "deploy_engine_tab",
    "settings_tab",
}
local MAX_DEPTH = 50

local stack: { Snapshot } = {}
local restorers: { [string]: (Snapshot) -> () } = {}
local replaying = false

local function snapshot(): Snapshot
    local snap: Snapshot = {}
    local data = ctx :: { [string]: any }
    for _, key in ipairs(KEYS) do
        snap[key] = tostring(data[key] or "")
    end
    return snap
end

local function same(a: Snapshot, b: Snapshot): boolean
    for _, key in ipairs(KEYS) do
        if a[key] ~= b[key] then
            return false
        end
    end
    return true
end

--- Empilha o estado atual. Chame ANTES de mudar `view` e companhia.
function History.push(): ()
    if replaying then
        return
    end
    local snap = snapshot()
    if snap.view == "" then
        return
    end
    local top = stack[#stack]
    if top and same(top, snap) then
        return
    end
    table.insert(stack, snap)
    if #stack > MAX_DEPTH then
        table.remove(stack, 1)
    end
end

--- Reabre a visão `view` pelo caminho do clique (ver o cabeçalho).
function History.register(view: string, restore: (Snapshot) -> ()): ()
    restorers[view] = restore
end

--- Volta uma visão. `false` se a pilha estava vazia.
function History.back(): boolean
    local snap = table.remove(stack)
    if not snap then
        return false
    end
    replaying = true
    local ok, err = pcall(function()
        local restore = restorers[snap.view]
        if restore then
            restore(snap)
        else
            local data = ctx :: { [string]: any }
            for _, key in ipairs(KEYS) do
                data[key] = snap[key]
            end
        end
    end)
    replaying = false
    if not ok then
        error(err, 0)
    end
    return true
end

--- Esquece os retratos que apontam para `id` em `key` (o item foi removido).
function History.drop(key: string, id: string): ()
    for i = #stack, 1, -1 do
        if stack[i][key] == id then
            table.remove(stack, i)
        end
    end
end

function History.clear(): ()
    stack = {}
end

function History.size(): number
    return #stack
end

return History
