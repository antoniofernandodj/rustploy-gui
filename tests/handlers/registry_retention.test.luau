--!nonstrict
-- Retenção de tags do registry: o botão Salvar da sub-aba Docker > Registry.
-- Sem `State.api` o handler tem de ser inerte (a conexão pode cair no instante do clique).

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem conexão, salvar não faz nada (nem mensagem, nem toast)
function test_registry_retention__salvar_sem_conexao_e_inerte()
    local tela = nova({
        registry_retention_form_enabled = "true",
        registry_retention_form_keep_last = "5",
        registry_message = "",
    })
    tela:call("registry_retention_save")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("registry_message"), "")
end
