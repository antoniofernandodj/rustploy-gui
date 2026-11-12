--!nonstrict
-- "Deploy com dependências": start_deploy pede o plano ao daemon, mostra a ordem num `dialog`
-- declarado (app.gv) e decide pelo valor que `open_dialog` devolve ("aceitar" | "so" | nil).
-- O `State.api` é um falso injetado na VM da tela com `tela:eval` (cada `component()` tem a sua VM:
-- um `require("state")` daqui devolveria outra tabela). Ele registra os comandos enviados ao daemon.
--
-- `open_dialog` suspende e o harness não resolve diálogos: o handler PARA nele. Por isso estes testes
-- cobrem tudo até o diálogo abrir (o plano pedido e semeado, nada deployado antes da escolha) e os
-- caminhos que nem chegam a ele; a decisão pelo valor devolvido (aceitar / só o serviço / nil) é o
-- contrato do `open_dialog`/`choice`, testado no glacier-ui (tests/dialog_actions.rs).

local function nova()
    local tela = component("views/app.gv", {})
    tela:call("init")
    return tela
end

-- Injeta o api falso. `respostas` é código Luau de uma tabela { Comando = resposta }.
local function com_api(tela, respostas)
    tela:eval([[
        local State = require("state")
        local respostas = ]] .. respostas .. [[

        State.enviados = {}
        State.last_pairs = {}
        State.api = {
            rpc_checked = function(_self, comando)
                local nome = next(comando)
                table.insert(State.enviados, nome)
                local r = respostas[nome]
                if r == nil then
                    return false, "sem resposta no teste"
                end
                return true, r
            end,
        }
    ]])
end

-- Os comandos enviados ao daemon, na ordem, separados por vírgula.
local function enviados(tela)
    tela:eval([[ ctx.enviados = table.concat(require("state").enviados, ",") ]])
    return tela:get("enviados")
end

local PLANO_3 = [[{
    DeployWithDependenciesPlan = { DeployBatch = {
        { service_name = "db", status = "Queued" },
        { service_name = "api", status = "Queued" },
        { service_name = "worker", status = "Queued" },
    } },
}]]

--- sem conexão, pedir o deploy não prepara dialog nenhum (nem toast)
function test_deploy_plan__sem_conexao_o_deploy_e_inerte()
    local tela = nova()
    tela:call("running_deploy", "svc_1")
    tela:call("service_deploy")
    assert_nil(tela:get("__dialog.plano"))
    assert_eq(#tela:toasts(), 0)
end

--- com dependências: pede o plano, semeia a ordem no corpo e para no diálogo, sem deployar nada
function test_deploy_plan__com_dependencias_semeia_o_plano_e_espera_a_escolha()
    local tela = nova()
    com_api(tela, PLANO_3)
    tela:call("running_deploy", "svc_1")
    assert_eq(enviados(tela), "DeployWithDependenciesPlan")
    assert_eq(tela:get("__dialog.plano"), "1. db\n2. api\n3. worker")
    assert_eq(#tela:toasts(), 0)
end

--- o plano marca ao lado do nome o que não entra na fila
function test_deploy_plan__ordem_indica_o_que_nao_entra_na_fila()
    local tela = nova()
    com_api(tela, [[{
        DeployWithDependenciesPlan = { DeployBatch = {
            { service_name = "db", status = "Running" },
            { service_name = "api", status = "Queued" },
        } },
    }]])
    tela:call("running_deploy", "svc_1")
    assert_eq(tela:get("__dialog.plano"), "1. db (running)\n2. api")
end

--- sem dependências (plano de um item só): o deploy simples de sempre, sem abrir diálogo
function test_deploy_plan__sem_dependencias_vai_direto_ao_deploy_simples()
    local tela = nova()
    com_api(tela, [[{
        DeployWithDependenciesPlan = { DeployBatch = { { service_name = "api", status = "Queued" } } },
        DeployStart = { Deployment = { id = "d1", state = "Queued" } },
    }]])
    tela:call("running_deploy", "svc_1")
    assert_eq(enviados(tela), "DeployWithDependenciesPlan,DeployStart")
    assert_nil(tela:get("__dialog.plano"))
    tela:eval([[ ctx.alvo = require("state").deploy_track.service_id ]])
    assert_eq(tela:get("alvo"), "svc_1")
end

--- plano indisponível (erro do daemon): também cai no deploy simples
function test_deploy_plan__plano_com_erro_cai_no_deploy_simples()
    local tela = nova()
    com_api(tela, [[{ DeployStart = { Deployment = { id = "d1", state = "Queued" } } }]])
    tela:call("running_deploy", "svc_1")
    assert_eq(enviados(tela), "DeployWithDependenciesPlan,DeployStart")
    assert_nil(tela:get("__dialog.plano"))
end
