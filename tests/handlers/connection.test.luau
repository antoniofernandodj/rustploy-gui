--!nonstrict
-- Sessão e login (handlers/connection.luau). Nada aqui conecta de verdade nem
-- grava o `storage`: forget_server e o caminho de sucesso do connect gravam a
-- lista de servidores salvos da MÁQUINA, e um teste não pode apagar a sua.
--
-- O login lembrado vem do `storage`, então todo teste que roda o `init` semeia
-- um `access_key` próprio — senão o pré-preenchimento dependeria de quem roda.

local AccessKey = require("access_key")

local CHAVE = AccessKey.encode("https://zz-teste.invalid:1", "tok")

local function nova(ctx_inicial)
    local semente = { access_key = CHAVE }
    for k, v in ctx_inicial or {} do
        semente[k] = v
    end
    local tela = component("views/app.gvb", semente)
    tela:call("init")
    return tela
end

--- a janela nasce no login, na visão de deployments, desconectada
function test_connection_init__a_janela_nasce_no_login_na_visao_de_deployments_desconectada()
    local tela = nova()
    assert_eq(tela:get("screen"), "login")
    assert_eq(tela:get("view"), "deployments")
    assert_eq(tela:get("connected"), "false")
    assert_eq(tela:get("status_line"), "pronto para conectar")
    assert_eq(tela:get("menu"), "true")
    assert_eq(tela:get("search"), "")
    assert_eq(tela:get("error"), "")
end

--- o init não pisa no que já estava no contexto
function test_connection_init__o_init_nao_pisa_no_que_ja_estava_no_contexto()
    local tela = nova({ view = "docker", menu = "false", search = "api", status_line = "x" })
    assert_eq(tela:get("view"), "docker")
    assert_eq(tela:get("menu"), "false")
    assert_eq(tela:get("search"), "api")
    assert_eq(tela:get("status_line"), "x")
end

--- as listas nascem como [] e não nil (o for-each não pode ler literal)
function test_connection_init__as_listas_nascem_como_e_nao_nil_o_for_each_nao_pode_ler_literal()
    local tela = nova()
    for _, chave in { "deployments", "projects", "services", "service_rows", "docker_images", "jobs_summary", "running", "project_services" } do
        assert_eq(tela:get(chave), "[]")
    end
end

--- os contadores nascem … e não 0: 0 afirmaria vazio antes do primeiro snapshot
function test_connection_init__os_contadores_nascem_e_nao_0_0_afirmaria_vazio_antes_do_primeiro_snapshot()
    local tela = nova()
    for _, chave in { "projects_count", "services_count", "jobs_count", "docker_images_count", "services_running", "deploy_engine_total_24h" } do
        assert_eq(tela:get(chave), "…")
    end
    assert_eq(tela:get("data_loading"), "true")
end

--- o contador já publicado não é trocado por …
function test_connection_init__o_contador_ja_publicado_nao_e_trocado_por()
    local tela = nova({ projects_count = "7" })
    assert_eq(tela:get("projects_count"), "7")
end

--- as coleções fixas dos widgets são JSON de {id,label}
function test_connection_init__as_colecoes_fixas_dos_widgets_sao_json_de_id_label()
    local tela = nova()
    for _, chave in { "settings_tabs", "docker_cleanup_kinds", "git_provider_modes", "healthcheck_kinds", "weekdays" } do
        local itens = json.decode(tela:get(chave) or "")
        assert_eq(#itens > 0, true)
        for _, item in itens do
            assert_eq(type(item.id), "string")
            assert_eq(type(item.label), "string")
        end
    end
    local abas = json.decode(tela:get("settings_tabs") or "")
    assert_eq(abas[1].id, "web")
end

--- o init aponta o servidor da chave semeada
function test_connection_init__o_init_aponta_o_servidor_da_chave_semeada()
    local tela = nova()
    assert_eq(tela:get("access_key_target"), "conecta em zz-teste.invalid:1")
end

--- os checkboxes de IaC nascem desmarcados
function test_connection_init__os_checkboxes_de_iac_nascem_desmarcados()
    local tela = nova()
    assert_eq(tela:get("manifest_prune"), "false")
    assert_eq(tela:get("manifest_deploy"), "false")
end

--- digitar uma chave válida mostra o servidor e limpa o erro
function test_connection_campo_do_token__digitar_uma_chave_valida_mostra_o_servidor_e_limpa_o_erro()
    local tela = nova()
    tela:set("error_access_key", "velho")
    tela:call("access_key_input", AccessKey.encode("https://outro.invalid:9797", "t"))
    assert_eq(tela:get("access_key_target"), "conecta em outro.invalid:9797")
    assert_eq(tela:get("error_access_key"), "")
end

--- uma chave inválida não mostra servidor nenhum
function test_connection_campo_do_token__uma_chave_invalida_nao_mostra_servidor_nenhum()
    local tela = nova()
    tela:call("access_key_input", "isso-nao-e-base64!!")
    assert_eq(tela:get("access_key_target"), "")
    assert_eq(tela:get("access_key"), "isso-nao-e-base64!!")
end

--- escolher um servidor salvo preenche o campo do mesmo jeito
function test_connection_campo_do_token__escolher_um_servidor_salvo_preenche_o_campo_do_mesmo_jeito()
    local tela = nova()
    local chave = AccessKey.encode("https://salvo.invalid:1", "t")
    tela:call("choose_saved_server", chave)
    assert_eq(tela:get("access_key"), chave)
    assert_eq(tela:get("access_key_target"), "conecta em salvo.invalid:1")
end

--- a lista de servidores salvos é um array JSON
function test_connection_campo_do_token__a_lista_de_servidores_salvos_e_um_array_json()
    local tela = nova()
    assert_eq(type(json.decode(tela:get("saved_servers") or "null")), "table")
end

--- sem token pede para colar
function test_connection_connect_so_o_que_falha_antes_da_rede__sem_token_pede_para_colar()
    local tela = nova()
    tela:set("access_key", "")
    tela:call("connect")
    assert_has(tela:get("error_access_key"), "cole o token")
    assert_eq(tela:get("screen"), "login")
    assert_eq(tela:get("connected"), "false")
end

--- o token da API no lugar do de conexão é explicado
function test_connection_connect_so_o_que_falha_antes_da_rede__o_token_da_api_no_lugar_do_de_conexao_e_explicado()
    local tela = nova()
    tela:set("access_key", "0123456789abcdef0123456789abcdef")
    tela:call("connect")
    assert_has(tela:get("error_access_key"), "não é um token de conexão")
    assert_eq(tela:get("screen"), "login")
end

--- chave corrompida avisa e não muda de tela
function test_connection_connect_so_o_que_falha_antes_da_rede__chave_corrompida_avisa_e_nao_muda_de_tela()
    local tela = nova()
    tela:set("access_key", "!!!!")
    tela:call("connect")
    assert_has(tela:get("error_access_key"), "corrompido")
    assert_nil(tela:get("api_token"))
end

--- apaga o contexto da sessão e volta ao login
function test_connection_disconnect__apaga_o_contexto_da_sessao_e_volta_ao_login()
    local tela = nova()
    tela:set("api_token", "segredo")
    tela:set("api_url", "https://x")
    tela:set("running", "[{\"p\":1}]")
    tela:set("projeto_aberto", "loja")
    tela:set("screen", "shell")
    tela:set("connected", "true")
    tela:call("disconnect")
    assert_eq(tela:get("screen"), "login")
    assert_eq(tela:get("connected"), "false")
    assert_eq(tela:get("status_line"), "desconectado")
    assert_nil(tela:get("api_token"))
    assert_nil(tela:get("api_url"))
    assert_nil(tela:get("projeto_aberto"))
end

--- não enumera chaves: o init semeia os defaults de novo, como no boot
function test_connection_disconnect__nao_enumera_chaves_o_init_semeia_os_defaults_de_novo_como_no_boot()
    local tela = nova()
    tela:set("view", "docker")
    tela:set("chave_de_uma_tela_nova", "x")
    tela:call("disconnect")
    assert_eq(tela:get("view"), "deployments")
    assert_nil(tela:get("chave_de_uma_tela_nova"))
    assert_eq(tela:get("projects"), "[]")
    assert_eq(tela:get("projects_count"), "…")
end
