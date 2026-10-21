--!nonstrict
-- busy.luau envolve handlers globais numa trava: enquanto um roda, a chave
-- `busy_<nome>` do ctx fica "true" e um segundo disparo é descartado. Mexe em
-- `_G` e no global `ctx`, então cada teste usa nomes de handler próprios.

local Busy = require("busy")

local env = _G :: any

local function ambiente()
    env.ctx = {}
    env.toast = function() end
    env.init = nil
end

describe("busy", function()
    test("key monta o nome da chave", function()
        expect(Busy.key("salvar")):toBe("busy_salvar")
    end)

    test("a chave fica true durante o handler e false depois", function()
        ambiente()
        local durante
        env.h_um = function()
            durante = env.ctx.busy_h_um
        end
        Busy.install({ "h_um" })
        env.h_um()
        expect(durante):toBe("true")
        expect(env.ctx.busy_h_um):toBe("false")
    end)

    test("repassa argumentos e valores de retorno", function()
        ambiente()
        env.h_soma = function(a, b)
            return a + b, "ok"
        end
        Busy.install({ "h_soma" })
        local soma, estado = env.h_soma(2, 3)
        expect(soma):toBe(5)
        expect(estado):toBe("ok")
    end)

    test("um segundo disparo durante a execução é descartado", function()
        ambiente()
        local rodadas = 0
        env.h_reentrante = function()
            rodadas += 1
            env.h_reentrante() -- o clique duplo
        end
        Busy.install({ "h_reentrante" })
        env.h_reentrante()
        expect(rodadas):toBe(1)
    end)

    test("depois de terminar, o handler pode rodar de novo", function()
        ambiente()
        local rodadas = 0
        env.h_repete = function()
            rodadas += 1
        end
        Busy.install({ "h_repete" })
        env.h_repete()
        env.h_repete()
        expect(rodadas):toBe(2)
    end)

    test("erro no handler se propaga e mesmo assim solta a trava", function()
        ambiente()
        env.h_quebra = function()
            error("boom", 0)
        end
        Busy.install({ "h_quebra" })
        expect(function()
            env.h_quebra()
        end):toThrow("boom")
        expect(env.ctx.busy_h_quebra):toBe("false")
        -- e não ficou travado: um novo disparo chega a rodar (e quebrar de novo)
        expect(function()
            env.h_quebra()
        end):toThrow("boom")
    end)

    test("toast solta a trava de quem o chamou (a ação já deu o retorno)", function()
        ambiente()
        local depois
        env.h_avisa = function()
            env.toast({ message = "pronto" })
            depois = env.ctx.busy_h_avisa
        end
        Busy.install({ "h_avisa" })
        env.h_avisa()
        expect(depois):toBe("false")
    end)

    test("o toast original continua sendo chamado com as opções", function()
        ambiente()
        local recebido
        env.toast = function(opcoes)
            recebido = opcoes
        end
        env.h_toast = function()
            env.toast({ message = "oi" })
        end
        Busy.install({ "h_toast" })
        env.h_toast()
        expect(recebido.message):toBe("oi")
    end)

    test("init semeia false em todas as chaves e chama o init original", function()
        ambiente()
        local chamado = false
        env.init = function()
            chamado = true
        end
        env.h_a = function() end
        env.h_b = function() end
        Busy.install({ "h_a", "h_b" })
        env.init()
        expect(chamado):toBe(true)
        expect(env.ctx.busy_h_a):toBe("false")
        expect(env.ctx.busy_h_b):toBe("false")
    end)

    test("init funciona mesmo sem um init original", function()
        ambiente()
        env.h_c = function() end
        Busy.install({ "h_c" })
        env.init()
        expect(env.ctx.busy_h_c):toBe("false")
    end)

    test("nome sem função global não ganha trava nem semente", function()
        ambiente()
        env.h_existe = function() end
        env.h_nao_funcao = 42
        Busy.install({ "h_existe", "h_fantasma", "h_nao_funcao" })
        env.init()
        expect(env.ctx.busy_h_existe):toBe("false")
        expect(env.ctx.busy_h_fantasma):toBeNil()
        expect(env.ctx.busy_h_nao_funcao):toBeNil()
        expect(env.h_nao_funcao):toBe(42)
    end)
end)
