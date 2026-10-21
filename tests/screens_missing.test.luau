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
    expect(novas):toEqual({}) -- lidas pelo markup e que ninguém publica
    expect(sumidas):toEqual({}) -- esperadas, mas já publicadas (ou não lidas): atualize a lista
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

describe("login", function()
    test("a tela de login só espera o erro opcional e o estado da janela", function()
        -- error_access_key só é escrita quando o conectar falha; `if=@error_access_key`.
        confere(app(), MOTOR, { "error_access_key" })
    end)
end)

describe("shell · cada visão", function()
    test("deployments", function()
        confere(app("deployments"), MOTOR, SESSAO, {
            "daemon_uptime", "services_label", -- snapshot
            "deployments_message", -- só depois de "limpar finalizados"
            "deployments_sort", -- a tabela grava ao ordenar
        })
    end)

    test("projects", function()
        confere(app("projects"), MOTOR, SESSAO)
    end)

    test("project_services", function()
        confere(app("project_services"), MOTOR, SESSAO, {
            "editing_project", "project_action_message", "project_can_delete",
            "project_description", "project_loading", "project_name", "project_tab",
        })
    end)

    test("service", function()
        confere(app("service"), MOTOR, SESSAO, {
            "daemon_uptime", "services_label",
            "service_action_message", "service_can_migrate", "service_deploy_running",
            "service_error", "service_name", "service_project", "service_project_id",
            "service_shared", "service_status_color", "service_status_label",
            "service_warm_visible", "tab",
        })
    end)

    test("running", function()
        confere(app("running"), MOTOR, SESSAO, { "running_count" })
    end)

    test("monitoring", function()
        confere(app("monitoring"), MOTOR, SESSAO, { "host_cpu", "host_disk", "host_load", "host_memory", "monitoring_sort" })
    end)

    test("ingress", function()
        confere(app("ingress"), MOTOR, SESSAO, { "host_ports_sort", "ingress_sort" })
    end)

    test("deploy_engine", function()
        confere(app("deploy_engine"), MOTOR, SESSAO, { "deploy_engine_queued_count", "deploy_engine_tab", "deploy_engine_uptime" })
    end)

    test("docker", function()
        confere(app("docker"), MOTOR, SESSAO, { "docker_containers_count", "docker_tab" })
    end)

    test("settings", function()
        confere(app("settings"), MOTOR, SESSAO, { "settings_tab" })
    end)

    test("schedules", function()
        confere(app("schedules"), MOTOR, SESSAO, { "jobs_sort" })
    end)

    test("support", function()
        confere(app("support"), MOTOR, SESSAO)
    end)
end)

describe("janelas auxiliares", function()
    local function janela(caminho, ctx_inicial)
        local tela = component(caminho, ctx_inicial)
        tela:call("init")
        return tela
    end

    test("logs ao vivo", function()
        confere(janela("views/log_window.gvb"), MOTOR)
    end)

    test("novo job", function()
        confere(janela("views/new_job_window.gvb"), {})
    end)

    test("novo serviço (com o projeto-alvo semeado pelo open_window)", function()
        confere(janela("views/new_service_window.gvb", { project_name = "loja", new_service_templates = "[]" }), {})
    end)

    test("novo projeto", function()
        -- O motor lê `erro_<campo>` de TODO form_control, mesmo sem `rules` (aqui
        -- a descrição é opcional) — uma leitura interna, não esquecimento do app.
        -- error_new_project_name só existe depois de uma validação que falha.
        confere(janela("views/new_project_form.gvb"), { "erro_new_project_description", "error_new_project_name" })
    end)

    test("novo token do registry", function()
        confere(janela("views/new_registry_token_window.gvb"), { "error_new_registry_token_name" })
    end)

    test("exportar serviço", function()
        confere(janela("views/service_export_window.gvb", { export_plan = "{}" }), {})
    end)
end)
