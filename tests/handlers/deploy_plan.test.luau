--!nonstrict
-- "Deploy com dependências": start_deploy mostra o plano num `dialog` declarado (open_dialog) e os
-- botões dele (deploy_plan_accept / deploy_plan_only) executam a escolha. Sem `State.api` (a sessão
-- pode cair no instante do clique) todos têm de ser inertes. O harness roda cada componente numa VM
-- própria e não deixa injetar um api falso nela, então o caminho COM conexão (plano → dialog →
-- aceitar/só o serviço) não é coberto aqui.

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
    local alvo = tela:get("deploy_plan_service_id")
    assert_true(alvo == nil or alvo == "")
    assert_nil(tela:get("__dialog.plano"))
    assert_eq(#tela:toasts(), 0)
end

--- Aceitar e Só o serviço sem alvo guardado não fazem nada
function test_deploy_plan__botoes_sem_alvo_sao_inertes()
    local tela = nova({})
    tela:call("deploy_plan_accept")
    tela:call("deploy_plan_only")
    assert_eq(#tela:toasts(), 0)
end

--- com alvo mas sem sessão, também não fazem nada (nem toast)
function test_deploy_plan__botoes_sem_conexao_sao_inertes()
    local tela = nova({ deploy_plan_service_id = "svc_9" })
    tela:call("deploy_plan_accept")
    tela:call("deploy_plan_only")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("deploy_plan_service_id"), "svc_9")
end
