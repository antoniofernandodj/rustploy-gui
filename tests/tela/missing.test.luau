--!nonstrict
-- Toda chave que uma tela LÊ tem de ser publicada por alguém. `tela:missing()`
-- devolve as que o markup lê e o `ctx` não tem; handler que escreve `total` e
-- markup que lê `{totall}` passa em todo teste de handler e deixa a tela vazia.
--
-- O que sobra na lista de cada tela é conhecido e tem causa. Os conjuntos abaixo
-- são o contrato: o teste falha se uma chave NOVA aparecer (alguém leu algo que
-- ninguém publica) e também se uma ESPERADA sumir (passou a ser publicada no
-- init, ou deixou de ser lida — atualize a lista).
--
-- LIMITE: o snapshot do daemon chega por SSE (stream.luau::apply_snapshot é
-- local e só roda lá), então não dá para publicá-lo aqui. As chaves "do
-- snapshot" abaixo são só CONGELADAS: este teste prova que o markup depende
-- delas, não que o stream as escreve com o mesmo nome.

local MOTOR = { "glacier_window_maximized" } -- o motor publica o estado da janela

-- Publicadas em connect()/apply_snapshot, depois do login.
local SESSAO = { "connected_server", "daemon_version" }

local function conjunto(...)
    local c = {}
    for _, lista in { ... } do
        for _, k in lista do
            c[k] = true
        end
    end
    return c
end

local function confere(tela, ...)
    local esperado = conjunto(...)
    local obtido = conjunto(tela:missing())
    local novas, sumidas = {}, {}
    for k in obtido do
        if not esperado[k] then
            table.insert(novas, k)
        end
    end
    for k in esperado do
        if not obtido[k] then
            table.insert(sumidas, k)
        end
    end
    table.sort(novas)
    table.sort(sumidas)
    -- Duas asserções para a mensagem de falha nomear as chaves.
    assert_eq(novas, {}) -- lidas pelo markup e que ninguém publica
    assert_eq(sumidas, {}) -- esperadas, mas já publicadas (ou não lidas): atualize a lista
end

local function app(visao)
    -- access_key semeado: o init pré-preencheria com o servidor salvo da máquina.
    local tela = component("views/app.gvb", { access_key = "x" })
    tela:call("init")
    if visao then
        tela:set("screen", "shell")
        tela:set("view", visao)
    end
    return tela
end

--- a tela de login só espera o erro opcional e o estado da janela
function test_login__a_tela_de_login_so_espera_o_erro_opcional_e_o_estado_da_janela()
    -- error_access_key só é escrita quando o conectar falha; `if=@error_access_key`.
    confere(app(), MOTOR, { "error_access_key" })
end

--- deployments
function test_shell_cada_visao__deployments()
    confere(app("deployments"), MOTOR, SESSAO, {
        "daemon_uptime", "services_label", -- snapshot
        "deployments_message", -- só depois de "limpar finalizados"
        "deployments_sort", -- a tabela grava ao ordenar
    })
end

--- projects
function test_shell_cada_visao__projects()
    confere(app("projects"), MOTOR, SESSAO)
end

--- project_services
function test_shell_cada_visao__project_services()
    confere(app("project_services"), MOTOR, SESSAO, {
        "editing_project", "project_action_message", "project_can_delete",
        "project_description", "project_loading", "project_name", "project_tab",
    })
end

--- service
function test_shell_cada_visao__service()
    confere(app("service"), MOTOR, SESSAO, {
        "daemon_uptime", "services_label",
        "service_action_message", "service_can_migrate", "service_deploy_running",
        "service_error", "service_name", "service_project", "service_project_id",
        "service_shared", "service_status_color", "service_status_label",
        "service_warm_visible", "tab",
    })
end

--- running
function test_shell_cada_visao__running()
    confere(app("running"), MOTOR, SESSAO, { "running_count" })
end

--- monitoring
function test_shell_cada_visao__monitoring()
    confere(app("monitoring"), MOTOR, SESSAO, { "host_cpu", "host_disk", "host_load", "host_memory", "monitoring_sort" })
end

--- ingress
function test_shell_cada_visao__ingress()
    confere(app("ingress"), MOTOR, SESSAO, { "host_ports_sort", "ingress_sort" })
end

--- deploy_engine
function test_shell_cada_visao__deploy_engine()
    confere(app("deploy_engine"), MOTOR, SESSAO, { "deploy_engine_queued_count", "deploy_engine_tab", "deploy_engine_uptime" })
end

--- docker
function test_shell_cada_visao__docker()
    confere(app("docker"), MOTOR, SESSAO, { "docker_containers_count", "docker_tab" })
end

--- settings
function test_shell_cada_visao__settings()
    confere(app("settings"), MOTOR, SESSAO, { "settings_tab" })
end

--- schedules
function test_shell_cada_visao__schedules()
    confere(app("schedules"), MOTOR, SESSAO, { "jobs_sort" })
end

--- support
function test_shell_cada_visao__support()
    confere(app("support"), MOTOR, SESSAO)
end

local function janela(caminho, ctx_inicial)
    local tela = component(caminho, ctx_inicial)
    tela:call("init")
    return tela
end

--- logs ao vivo
function test_janelas_auxiliares__logs_ao_vivo()
    confere(janela("views/log_window.gvb"), MOTOR)
end

--- novo job
function test_janelas_auxiliares__novo_job()
    confere(janela("views/new_job_window.gvb"), {})
end

--- novo serviço (com o projeto-alvo semeado pelo open_window)
function test_janelas_auxiliares__novo_servico_com_o_projeto_alvo_semeado_pelo_open_window()
    confere(janela("views/new_service_window.gvb", { project_name = "loja", new_service_templates = "[]" }), {})
end

--- novo projeto
function test_janelas_auxiliares__novo_projeto()
    -- O motor lê `erro_<campo>` de TODO form_control, mesmo sem `rules` (aqui
    -- a descrição é opcional) — uma leitura interna, não esquecimento do app.
    -- error_new_project_name só existe depois de uma validação que falha.
    confere(janela("views/new_project_form.gvb"), { "erro_new_project_description", "error_new_project_name" })
end

--- novo token do registry
function test_janelas_auxiliares__novo_token_do_registry()
    confere(janela("views/new_registry_token_window.gvb"), { "error_new_registry_token_name" })
end

--- exportar serviço
function test_janelas_auxiliares__exportar_servico()
    confere(janela("views/service_export_window.gvb", { export_plan = "{}" }), {})
end
