--!nonstrict
-- Navegação da sidebar, abas e busca (handlers/nav.luau), sem conexão.

local function nova()
    local tela = component("views/app.gvb")
    tela:call("init")
    return tela
end

--- a sidebar troca a visão e limpa o serviço selecionado
function test_visoes__a_sidebar_troca_a_visao_e_limpa_o_servico_selecionado()
    for acao, visao in
        {
            nav_deployments = "deployments",
            nav_running = "running",
            nav_monitoring = "monitoring",
            nav_schedules = "schedules",
            nav_ingress = "ingress",
            nav_docker = "docker",
            nav_support = "support",
        }
    do
        local tela = nova()
        tela:set("selected_service", "svc-1")
        tela:call(acao)
        assert_eq(tela:get("view"), visao)
        assert_eq(tela:get("selected_service"), "")
    end
end

--- projetos também limpa o projeto selecionado
function test_visoes__projetos_tambem_limpa_o_projeto_selecionado()
    local tela = nova()
    tela:set("selected_project_id", "p1")
    tela:call("nav_projects")
    assert_eq(tela:get("view"), "projects")
    assert_eq(tela:get("selected_project_id"), "")
end

--- o Deploy Engine abre na aba da fila, sem pisar numa aba já escolhida
function test_visoes__o_deploy_engine_abre_na_aba_da_fila_sem_pisar_numa_aba()
    local tela = nova()
    tela:call("nav_deploy_engine")
    assert_eq(tela:get("view"), "deploy_engine")
    assert_eq(tela:get("deploy_engine_tab"), "fila")

    local outra = nova()
    outra:set("deploy_engine_tab", "historico")
    outra:call("nav_deploy_engine")
    assert_eq(outra:get("deploy_engine_tab"), "historico")
end

--- as configurações abrem na aba web e semeiam o provedor Git sem pisar no
--- escolhido
function test_visoes__as_configuracoes_abrem_na_aba_web_e_semeiam_o_provedor()
    local tela = nova()
    tela:call("nav_settings")
    assert_eq(tela:get("view"), "settings")
    assert_eq(tela:get("settings_tab"), "web")
    assert_eq(tela:get("git_provider_kind"), "gitea")
    assert_eq(tela:get("git_provider_mode"), "oauth")

    local escolhido = nova()
    escolhido:set("git_provider_kind", "github")
    escolhido:set("git_provider_mode", "pat")
    escolhido:call("nav_settings")
    assert_eq(escolhido:get("git_provider_kind"), "github")
    assert_eq(escolhido:get("git_provider_mode"), "pat")
end

--- nav genérico vai para a visão pedida e ignora valor vazio
function test_visoes__nav_generico_vai_para_a_visao_pedida_e_ignora_valor()
    local tela = nova()
    tela:call("nav", "docker")
    assert_eq(tela:get("view"), "docker")
    tela:call("nav")
    assert_eq(tela:get("view"), "docker")
end

--- cada aba grava a sua chave
function test_abas_e_campos__cada_aba_grava_a_sua_chave()
    local tela = nova()
    tela:call("project_tab", "jobs")
    tela:call("deploy_engine_tab", "historico")
    tela:call("deploy_tab", "logs")
    tela:call("tab", "domains")
    tela:call("select_provider_tab", "github")
    tela:call("docker_tab", "images")
    assert_eq(tela:get("project_tab"), "jobs")
    assert_eq(tela:get("deploy_engine_tab"), "historico")
    assert_eq(tela:get("deploy_tab"), "logs")
    assert_eq(tela:get("tab"), "domains")
    assert_eq(tela:get("provider_tab"), "github")
    assert_eq(tela:get("docker_tab"), "images")
end

--- o setter genérico field grava a chave com o valor
function test_abas_e_campos__o_setter_generico_field_grava_a_chave_com_o()
    local tela = nova()
    tela:call("field", "qualquer_chave")
    assert_eq(tela:get("qualquer_chave"), "")
end

--- a busca guarda o texto como veio e não quebra sem snapshot
function test_abas_e_campos__a_busca_guarda_o_texto_como_veio_e_nao_quebra()
    local tela = nova()
    tela:call("search_changed", "Minha API")
    assert_eq(tela:get("search"), "Minha API")
    tela:call("search_changed", "")
    assert_eq(tela:get("search"), "")
end
