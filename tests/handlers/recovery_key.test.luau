--!nonstrict
-- Settings → Chave de recuperação: sem conexão os handlers são inertes, a tela nasce sem chave, e
-- "Guardei" esquece a privada da memória da tela.

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem sessão, gerar não faz nada (nem toast, nem privada na tela)
function test_recovery_key__sem_conexao_e_inerte()
    local tela = nova({})
    tela:call("recovery_key_generate")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("recovery_key_generated"), "false")
    assert_eq(tela:get("recovery_key_private"), "")
end

--- "Guardei em lugar seguro" apaga a privada e o conteúdo do arquivo do estado da tela
function test_recovery_key__dismiss_esquece_a_privada()
    local tela = nova({
        recovery_key_generated = "true",
        recovery_key_private = "AGE-SECRET-KEY-1ABC",
        recovery_key_contents = "# x\nAGE-SECRET-KEY-1ABC",
    })
    tela:call("recovery_key_dismiss")
    assert_eq(tela:get("recovery_key_generated"), "false")
    assert_eq(tela:get("recovery_key_private"), "")
    assert_eq(tela:get("recovery_key_contents"), "")
end
