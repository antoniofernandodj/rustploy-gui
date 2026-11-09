--!nonstrict
-- Aba Dados: sem conexão os handlers são inertes (o botão pode ser clicado quando a sessão cai).

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem sessão, exportar, conferir e importar não fazem nada
function test_dados_sem_conexao__nada_acontece()
    local tela = nova({ selected_service = "svc_1", data_file_path = "/tmp/x.rpdata" })
    tela:call("data_preview")
    tela:call("data_confirm")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("data_preview_text") or "", "")
end
