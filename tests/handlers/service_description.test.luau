--!nonstrict
-- Descrição do serviço no cabeçalho (handlers/service_description.luau): grava
-- sozinha depois do debounce, sem botão e sem confirmação; o `State.api` é um
-- falso injetado com `tela:eval`, e `glacier test` não dispara os `after` — por
-- isso a gravação é exercitada por `service_description_flush`.

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

local function carrega(tela, texto, service_id)
    tela:eval(
        string.format(
            [[ require("handlers/service_description").load(%s, %s) ]],
            string.format("%q", service_id or "svc_1"),
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

--- digitar não grava na hora: é o debounce que segura a escrita
function test_descricao__digitar_nao_grava_na_hora()
    local tela = nova()
    com_api(tela)
    carrega(tela, "Antiga.")
    tela:call("service_description_change", "Nova descrição.")
    assert_eq(tela:get("service_description"), "Nova descrição.")
    assert_eq(#enviados(tela), 0, "o save sai do timer, não da tecla")
end

--- grava só a descrição, aparada; sem mudança não manda nada
function test_descricao__flush_manda_so_a_descricao()
    local tela = nova()
    com_api(tela)
    carrega(tela, "Antiga.")
    tela:call("service_description_change", "  Nova descrição.  ")
    tela:call("service_description_flush")
    local lista = enviados(tela)
    assert_eq(#lista, 1)
    assert_eq(lista[1].service_id, "svc_1")
    assert_eq(lista[1].description, "Nova descrição.")
    assert_eq(tela:get("service_description_original"), "Nova descrição.")
    assert_true(tela:get("service_description_message") ~= "")

    tela:call("service_description_flush")
    assert_eq(#enviados(tela), 1, "nada mudou: nada a gravar")
end

--- esvaziar grava direto, sem diálogo
function test_descricao__esvaziar_grava_sem_confirmacao()
    local tela = nova()
    com_api(tela)
    carrega(tela, "Antiga.")
    tela:call("service_description_change", "   ")
    tela:call("service_description_flush")
    local lista = enviados(tela)
    assert_eq(#lista, 1)
    assert_eq(lista[1].description, "")
end

--- um fetch durante o debounce não atropela o que está sendo digitado; outro
--- serviço troca o campo
function test_descricao__fetch_nao_atropela_rascunho()
    local tela = nova()
    carrega(tela, "Gravada.")
    tela:call("service_description_change", "Digitando…")
    carrega(tela, "Gravada.")
    assert_eq(tela:get("service_description"), "Digitando…")
    tela:eval([[ require("handlers/service_description").load("svc_2", "Outro.") ]])
    assert_eq(tela:get("service_description"), "Outro.")
end
