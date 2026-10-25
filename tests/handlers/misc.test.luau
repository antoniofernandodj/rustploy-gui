--!nonstrict
-- Handlers que só mexem no ctx, ou que não fazem nada sem conexão:
-- deploy_queue, secrets e bundle. Sem `State.api` eles têm de ser inertes —
-- nem toast, nem mudança de contexto —, porque o botão pode ser clicado no
-- instante em que a sessão cai.

local function nova(ctx_inicial)
    local tela = component("views/app.gvb", ctx_inicial)
    tela:call("init")
    return tela
end

--- cancelar, promover, reordenar e pausar são inertes
function test_deploy_queue_sem_conexao__cancelar_promover_reordenar_e_pausar()
    local tela = nova({ deploy_engine_paused = "false" })
    tela:call("queue_cancel", "d1")
    tela:call("queue_promote", "d1")
    tela:call("queue_reorder", '["d1","d2"]')
    tela:call("queue_toggle_pause")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("deploy_engine_paused"), "false")
end

--- id vazio também não faz nada
function test_deploy_queue_sem_conexao__id_vazio_tambem_nao_faz_nada()
    local tela = nova()
    tela:call("queue_cancel", "")
    tela:call("queue_promote", "")
    assert_eq(#tela:toasts(), 0)
end

-- O painel só faz sentido para um deploy ATIVO: open_detail marca o serviço e
-- logo em seguida refresh_deploy_engine_detail procura esse id entre os
-- deploys ativos do snapshot. Sem snapshot (ou sem esse id lá) o deploy já
-- terminou, e o painel se fecha em vez de ficar apontando para o nada.
--- sem um deploy ativo com esse id, o painel se fecha na hora
function test_deploy_queue_detalhe_do_deploy__sem_um_deploy_ativo_com_esse_id()
    local tela = nova()
    tela:call("deploy_engine_open_detail", "svc-9")
    assert_eq(tela:get("deploy_engine_detail_id"), "")
    assert_eq(tela:get("deploy_engine_detail_open"), "false")
end

--- fechar limpa o id e desmarca aberto
function test_deploy_queue_detalhe_do_deploy__fechar_limpa_o_id_e_desmarca()
    local tela = nova({
        deploy_engine_detail_id = "svc-9",
        deploy_engine_detail_open = "true",
    })
    tela:call("deploy_engine_close_detail")
    assert_eq(tela:get("deploy_engine_detail_id"), "")
    assert_eq(tela:get("deploy_engine_detail_open"), "false")
end

--- secret_use arma o form em modo secret com o nome escolhido
function test_secrets__secret_use_arma_o_form_em_modo_secret_com_o_nome()
    local tela = nova()
    tela:call("secret_use", "DB_PASS")
    assert_eq(tela:get("project_env_new_is_secret"), "true")
    assert_eq(tela:get("project_env_new_value"), "DB_PASS")
    assert_eq(tela:get("project_env_new_key"), "DB_PASS")
end

--- secret_use não pisa numa chave que o usuário já digitou
function test_secrets__secret_use_nao_pisa_numa_chave_que_o_usuario_ja()
    local tela = nova({ project_env_new_key = "MINHA_CHAVE" })
    tela:call("secret_use", "DB_PASS")
    assert_eq(tela:get("project_env_new_key"), "MINHA_CHAVE")
    assert_eq(tela:get("project_env_new_value"), "DB_PASS")
end

--- secret_use trata chave só de espaços como vazia
function test_secrets__secret_use_trata_chave_so_de_espacos_como_vazia()
    local tela = nova({ project_env_new_key = "   " })
    tela:call("secret_use", "X")
    assert_eq(tela:get("project_env_new_key"), "X")
end

--- o interruptor de secret alterna e limpa o valor digitado
function test_secrets__o_interruptor_de_secret_alterna_e_limpa_o_valor()
    local tela = nova({ project_env_new_value = "abc" })
    tela:call("project_env_secret_toggle")
    assert_eq(tela:get("project_env_new_is_secret"), "true")
    assert_eq(tela:get("project_env_new_value"), "")
    tela:set("project_env_new_value", "def")
    tela:call("project_env_secret_toggle")
    assert_eq(tela:get("project_env_new_is_secret"), "false")
    assert_eq(tela:get("project_env_new_value"), "")
end

--- a falha de validação só avisa
function test_secrets__a_falha_de_validacao_so_avisa()
    local tela = nova()
    tela:call("secret_add_show_validation_errors", "[]")
    local avisos = tela:toasts()
    assert_eq(#avisos, 1)
    assert_eq(avisos[1].kind, "warning")
end

--- adicionar sem projeto ou sem conexão não faz nada
function test_secrets__adicionar_sem_projeto_ou_sem_conexao_nao_faz_nada()
    local tela =
        nova({ project_secret_new_name = "A", project_secret_new_value = "1" })
    tela:call("secret_add")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("project_secret_new_name"), "A")

    local com_projeto = nova({
        selected_project_id = "p1",
        project_secret_new_name = "A",
        project_secret_new_value = "1",
    })
    com_projeto:call("secret_add")
    assert_eq(#com_projeto:toasts(), 0)
    assert_eq(com_projeto:get("project_secret_new_name"), "A")
end

--- apagar sem projeto ou com nome vazio não pergunta nem faz nada
function test_secrets__apagar_sem_projeto_ou_com_nome_vazio_nao_pergunta_nem()
    local tela = nova()
    tela:call("secret_delete", "X")
    local com_projeto = nova({ selected_project_id = "p1" })
    com_projeto:call("secret_delete", "")
    assert_eq(#tela:toasts() + #com_projeto:toasts(), 0)
end

--- sem conexão ou sem serviço escolhido não abre janela nem avisa
function test_bundle_exportar_servico__sem_conexao_ou_sem_servico_escolhido()
    local tela = nova({ selected_service = "svc-1" })
    tela:call("open_export_window", "")
    tela:call("open_export_window", "svc-2")
    assert_eq(#tela:toasts(), 0)
end

-- Aba Atualizações (Command::CheckUpdate). Sem conexão o botão é inerte, como o
-- resto: nem toast, nem mensagem "verificando…" presa na tela.
--- o init semeia as chaves da aba e a lista de abas a inclui
function test_atualizacoes__o_init_semeia_as_chaves_e_a_aba()
    local tela = nova()
    assert_eq(tela:get("update_current_version"), "")
    assert_eq(tela:get("update_latest_version"), "")
    assert_eq(tela:get("update_checked_at_label"), "")
    assert_eq(tela:get("update_is_available"), "false")
    assert_eq(tela:get("update_release_url"), "")
    assert_eq(tela:get("update_message"), "")
    assert_eq(tela:get("update_progress_message"), "")
    assert_eq(tela:get("update_is_helper_available"), "false")
    assert_true(
        string.find(tela:get("update_install_command"), "install.sh", 1, true)
            ~= nil
    )
    -- Listas chegam no ctx como JSON: confere a aba e que ela é a última.
    local abas = tela:get("settings_tabs")
    local ids = {}
    for id in string.gmatch(abas, '"id":"([a-z]+)"') do
        table.insert(ids, id)
    end
    assert_eq(ids, { "web", "git", "iac", "maintenance", "updates" })
end

--- verificar sem conexão não faz nada
function test_atualizacoes__verificar_sem_conexao_nao_faz_nada()
    local tela = nova()
    tela:call("update_check_now")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("update_message"), "")
    assert_eq(tela:get("update_is_available"), "false")
end

--- o init não pisa numa consulta que já estava no contexto
function test_atualizacoes__o_init_nao_pisa_no_resultado_anterior()
    local tela = nova({
        update_latest_version = "0.2.0",
        update_is_available = "true",
    })
    assert_eq(tela:get("update_latest_version"), "0.2.0")
    assert_eq(tela:get("update_is_available"), "true")
end

--- atualizar e reverter sem conexão não fazem nada (nem pedem confirmação)
function test_atualizacoes__atualizar_e_reverter_sem_conexao_nao_fazem_nada()
    local tela = nova()
    tela:call("update_apply")
    tela:call("update_rollback")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("update_progress_message"), "")
end
