--!nonstrict
-- Edição no lugar da chave/valor de uma variável (handlers/secrets.luau), sem conexão.

local function nova()
    local tela = component("views/app.gv")
    tela:call("init")
    return tela
end

local LINHAS = '[{"key":"A","value":"1","kind":"plain","secret_name":""},'
    .. '{"key":"SENHA","value":"🔒 secret:DB_PASS","kind":"secret","secret_name":"DB_PASS"}]'

--- ✏️ arma o campo da CHAVE na própria linha, com a chave atual como rascunho
function test_edicao_no_lugar__a_chave_comeca_com_a_chave_atual()
    local tela = nova()
    tela:set("project_env", LINHAS)
    tela:call("project_env_edit_key", "A")
    assert_eq(tela:get("env_edit_id"), "key:A")
    assert_eq(tela:get("env_edit_draft"), "A")
    assert_eq(tela:get("env_edit_scope"), "project")
end

--- ✎ arma o campo do VALOR: em claro mostra o valor; secret mostra a referência, nunca o valor
function test_edicao_no_lugar__o_valor_comeca_com_o_valor_ou_a_referencia_do_secret()
    local tela = nova()
    tela:set("project_env", LINHAS)
    tela:call("project_env_edit_value", "A")
    assert_eq(tela:get("env_edit_id"), "value:A")
    assert_eq(tela:get("env_edit_draft"), "1")
    assert_eq(tela:get("env_edit_was_secret"), "false")

    tela:call("project_env_edit_value", "SENHA")
    assert_eq(tela:get("env_edit_id"), "value:SENHA")
    assert_eq(tela:get("env_edit_draft"), "secret:DB_PASS")
    assert_eq(tela:get("env_edit_was_secret"), "true")
end

--- a variável do serviço usa o escopo do serviço
function test_edicao_no_lugar__o_escopo_do_servico()
    local tela = nova()
    tela:set("service_env", LINHAS)
    tela:call("service_env_edit_value", "A")
    assert_eq(tela:get("env_edit_scope"), "service")
    assert_eq(tela:get("env_edit_id"), "value:A")
end

--- uma chave que não existe na lista não arma nada
function test_edicao_no_lugar__chave_inexistente_nao_arma_nada()
    local tela = nova()
    tela:set("project_env", LINHAS)
    tela:call("project_env_edit_key", "NADA")
    assert_eq(tela:get("env_edit_id") or "", "")
end

--- ✕ desiste e limpa o rascunho
function test_edicao_no_lugar__cancelar_limpa_tudo()
    local tela = nova()
    tela:set("project_env", LINHAS)
    tela:call("project_env_edit_key", "A")
    tela:call("env_edit_cancel")
    assert_eq(tela:get("env_edit_id"), "")
    assert_eq(tela:get("env_edit_draft"), "")
    assert_eq(tela:get("env_edit_scope"), "")
end

--- sem conexão, gravar não faz nada e não perde o que foi digitado
function test_edicao_no_lugar__sem_conexao_o_rascunho_fica()
    local tela = nova()
    tela:set("project_env", LINHAS)
    tela:call("project_env_edit_value", "A")
    tela:set("env_edit_draft", "novo")
    tela:call("env_edit_apply")
    assert_eq(tela:get("env_edit_id"), "value:A")
    assert_eq(tela:get("env_edit_draft"), "novo")
end
