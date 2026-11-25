--!nonstrict
-- Painel "Descrição" da aba General (handlers/service_description.luau): grava
-- só com ServiceDescriptionSet, nada sem mudança, apagar tudo pede confirmação,
-- e um fetch do serviço não atropela o rascunho. O `State.api` é um falso
-- injetado com `tela:eval`; `confirm` suspende o handler e `tela:answer` o retoma.

local function nova()
    local tela = component("views/app.gv", {})
    tela:call("init")
    tela:set("selected_service", "svc_1")
    return tela
end

local function com_api(tela)
    tela:eval([[
        local State = require("state")
        State.enviados = {}
        State.api = {
            rpc_checked = function(_self, comando)
                local nome = next(comando)
                table.insert(State.enviados, comando[nome])
                local texto = comando[nome].description
                return true, { Service = { id = "svc_1", spec = {
                    name = "worker", description = texto ~= "" and texto or nil,
                } } }
            end,
            rpc = function() return false, "sem snapshot no teste" end,
        }
    ]])
end

local function carrega(tela, texto)
    tela:eval(
        string.format(
            [[ require("handlers/service_description").load("svc_1", %s) ]],
            texto and string.format("%q", texto) or "nil"
        )
    )
end

local function enviados(tela)
    tela:eval([[
        local State = require("state")
        ctx.lido = json.encode(State.enviados)
    ]])
    return json.decode(tela:get("lido"))
end

--- carregar põe o texto gravado no editor
function test_descricao__carrega_o_texto_gravado()
    local tela = nova()
    carrega(tela, "Processa a fila de e-mails.")
    assert_eq(tela:get("service_description"), "Processa a fila de e-mails.")
    carrega(tela, nil)
    assert_eq(tela:get("service_description"), "")
end

--- salvar manda só a descrição, aparada; sem mudança não manda nada
function test_descricao__salvar_manda_so_a_descricao()
    local tela = nova()
    com_api(tela)
    carrega(tela, "Antiga.")
    tela:call("service_description_save")
    assert_eq(#enviados(tela), 0)

    tela:set("service_description", "  Nova descrição.  ")
    tela:call("service_description_save")
    local lista = enviados(tela)
    assert_eq(#lista, 1)
    assert_eq(lista[1].service_id, "svc_1")
    assert_eq(lista[1].description, "Nova descrição.")
    assert_eq(tela:get("service_description_original"), "Nova descrição.")
end

--- apagar tudo pede confirmação; recusada, nada é gravado
function test_descricao__apagar_pede_confirmacao()
    local tela = nova()
    com_api(tela)
    carrega(tela, "Antiga.")
    tela:set("service_description", "   ")
    tela:call("service_description_save")
    tela:answer(false)
    assert_eq(#enviados(tela), 0)

    tela:call("service_description_save")
    tela:answer(true)
    local lista = enviados(tela)
    assert_eq(#lista, 1)
    assert_eq(lista[1].description, "")
end

--- um fetch do mesmo serviço não atropela o que está sendo digitado; outro
--- serviço troca; cancelar volta ao gravado
function test_descricao__fetch_nao_atropela_rascunho()
    local tela = nova()
    carrega(tela, "Gravada.")
    tela:set("service_description", "Digitando…")
    carrega(tela, "Gravada.")
    assert_eq(tela:get("service_description"), "Digitando…")
    tela:call("service_description_cancel")
    assert_eq(tela:get("service_description"), "Gravada.")
    tela:eval([[ require("handlers/service_description").load("svc_2", "Outro.") ]])
    assert_eq(tela:get("service_description"), "Outro.")
end
