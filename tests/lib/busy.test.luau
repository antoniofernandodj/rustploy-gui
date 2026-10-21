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

--- key monta o nome da chave
function test_key_monta_o_nome_da_chave()
    assert_eq(Busy.key("salvar"), "busy_salvar")
end

--- a chave fica true durante o handler e false depois
function test_a_chave_fica_true_durante_o_handler_e_false_depois()
    ambiente()
    local durante
    env.h_um = function()
        durante = env.ctx.busy_h_um
    end
    Busy.install({ "h_um" })
    env.h_um()
    assert_eq(durante, "true")
    assert_eq(env.ctx.busy_h_um, "false")
end

--- repassa argumentos e valores de retorno
function test_repassa_argumentos_e_valores_de_retorno()
    ambiente()
    env.h_soma = function(a, b)
        return a + b, "ok"
    end
    Busy.install({ "h_soma" })
    local soma, estado = env.h_soma(2, 3)
    assert_eq(soma, 5)
    assert_eq(estado, "ok")
end

--- um segundo disparo durante a execução é descartado
function test_um_segundo_disparo_durante_a_execucao_e_descartado()
    ambiente()
    local rodadas = 0
    env.h_reentrante = function()
        rodadas += 1
        env.h_reentrante() -- o clique duplo
    end
    Busy.install({ "h_reentrante" })
    env.h_reentrante()
    assert_eq(rodadas, 1)
end

--- depois de terminar, o handler pode rodar de novo
function test_depois_de_terminar_o_handler_pode_rodar_de_novo()
    ambiente()
    local rodadas = 0
    env.h_repete = function()
        rodadas += 1
    end
    Busy.install({ "h_repete" })
    env.h_repete()
    env.h_repete()
    assert_eq(rodadas, 2)
end

--- erro no handler se propaga e mesmo assim solta a trava
function test_erro_no_handler_se_propaga_e_mesmo_assim_solta_a_trava()
    ambiente()
    env.h_quebra = function()
        error("boom", 0)
    end
    Busy.install({ "h_quebra" })
    assert_fails(function()
        env.h_quebra()
    end, "boom")
    assert_eq(env.ctx.busy_h_quebra, "false")
    -- e não ficou travado: um novo disparo chega a rodar (e quebrar de novo)
    assert_fails(function()
        env.h_quebra()
    end, "boom")
end

--- toast solta a trava de quem o chamou (a ação já deu o retorno)
function test_toast_solta_a_trava_de_quem_o_chamou_a_acao_ja_deu_o_retorno()
    ambiente()
    local depois
    env.h_avisa = function()
        env.toast({ message = "pronto" })
        depois = env.ctx.busy_h_avisa
    end
    Busy.install({ "h_avisa" })
    env.h_avisa()
    assert_eq(depois, "false")
end

--- o toast original continua sendo chamado com as opções
function test_o_toast_original_continua_sendo_chamado_com_as_opcoes()
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
    assert_eq(recebido.message, "oi")
end

--- init semeia false em todas as chaves e chama o init original
function test_init_semeia_false_em_todas_as_chaves_e_chama_o_init_original()
    ambiente()
    local chamado = false
    env.init = function()
        chamado = true
    end
    env.h_a = function() end
    env.h_b = function() end
    Busy.install({ "h_a", "h_b" })
    env.init()
    assert_eq(chamado, true)
    assert_eq(env.ctx.busy_h_a, "false")
    assert_eq(env.ctx.busy_h_b, "false")
end

--- init funciona mesmo sem um init original
function test_init_funciona_mesmo_sem_um_init_original()
    ambiente()
    env.h_c = function() end
    Busy.install({ "h_c" })
    env.init()
    assert_eq(env.ctx.busy_h_c, "false")
end

--- nome sem função global não ganha trava nem semente
function test_nome_sem_funcao_global_nao_ganha_trava_nem_semente()
    ambiente()
    env.h_existe = function() end
    env.h_nao_funcao = 42
    Busy.install({ "h_existe", "h_fantasma", "h_nao_funcao" })
    env.init()
    assert_eq(env.ctx.busy_h_existe, "false")
    assert_nil(env.ctx.busy_h_fantasma)
    assert_nil(env.ctx.busy_h_nao_funcao)
    assert_eq(env.h_nao_funcao, 42)
end
