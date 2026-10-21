--!nonstrict
-- A lista de ações com trava é mantida por `tools/busy_actions.py --check`
-- contra os templates; este teste guarda o que o script não olha: que ela é
-- uma lista de nomes de handler bem formada.

local Actions = require("busy_actions")

describe("busy_actions", function()
    test("não está vazia", function()
        expect(#Actions > 50):toBe(true)
    end)

    test("só tem nomes de função válidos em Luau", function()
        for _, nome in Actions do
            expect(type(nome)):toBe("string")
            expect(nome):toMatch("^[%a_][%w_]*$")
        end
    end)

    test("não repete nome (a segunda trava envolveria a primeira)", function()
        local vistos = {}
        for _, nome in Actions do
            expect(vistos[nome]).never:toBe(true)
            vistos[nome] = true
        end
    end)

    test("está em ordem alfabética, para o diff do --check ser legível", function()
        for i = 2, #Actions do
            expect(Actions[i - 1] < Actions[i]):toBe(true)
        end
    end)
end)
