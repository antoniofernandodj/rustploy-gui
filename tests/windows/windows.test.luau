--!nonstrict
-- Scripts das janelas auxiliares (cada uma é um motor isolado, aberto por
-- open_window com `data`). Aqui entra o que cada init semeia e o que cada ação
-- faz SEM conexão — o caminho de rede (`fetch`) suspende e não é exercitado.

local function janela(caminho, ctx_inicial)
    local tela = component(caminho, ctx_inicial)
    tela:call("init")
    return tela
end

-- ── Exportar serviço ────────────────────────────────────────────────────────

local PLANO = {
    service_name = "api",
    project_name = "loja",
    service_env = { { key = "A" }, { key = "S", is_secret = true } },
    project_env = {
        { key = "DB", suggested = true },
        { key = "LOG" },
        { key = "TOK", is_secret = true, suggested = true },
    },
}

local function exportar(plano)
    return janela("views/service_export_window.gvb", {
        export_plan = json.encode(plano or PLANO),
        export_service_id = "svc-1",
    })
end

local function linhas(tela)
    local por_chave = {}
    for _, linha in json.decode(tela:get("export_vars") or "[]") do
        por_chave[linha.key] = linha
    end
    return por_chave
end

--- o init resume o plano
function test_janela_exportar_servico__o_init_resume_o_plano()
    local tela = exportar()
    assert_eq(tela:get("export_service"), "api")
    assert_eq(tela:get("export_project"), "loja")
    assert_eq(tela:get("export_service_vars"), "A, S 🔒")
    assert_eq(tela:get("export_service_count"), "2")
    assert_eq(tela:get("export_has_vars"), "true")
    assert_eq(tela:get("export_values"), "true")
    assert_eq(tela:get("export_error"), "")
    assert_eq(tela:get("export_yaml"), "")
end

--- as variáveis do projeto nascem marcadas só quando o serviço as cita
function test_janela_exportar_servico__as_variaveis_do_projeto_nascem()
    local tela = exportar()
    local vars = linhas(tela)
    assert_eq(vars.DB.mark, "☑")
    assert_eq(vars.LOG.mark, "☐")
    assert_eq(vars.TOK.mark, "☑")
    assert_eq(tela:get("export_picked_count"), "2")
end

--- as etiquetas dizem se é secret e se o serviço a cita
function test_janela_exportar_servico__as_etiquetas_dizem_se_e_secret_e_se_o()
    local vars = linhas(exportar())
    assert_eq(vars.DB.tag, "citada pelo serviço")
    assert_eq(vars.LOG.tag, "")
    assert_eq(vars.TOK.tag, "secret · citada pelo serviço")
end

--- alternar uma variável inverte só ela
function test_janela_exportar_servico__alternar_uma_variavel_inverte_so_ela()
    local tela = exportar()
    tela:call("export_toggle", "LOG")
    assert_eq(linhas(tela).LOG.mark, "☑")
    assert_eq(tela:get("export_picked_count"), "3")
    tela:call("export_toggle", "LOG")
    assert_eq(linhas(tela).LOG.mark, "☐")
    assert_eq(tela:get("export_picked_count"), "2")
end

--- todas, nenhuma e sugeridas
function test_janela_exportar_servico__todas_nenhuma_e_sugeridas()
    local tela = exportar()
    tela:call("export_all")
    assert_eq(tela:get("export_picked_count"), "3")
    tela:call("export_none")
    assert_eq(tela:get("export_picked_count"), "0")
    assert_eq(linhas(tela).DB.mark, "☐")
    tela:call("export_suggested")
    assert_eq(tela:get("export_picked_count"), "2")
    assert_eq(linhas(tela).LOG.mark, "☐")
end

--- o plano bloqueado repassa o motivo
function test_janela_exportar_servico__o_plano_bloqueado_repassa_o_motivo()
    local plano =
        { service_name = "x", blocked = "serviço compose não exporta" }
    assert_eq(
        exportar(plano):get("export_blocked"),
        "serviço compose não exporta"
    )
end

--- plano vazio ou ilegível não quebra: sem variáveis e lista []
function test_janela_exportar_servico__plano_vazio_ou_ilegivel_nao_quebra_sem()
    for _, texto in { "{}", "isso não é json" } do
        local tela =
            janela("views/service_export_window.gvb", { export_plan = texto })
        assert_eq(tela:get("export_service"), "")
        assert_eq(
            tela:get("export_service_vars"),
            "(este serviço não tem variáveis próprias)"
        )
        assert_eq(tela:get("export_service_count"), "0")
        assert_eq(tela:get("export_has_vars"), "false")
        assert_eq(tela:get("export_vars"), "[]")
        assert_eq(tela:get("export_picked_count"), "0")
    end
end

--- mostrar o pacote sem conexão explica o que fazer
function test_janela_exportar_servico__mostrar_o_pacote_sem_conexao_explica_o()
    local tela = exportar()
    tela:call("export_show")
    assert_eq(
        tela:get("export_error"),
        "sem conexão — reabra a janela pelo app"
    )
    assert_eq(tela:get("export_yaml"), "")
end

--- o setter field grava a chave pedida
function test_janela_exportar_servico__o_setter_field_grava_a_chave_pedida()
    local tela = exportar()
    tela:call("field", "export_values")
    assert_eq(tela:get("export_values"), "")
end

-- ── Logs ao vivo ────────────────────────────────────────────────────────────

local function semente(n)
    local linhas_log = {}
    for i = 1, n do
        table.insert(
            linhas_log,
            { line = "linha " .. i, timestamp = "2026-03-01T10:00:00Z" }
        )
    end
    return json.encode(linhas_log)
end

--- o histórico semeado vira texto, uma linha por evento, terminado em \\n
function test_janela_logs__o_historico_semeado_vira_texto_uma_linha_por()
    local tela =
        janela("views/log_window.gvb", { log_window_seed = semente(3) })
    assert_eq(tela:get("log_window_count"), "3")
    local texto = tela:get("log_window_logs_text") or ""
    assert_match(texto, "^%d%d:%d%d:%d%d linha 1\n")
    assert_match(texto, "linha 3\n$")
    local n = 0
    for _ in string.gmatch(texto, "[^\n]+") do
        n += 1
    end
    assert_eq(n, 3)
end

--- sem semente a janela abre vazia
function test_janela_logs__sem_semente_a_janela_abre_vazia()
    local tela = janela("views/log_window.gvb")
    assert_eq(tela:get("log_window_count"), "0")
    assert_eq(tela:get("log_window_logs_text"), "")
end

--- semente ilegível é tratada como vazia
function test_janela_logs__semente_ilegivel_e_tratada_como_vazia()
    local tela =
        janela("views/log_window.gvb", { log_window_seed = "não é json" })
    assert_eq(tela:get("log_window_count"), "0")
end

--- o título padrão é Logs, e o que o pai mandou vale
function test_janela_logs__o_titulo_padrao_e_logs_e_o_que_o_pai_mandou_vale()
    assert_eq(janela("views/log_window.gvb"):get("log_window_title"), "Logs")
    local com_titulo =
        janela("views/log_window.gvb", { log_window_title = "api · build" })
    assert_eq(com_titulo:get("log_window_title"), "api · build")
end

-- ── Novo projeto ────────────────────────────────────────────────────────────

--- o init zera mensagens e semeia os campos sem pisar no que veio
function test_janela_novo_projeto__o_init_zera_mensagens_e_semeia_os_campos()
    local tela = janela("views/new_project_form.gvb")
    assert_eq(tela:get("new_project_name"), "")
    assert_eq(tela:get("new_project_description"), "")
    assert_eq(tela:get("new_project_error"), "")
    assert_eq(tela:get("new_project_message"), "")
    local preenchida =
        janela("views/new_project_form.gvb", { new_project_name = "loja" })
    assert_eq(preenchida:get("new_project_name"), "loja")
end

--- a falha de validação só avisa
function test_janela_novo_projeto__a_falha_de_validacao_so_avisa()
    local tela = janela("views/new_project_form.gvb")
    tela:call("new_project_show_validation_errors", "[]")
    assert_eq(tela:toasts()[1].message, "Corrija os campos destacados")
    assert_eq(tela:toasts()[1].kind, "warning")
end

--- criar sem a conexão semeada manda reabrir a janela
function test_janela_novo_projeto__criar_sem_a_conexao_semeada_manda_reabrir()
    local tela =
        janela("views/new_project_form.gvb", { new_project_name = "loja" })
    tela:call("submit_project")
    assert_eq(
        tela:get("new_project_error"),
        "sem conexão — reabra a janela pelo app"
    )
    assert_eq(tela:get("new_project_busy"), "")
end

-- ── Novo token do registry ──────────────────────────────────────────────────

--- o init abre no formulário com escopo de leitura
function test_janela_novo_token_do_registry__o_init_abre_no_formulario_com()
    local tela = janela("views/new_registry_token_window.gvb")
    assert_eq(tela:get("new_registry_token_step"), "form")
    assert_eq(tela:get("new_registry_token_scope"), "pull")
    assert_eq(tela:get("new_registry_token_name"), "")
    assert_eq(tela:get("new_registry_token_login_command"), "")
end

--- os escopos oferecidos são pull e push
function test_janela_novo_token_do_registry__os_escopos_oferecidos_sao_pull_e()
    local escopos = json.decode(
        janela("views/new_registry_token_window.gvb"):get(
            "new_registry_token_scopes"
        ) or "[]"
    )
    assert_eq(#escopos, 2)
    assert_eq(escopos[1].id, "pull")
    assert_eq(escopos[2].id, "push")
end

--- o host do registry vem do pai, com um padrão local
function test_janela_novo_token_do_registry__o_host_do_registry_vem_do_pai()
    assert_eq(
        janela("views/new_registry_token_window.gvb"):get("registry_host"),
        "127.0.0.1:5100"
    )
    assert_eq(
        janela(
            "views/new_registry_token_window.gvb",
            { registry_host = "r.exemplo.com" }
        ):get("registry_host"),
        "r.exemplo.com"
    )
end

--- criar sem conexão e a falha de validação
function test_janela_novo_token_do_registry__criar_sem_conexao_e_a_falha_de()
    local tela = janela("views/new_registry_token_window.gvb")
    tela:call("new_registry_token_create")
    assert_eq(
        tela:get("new_registry_token_error"),
        "sem conexão — reabra a janela pelo app"
    )
    assert_eq(tela:get("new_registry_token_step"), "form")
    tela:call("new_registry_token_show_validation_errors", "[]")
    assert_eq(tela:toasts()[1].message, "Informe o nome do token")
end

-- ── Novo serviço ────────────────────────────────────────────────────────────

local function wizard(ctx_inicial)
    local base = { project_name = "loja", new_service_templates = "[]" }
    for k, v in ctx_inicial or {} do
        base[k] = v
    end
    return janela("views/new_service_window.gvb", base)
end

--- abre escolhendo o tipo, com o formulário zerado
function test_janela_novo_servico__abre_escolhendo_o_tipo_com_o_formulario()
    local tela = wizard()
    assert_eq(tela:get("new_service_step"), "pick_type")
    assert_eq(tela:get("new_service_name"), "")
    assert_eq(tela:get("new_service_template_search"), "")
    assert_eq(tela:get("new_service_busy"), "")
end

--- pedida para importar, abre direto no passo de importação
function test_janela_novo_servico__pedida_para_importar_abre_direto_no_passo()
    assert_eq(
        wizard({ new_service_start = "import" }):get("new_service_step"),
        "import_form"
    )
end

--- o passo de importação nasce zerado
function test_janela_novo_servico__o_passo_de_importacao_nasce_zerado()
    local tela = wizard()
    assert_eq(tela:get("import_text"), "")
    assert_eq(tela:get("import_report"), "false")
    assert_eq(tela:get("import_drop_domains"), "false")
    assert_eq(tela:get("import_deploy"), "false")
end

--- catálogo ilegível não derruba a janela
function test_janela_novo_servico__catalogo_ilegivel_nao_derruba_a_janela()
    local tela = wizard({ new_service_templates = "não é json" })
    assert_eq(tela:get("new_service_step"), "pick_type")
end

--- o setter field existe nesta janela (digitar nos inputs escreve no ctx)
function test_janela_novo_servico__o_setter_field_existe_nesta_janela_digitar()
    local tela = wizard()
    tela:call("field", "new_service_name")
    assert_eq(tela:get("new_service_name"), "")
end
