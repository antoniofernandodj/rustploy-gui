--!strict

-- busy.luau — trava de "ação em andamento" para os handlers de on_click/on_submit.
--
-- `install(names)` troca cada função global listada por uma versão que, enquanto
-- roda (inclusive suspensa num `fetch`), mantém `ctx.busy_<nome> = "true"`:
--   • um novo disparo da MESMA ação nesse intervalo é ignorado (duplo clique);
--   • o template liga `disabled = @busy_<nome>` no botão, então ele fica
--     bloqueado na hora e volta assim que a ação termina — com sucesso, erro
--     de resposta ou timeout (o `fetch` tem teto em net/api.luau), e mesmo se
--     o handler lançar erro (o flag é limpo antes de relançar).
-- `install` também embrulha o `init()` para semear os flags (ver `seed`).
-- A lista vem de busy_actions.luau; só ações de botão/formulário entram (um
-- callback de sse ou uma `rule` bloqueada por reentrada perderia eventos).

local M = {}

function M.key(name: string): string
    return "busy_" .. name
end

-- Semeia `busy_<nome> = "false"` para toda ação instalada. O template liga
-- `disabled = @busy_<nome>`, e uma chave ausente não resolve. Roda dentro do
-- `init()` (ver `install`): o logout (`disconnect`) apaga o `ctx` inteiro e
-- chama `init()` de novo, então os flags renascem junto com os demais defaults.
local function seed(names: { string }): ()
    for _, name in names do
        ctx[M.key(name)] = "false"
    end
end

function M.install(names: { string }): ()
    local env = _G :: any
    local installed: { string } = {}

    for _, name in names do
        local fn = env[name]

        if type(fn) == "function" then
            local key = M.key(name)
            table.insert(installed, name)

            env[name] = function(...)
                if ctx[key] == "true" then
                    return
                end

                ctx[key] = "true"
                local res = table.pack(pcall(fn, ...))
                ctx[key] = "false"

                if not res[1] then
                    error(res[2], 0)
                end

                return table.unpack(res, 2, res.n)
            end
        end
    end

    local init = env.init
    env.init = function(...)
        seed(installed)

        if type(init) == "function" then
            return init(...)
        end
    end
end

return M
