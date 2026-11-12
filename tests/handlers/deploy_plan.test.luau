--!nonstrict
-- "Deploy com dependências": start_deploy mostra o plano num `dialog` declarado e decide pelo valor
-- que `open_dialog` devolve ("aceitar" | "so" | nil). Sem `State.api` (a sessão pode cair no instante
-- do clique) ele tem de ser inerte. O harness roda cada componente numa VM própria e não deixa
-- injetar um api falso nela, então o caminho COM conexão (plano → dialog → escolha) não é coberto
-- aqui; o contrato do `open_dialog`/`choice` é testado no glacier-ui (tests/dialog_actions.rs).

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem conexão, pedir o deploy não prepara dialog nenhum (nem toast)
function test_deploy_plan__sem_conexao_o_deploy_e_inerte()
    local tela = nova({})
    tela:call("running_deploy", "svc_1")
    tela:call("service_deploy")
    assert_nil(tela:get("__dialog.plano"))
    assert_eq(#tela:toasts(), 0)
end
