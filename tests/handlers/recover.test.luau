--!nonstrict
-- Settings → Recuperar: sem conexão os handlers são inertes (o botão pode ser clicado quando a sessão cai),
-- o formulário nasce vazio, e a linha de cada serviço traz o que a tela precisa.

local Recover = require("handlers/recover")

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem sessão, nada acontece (nem toast) e a chave NÃO é apagada: não houve envio
function test_recover__sem_conexao_e_inerte()
    local tela =
        nova({ recover_key = "AGE-SECRET-KEY-1ABC", recover_token = "tok" })
    tela:call("recover_start")
    tela:call("recover_run")
    tela:call("recover_cancel")
    tela:call("recover_refresh")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("recover_key"), "AGE-SECRET-KEY-1ABC")
end

--- a tela nasce no estado "nada em curso", com o formulário vazio
function test_recover__estado_inicial()
    local tela = nova({})
    assert_eq(tela:get("recover_phase"), "idle")
    assert_eq(tela:get("recover_services_count"), "0")
    assert_eq(tela:get("recover_key"), "")
    assert_eq(tela:get("recover_token"), "")
end

--- a linha de um serviço: banco/volume, projeto/nome, backup achado (ou "sobe vazio") e a etapa
function test_recover__linha_do_servico()
    local banco = Recover.service_row({
        kind = "database",
        name = "banco",
        project = "loja",
        latest_backup = "2026-11-11T13:44:06Z",
        step = "restoring",
    })
    assert_eq(banco.kind, "BD")
    assert_eq(banco.who, "loja / banco")
    assert_true(
        string.find(banco.backup, "2026-11-11T13:44:06Z", 1, true) ~= nil
    )

    local web = Recover.service_row({
        kind = "volume",
        name = "web",
        project = "loja",
        step = "failed",
        error = "deu ruim",
    })
    assert_eq(web.kind, "VOL")
    assert_true(string.find(web.step, "deu ruim", 1, true) ~= nil)
    assert_true(
        string.find(web.backup, "vazio", 1, true) ~= nil
            or string.find(web.backup, "empty", 1, true) ~= nil
    )
end

--- etapa desconhecida aparece como veio (nunca some)
function test_recover__etapa_desconhecida_aparece_como_veio()
    assert_eq(Recover.step_label("etapa-nova"), "etapa-nova")
end
