--!nonstrict
-- Janela "Novo job" (scripts/new_job_window.luau): passos do assistente, modo
-- edição e a validação do formulário. Os testes de `new_job_create` só chegam
-- até onde a validação recusa — passar dela dispararia o RPC (rede).

local CAMINHO = "views/new_job_window.gvb"

local function nova(ctx_inicial)
    local tela = component(CAMINHO, ctx_inicial)
    tela:call("init")
    return tela
end

-- `api_url` semeado: sem ele new_job_create para antes de validar qualquer campo.
-- Os campos do formulário NÃO podem ser semeados: o init zera nome, main_service
-- e compose. Entram depois dele, com `set`, como se o usuário os tivesse digitado.
local function conectada(campos)
    local tela = nova({ api_url = "https://zz-teste.invalid", api_token = "t" })
    for k, v in campos or {} do
        tela:set(k, v)
    end
    return tela
end

local PROJETOS = json.encode({ { id = "p1", name = "loja" }, { id = "p2", name = "blog" } })
local SERVICOS = json.encode({
    { id = "s1", name = "api", project_id = "p1" },
    { id = "s2", name = "web", project_id = "p1" },
    { id = "s3", name = "wp", project_id = "p2" },
})

--- abre escolhendo o projeto, com o formulário zerado
function test_novo_job_init__abre_escolhendo_o_projeto_com_o_formulario_zerado()
    local tela = nova()
    assert_eq(tela:get("new_job_step"), "pick_project")
    assert_eq(tela:get("new_job_name"), "")
    assert_eq(tela:get("new_job_compose"), "")
    assert_eq(tela:get("new_job_main_service"), "")
    assert_eq(tela:get("new_job_edit_id"), "")
    assert_eq(tela:get("new_job_error"), "")
    assert_eq(tela:get("new_job_busy"), "")
end

--- os padrões da recorrência: manual, a cada 6h, 03:00, segunda
function test_novo_job_init__os_padroes_da_recorrencia_manual_a_cada_6h_03_00_segunda()
    local tela = nova()
    assert_eq(tela:get("new_job_kind"), "manual")
    assert_eq(tela:get("new_job_hours"), "6")
    assert_eq(tela:get("new_job_time"), "03:00")
    assert_eq(tela:get("new_job_weekday"), "0")
    assert_eq(tela:get("new_job_enabled"), "true")
end

--- a fonte do compose começa em colado, com o caminho padrão
function test_novo_job_init__a_fonte_do_compose_comeca_em_colado_com_o_caminho_padrao()
    local tela = nova()
    assert_eq(tela:get("new_job_source"), "compose")
    assert_eq(tela:get("new_job_compose_path"), "docker-compose.yml")
    assert_eq(tela:get("new_job_git_providers"), "[]")
    assert_eq(tela:get("new_job_git_repos"), "[]")
end

--- os catálogos semeados pelo pai ficam à disposição
function test_novo_job_init__os_catalogos_semeados_pelo_pai_ficam_a_disposicao()
    local tela = nova({ new_job_projects = PROJETOS, new_job_services = SERVICOS })
    assert_eq(tela:get("new_job_projects"), PROJETOS)
    assert_eq(tela:get("new_job_services_all"), SERVICOS)
    assert_eq(tela:get("new_job_services_filtered"), "[]")
end

--- sem catálogo os projetos nascem []
function test_novo_job_init__sem_catalogo_os_projetos_nascem()
    assert_eq(nova():get("new_job_projects"), "[]")
end

--- os dias da semana vêm do formatador
function test_novo_job_init__os_dias_da_semana_vem_do_formatador()
    assert_eq(#json.decode(nova():get("weekdays") or "[]"), 7)
end

local function editando(job)
    return nova({ new_job_edit_job = json.encode(job) })
end

--- pula direto para o formulário e preenche o job
function test_novo_job_modo_edicao__pula_direto_para_o_formulario_e_preenche_o_job()
    local tela = editando({ id = "j1", name = "migrar", main_service = "app", compose = "services: {}", enabled = true })
    assert_eq(tela:get("new_job_edit_id"), "j1")
    assert_eq(tela:get("new_job_step"), "form")
    assert_eq(tela:get("new_job_name"), "migrar")
    assert_eq(tela:get("new_job_main_service"), "app")
    assert_eq(tela:get("new_job_compose"), "services: {}")
    assert_eq(tela:get("new_job_enabled"), "true")
end

--- job pausado vem desmarcado
function test_novo_job_modo_edicao__job_pausado_vem_desmarcado()
    assert_eq(editando({ id = "j", enabled = false }):get("new_job_enabled"), "false")
end

--- recorrência de intervalo
function test_novo_job_modo_edicao__recorrencia_de_intervalo()
    local tela = editando({ id = "j", recurrence = { IntervalHours = 12 } })
    assert_eq(tela:get("new_job_kind"), "interval")
    assert_eq(tela:get("new_job_hours"), "12")
end

--- recorrência diária vira HH:MM
function test_novo_job_modo_edicao__recorrencia_diaria_vira_hh_mm()
    local tela = editando({ id = "j", recurrence = { Daily = { hour = 7, minute = 5 } } })
    assert_eq(tela:get("new_job_kind"), "daily")
    assert_eq(tela:get("new_job_time"), "07:05")
end

--- recorrência semanal guarda o dia e o horário
function test_novo_job_modo_edicao__recorrencia_semanal_guarda_o_dia_e_o_horario()
    local tela = editando({ id = "j", recurrence = { Weekly = { weekday = 3, hour = 9, minute = 30 } } })
    assert_eq(tela:get("new_job_kind"), "weekly")
    assert_eq(tela:get("new_job_weekday"), "3")
    assert_eq(tela:get("new_job_time"), "09:30")
end

--- sem recorrência (ou desconhecida) é manual com os padrões
function test_novo_job_modo_edicao__sem_recorrencia_ou_desconhecida_e_manual_com_os_padroes()
    for _, job in { { id = "j" }, { id = "j", recurrence = { Mensal = {} } } } do
        local tela = editando(job)
        assert_eq(tela:get("new_job_kind"), "manual")
        assert_eq(tela:get("new_job_hours"), "6")
        assert_eq(tela:get("new_job_time"), "03:00")
    end
end

--- job com fonte git troca a fonte e os campos do picker
function test_novo_job_modo_edicao__job_com_fonte_git_troca_a_fonte_e_os_campos_do_picker()
    local tela = editando({
        id = "j",
        git_source = { provider_id = "gp1", branch = "main", compose_path = "ci/compose.yml" },
    })
    assert_eq(tela:get("new_job_source"), "git")
    assert_eq(tela:get("new_job_git_provider_id"), "gp1")
    assert_eq(tela:get("new_job_git_branch"), "main")
    assert_eq(tela:get("new_job_compose_path"), "ci/compose.yml")
    assert_eq(tela:get("new_job_compose"), "")
end

--- git sem compose_path usa o padrão
function test_novo_job_modo_edicao__git_sem_compose_path_usa_o_padrao()
    local tela = editando({ id = "j", git_source = { branch = "dev" } })
    assert_eq(tela:get("new_job_compose_path"), "docker-compose.yml")
end

--- as variáveis do job voltam como .env, com segredo e comentário
function test_novo_job_modo_edicao__as_variaveis_do_job_voltam_como_env_com_segredo_e_comentario()
    local tela = editando({
        id = "j",
        env_vars = { { key = "A", value = { Plain = "1" } }, { key = "B", value = { Secret = "S" } } },
        env_comments = { { before_key = "B", text = "# b" } },
    })
    assert_eq(tela:get("new_job_env_text"), "A=1\n# b\nB=<secret:S>")
end

--- JSON de edição ilegível é ignorado: abre como job novo
function test_novo_job_modo_edicao__json_de_edicao_ilegivel_e_ignorado_abre_como_job_novo()
    local tela = nova({ new_job_edit_job = "isso não é json" })
    assert_eq(tela:get("new_job_edit_id"), "")
    assert_eq(tela:get("new_job_step"), "pick_project")
end

local function com_catalogo()
    return nova({ new_job_projects = PROJETOS, new_job_services = SERVICOS })
end

--- escolher o projeto filtra os serviços dele e avança
function test_novo_job_passos__escolher_o_projeto_filtra_os_servicos_dele_e_avanca()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "p1")
    assert_eq(tela:get("new_job_project_id"), "p1")
    assert_eq(tela:get("new_job_project_name"), "loja")
    assert_eq(tela:get("new_job_step"), "pick_service")
    local nomes = {}
    for _, s in json.decode(tela:get("new_job_services_filtered") or "[]") do
        table.insert(nomes, s.name)
    end
    assert_eq(nomes, { "api", "web" })
end

--- outro projeto, outros serviços
function test_novo_job_passos__outro_projeto_outros_servicos()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "p2")
    assert_eq(tela:get("new_job_project_name"), "blog")
    assert_eq(#json.decode(tela:get("new_job_services_filtered") or "[]"), 1)
end

--- projeto desconhecido não acha nome nem serviço, mas o passo avança
function test_novo_job_passos__projeto_desconhecido_nao_acha_nome_nem_servico_mas_o_passo_avanca()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "zzz")
    assert_eq(tela:get("new_job_project_name"), "")
    assert_eq(tela:get("new_job_services_filtered"), "[]")
end

--- escolher o serviço gatilho guarda o nome e vai ao formulário
function test_novo_job_passos__escolher_o_servico_gatilho_guarda_o_nome_e_vai_ao_formulario()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "p1")
    tela:call("new_job_pick_service", "s2")
    assert_eq(tela:get("new_job_service_id"), "s2")
    assert_eq(tela:get("new_job_service_name"), "web")
    assert_eq(tela:get("new_job_step"), "form")
end

--- job autônomo: sem serviço gatilho
function test_novo_job_passos__job_autonomo_sem_servico_gatilho()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "p1")
    tela:call("new_job_pick_no_service")
    assert_eq(tela:get("new_job_service_id"), "")
    assert_eq(tela:get("new_job_service_name"), "nenhum (autônomo)")
    assert_eq(tela:get("new_job_step"), "form")
end

--- voltar recua um passo por vez
function test_novo_job_passos__voltar_recua_um_passo_por_vez()
    local tela = com_catalogo()
    tela:call("new_job_pick_project", "p1")
    tela:call("new_job_pick_service", "s1")
    assert_eq(tela:get("new_job_step"), "form")
    tela:call("new_job_back")
    assert_eq(tela:get("new_job_step"), "pick_service")
    tela:call("new_job_back")
    assert_eq(tela:get("new_job_step"), "pick_project")
    tela:call("new_job_back")
    assert_eq(tela:get("new_job_step"), "pick_project")
end

--- o tipo de recorrência e o setter genérico
function test_novo_job_passos__o_tipo_de_recorrencia_e_o_setter_generico()
    local tela = nova()
    tela:call("new_job_kind", "weekly")
    assert_eq(tela:get("new_job_kind"), "weekly")
    tela:call("field", "new_job_name")
    assert_eq(tela:get("new_job_name"), "")
end

--- trocar a fonte sem conexão só grava a escolha
function test_novo_job_fonte_git__trocar_a_fonte_sem_conexao_so_grava_a_escolha()
    local tela = nova()
    tela:call("new_job_source", "git")
    assert_eq(tela:get("new_job_source"), "git")
    assert_eq(tela:get("new_job_git_message"), "")
    tela:call("new_job_source", "compose")
    assert_eq(tela:get("new_job_source"), "compose")
end

--- escolher a conta zera repositório, repos e branches
function test_novo_job_fonte_git__escolher_a_conta_zera_repositorio_repos_e_branches()
    local tela = nova({ new_job_git_repo = "a/b", new_job_git_repos = "[1]", new_job_git_branches = "[1]" })
    tela:call("new_job_git_provider_pick", "gp1")
    assert_eq(tela:get("new_job_git_provider_id"), "gp1")
    assert_eq(tela:get("new_job_git_repo"), "")
    assert_eq(tela:get("new_job_git_repos"), "[]")
    assert_eq(tela:get("new_job_git_branches"), "[]")
end

--- escolher o repositório adota a branch padrão dele
function test_novo_job_fonte_git__escolher_o_repositorio_adota_a_branch_padrao_dele()
    local repos = json.encode({
        { full_name = "a/b", clone_url = "u1", default_branch = "main" },
        { full_name = "a/c", clone_url = "u2", default_branch = "" },
    })
    local tela = nova({ new_job_git_repos = repos })
    tela:call("new_job_git_repo_pick", "a/b")
    assert_eq(tela:get("new_job_git_repo"), "a/b")
    assert_eq(tela:get("new_job_git_branch"), "main")
    assert_eq(tela:get("new_job_git_branches"), "[]")
end

--- repositório sem branch padrão deixa a branch como estava
function test_novo_job_fonte_git__repositorio_sem_branch_padrao_deixa_a_branch_como_estava()
    local repos = json.encode({ { full_name = "a/c", clone_url = "u2", default_branch = "" } })
    local tela = nova({ new_job_git_repos = repos })
    tela:call("new_job_git_repo_pick", "a/c")
    assert_eq(tela:get("new_job_git_branch"), "")
end

local function erro_ao_criar(campos, fonte)
    local tela = conectada()
    if fonte then
        tela:call("new_job_source", fonte)
    end
    for k, v in campos or {} do
        tela:set(k, v)
    end
    tela:call("new_job_create")
    return tela:get("new_job_error"), tela
end

--- sem conexão manda reabrir a janela
function test_novo_job_criar_so_ate_a_validacao_recusar__sem_conexao_manda_reabrir_a_janela()
    local tela = nova()
    tela:set("new_job_name", "x")
    tela:call("new_job_create")
    assert_eq(tela:get("new_job_error"), "sem conexão — reabra a janela pelo app")
end

--- o nome é obrigatório, mesmo só de espaços
function test_novo_job_criar_so_ate_a_validacao_recusar__o_nome_e_obrigatorio_mesmo_so_de_espacos()
    assert_eq((erro_ao_criar({ new_job_name = "   " })), "informe um nome")
    assert_eq((erro_ao_criar({})), "informe um nome")
end

--- o main_service é obrigatório
function test_novo_job_criar_so_ate_a_validacao_recusar__o_main_service_e_obrigatorio()
    local erro = erro_ao_criar({ new_job_name = "migrar", new_job_main_service = " " })
    assert_has(erro, "main_service")
end

--- fonte compose pede o docker-compose colado
function test_novo_job_criar_so_ate_a_validacao_recusar__fonte_compose_pede_o_docker_compose_colado()
    local erro = erro_ao_criar({ new_job_name = "migrar", new_job_main_service = "app", new_job_compose = "  \n " })
    assert_eq(erro, "cole o docker-compose.yml do job")
end

--- fonte git pede repositório e branch
function test_novo_job_criar_so_ate_a_validacao_recusar__fonte_git_pede_repositorio_e_branch()
    for _, parcial in {
        {},
        { new_job_git_repo = "a/b" },
        { new_job_git_branch = "main" },
        { new_job_git_repo = "a/b", new_job_git_branch = "   " },
    } do
        local campos = { new_job_name = "migrar", new_job_main_service = "app" }
        for k, v in parcial do
            campos[k] = v
        end
        assert_eq((erro_ao_criar(campos, "git")), "selecione repositório e branch")
    end
end

--- git com repositório que não está na lista pede para selecionar de novo
function test_novo_job_criar_so_ate_a_validacao_recusar__git_com_repositorio_que_nao_esta_na_lista_pede_para_selecionar_de_novo()
    local erro = erro_ao_criar({
        new_job_name = "migrar", new_job_main_service = "app",
        new_job_git_repo = "a/b", new_job_git_branch = "main", new_job_git_repos = "[]",
    }, "git")
    assert_has(erro, "não foi possível resolver a URL")
end

--- o erro some quando o formulário passa a validar (limpa antes de ir à rede)
function test_novo_job_criar_so_ate_a_validacao_recusar__o_erro_some_quando_o_formulario_passa_a_validar_limpa_antes_de_ir_a_rede()
    local tela = conectada({ new_job_name = "migrar", new_job_main_service = "app", new_job_compose = "services: {}" })
    tela:set("new_job_error", "velho")
    tela:call("new_job_create") -- passa da validação: o RPC suspende
    assert_eq(tela:get("new_job_error"), "")
    assert_eq(tela:get("new_job_message"), "criando…")
end

--- o formulário recusado não deixa o botão travado
function test_novo_job_criar_so_ate_a_validacao_recusar__o_formulario_recusado_nao_deixa_o_botao_travado()
    local _, tela = erro_ao_criar({ new_job_name = "migrar" })
    assert_eq(tela:get("new_job_busy"), "")
    assert_eq(tela:get("new_job_message"), "")
end
