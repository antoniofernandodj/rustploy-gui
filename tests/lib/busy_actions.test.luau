--!nonstrict
-- A lista de ações com trava é mantida por `tools/busy_actions.py --check`
-- contra os templates; este teste guarda o que o script não olha: que ela é
-- uma lista de nomes de handler bem formada.

local Actions = require("busy_actions")

--- não está vazia
function test_nao_esta_vazia()
    assert_eq(#Actions > 50, true)
end

--- só tem nomes de função válidos em Luau
function test_so_tem_nomes_de_funcao_validos_em_luau()
    for _, nome in Actions do
        assert_eq(type(nome), "string")
        assert_match(nome, "^[%a_][%w_]*$")
    end
end

--- não repete nome (a segunda trava envolveria a primeira)
function test_nao_repete_nome_a_segunda_trava_envolveria_a_primeira()
    local vistos = {}
    for _, nome in Actions do
        assert_ne(vistos[nome], true)
        vistos[nome] = true
    end
end

--- está em ordem alfabética, para o diff do --check ser legível
function test_esta_em_ordem_alfabetica_para_o_diff_do_check_ser_legivel()
    for i = 2, #Actions do
        assert_eq(Actions[i - 1] < Actions[i], true)
    end
end
