--!nonstrict
-- Painel ⋯ dos jobs (`components/job_actions.component.gv`): Remover e Reconstruir pedem confirmação,
-- e o painel tem de fechar ANTES dela. O painel é uma camada flutuante e ficava por cima da janela de
-- confirmação, escondendo-a (achado em 2026-11-14). `confirm` suspende o handler; `tela:answer` o
-- retoma, então dá para olhar o estado no meio, com a confirmação na tela.

local function nova()
    local tela = component("views/app.gv", {})
    tela:call("init")
    tela:eval([[
        local State = require("state")
        State.enviados = {}
        State.jobs_by_id = { job_1 = { id = "job_1", name = "bucket" } }
        State.api = {
            rpc_checked = function(_self, comando)
                table.insert(State.enviados, (next(comando)))
                return true, {}
            end,
            rpc = function() return false, "sem snapshot no teste" end,
        }
        ctx.job_actions_open_job_1 = "true"
    ]])
    return tela
end

local function enviados(tela)
    tela:eval([[ ctx.enviados = table.concat(require("state").enviados, ",") ]])
    return tela:get("enviados")
end

--- Remover: com a confirmação aberta, o painel já fechou; cancelar não manda nada
function test_job_delete__painel_fecha_antes_da_confirmacao()
    local tela = nova()
    tela:call("job_delete", "job_1")
    assert_eq(tela:get("job_actions_open_job_1"), "", "o painel ficaria por cima da confirmação")
    tela:answer(false)
    assert_eq(enviados(tela), "")
end

--- Remover: confirmar manda JobDelete
function test_job_delete__confirmar_remove()
    local tela = nova()
    tela:call("job_delete", "job_1")
    tela:answer(true)
    assert_eq(enviados(tela), "JobDelete")
end

--- Reconstruir sem cache: o mesmo painel, a mesma regra
function test_job_rebuild__painel_fecha_antes_da_confirmacao()
    local tela = nova()
    tela:call("job_rebuild", "job_1")
    assert_eq(tela:get("job_actions_open_job_1"), "", "o painel ficaria por cima da confirmação")
    tela:answer(true)
    assert_eq(enviados(tela), "JobWarm")
end
