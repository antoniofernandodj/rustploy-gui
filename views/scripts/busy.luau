--!strict

-- busy.luau — trava de "ação em andamento" para os handlers de on_click/on_submit.
--
-- `install(names)` troca cada função global listada por uma versão que, enquanto
-- roda (inclusive suspensa num `fetch`), mantém `ctx.busy_<nome> = "true"`:
--   • um novo disparo da MESMA ação nesse intervalo é ignorado (duplo clique);
--   • o template liga `disabled = @busy_<nome>` no botão, então ele fica
--     bloqueado na hora e volta assim que a ação termina — com sucesso, erro
--     de resposta ou timeout (o `fetch` tem teto em net/api.luau), e mesmo se
--     o handler lançar erro (o flag é limpo antes de relançar);
--   • o botão libera no PRIMEIRO `toast` da própria ação — é o aviso de que a
--     resposta chegou. Depois dele o handler ainda costuma reler serviço/
--     histórico/snapshot (mais rpcs); esperar isso deixaria o botão travado
--     segundos além da resposta. A ação é identificada pela corrotina
--     (`coroutine.running()`), então toasts de outras ações não interferem.
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

-- Quem está rodando: `running[nome] = corrotina dona`; `held[corrotina]` =
-- chaves que ela segura (uma ação pode chamar outra, também embrulhada).
-- Código Lua que chama um handler direto (sem corrotina própria) roda na
-- principal, onde `coroutine.running()` é nil: `MAIN` é o dono dessas chamadas.
local MAIN = {}
local running: { [string]: any } = {}
local held: { [any]: { string } } = {}

local function owner(): any
    return coroutine.running() or MAIN
end

local function release(thread: any): ()
    local keys = held[thread]

    if keys then
        for _, key in keys do
            if running[key] == thread then
                running[key] = nil
                ctx[key] = "false"
            end
        end
    end
end

function M.install(names: { string }): ()
    local env = _G :: any
    local installed: { string } = {}

    for _, name in names do
        local handler_function = env[name]

        if type(handler_function) == "function" then
            local key = M.key(name)
            table.insert(installed, name)

            env[name] = function(...)
                if running[key] then
                    return
                end

                local thread = owner()
                running[key] = thread
                ctx[key] = "true"
                held[thread] = held[thread] or {}
                table.insert(held[thread], key)

                local call_results = table.pack(pcall(handler_function, ...))

                -- Larga só a chave DESTA ação (a externa, se houver, segue presa).
                if running[key] == thread then
                    running[key] = nil
                    ctx[key] = "false"
                end

                local keys = held[thread]
                if keys then
                    table.remove(keys, table.find(keys, key))
                    if #keys == 0 then
                        held[thread] = nil
                    end
                end

                if not call_results[1] then
                    error(call_results[2], 0)
                end

                return table.unpack(call_results, 2, call_results.n)
            end
        end
    end

    local real_toast = env.toast
    env.toast = function(toast_options)
        release(owner())

        return real_toast(toast_options)
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
