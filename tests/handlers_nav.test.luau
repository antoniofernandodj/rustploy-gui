--!nonstrict
-- Navegação da sidebar, abas e busca (handlers/nav.luau), sem conexão.

local function nova()
    local tela = component("views/app.gvb")
    tela:call("init")
    return tela
end

describe("nav · visões", function()
    test("a sidebar troca a visão e limpa o serviço selecionado", function()
        for acao, visao in {
            nav_deployments = "deployments",
            nav_running = "running",
            nav_monitoring = "monitoring",
            nav_schedules = "schedules",
            nav_ingress = "ingress",
            nav_docker = "docker",
            nav_support = "support",
        } do
            local tela = nova()
            tela:set("selected_service", "svc-1")
            tela:call(acao)
            expect(tela:get("view")):toBe(visao)
            expect(tela:get("selected_service")):toBe("")
        end
    end)

    test("projetos também limpa o projeto selecionado", function()
        local tela = nova()
        tela:set("selected_project_id", "p1")
        tela:call("nav_projects")
        expect(tela:get("view")):toBe("projects")
        expect(tela:get("selected_project_id")):toBe("")
    end)

    test("o Deploy Engine abre na aba da fila, sem pisar numa aba já escolhida", function()
        local tela = nova()
        tela:call("nav_deploy_engine")
        expect(tela:get("view")):toBe("deploy_engine")
        expect(tela:get("deploy_engine_tab")):toBe("fila")

        local outra = nova()
        outra:set("deploy_engine_tab", "historico")
        outra:call("nav_deploy_engine")
        expect(outra:get("deploy_engine_tab")):toBe("historico")
    end)

    test("as configurações abrem na aba web e semeiam o provedor Git sem pisar no escolhido", function()
        local tela = nova()
        tela:call("nav_settings")
        expect(tela:get("view")):toBe("settings")
        expect(tela:get("settings_tab")):toBe("web")
        expect(tela:get("git_provider_kind")):toBe("gitea")
        expect(tela:get("git_provider_mode")):toBe("oauth")

        local escolhido = nova()
        escolhido:set("git_provider_kind", "github")
        escolhido:set("git_provider_mode", "pat")
        escolhido:call("nav_settings")
        expect(escolhido:get("git_provider_kind")):toBe("github")
        expect(escolhido:get("git_provider_mode")):toBe("pat")
    end)

    test("nav genérico vai para a visão pedida e ignora valor vazio", function()
        local tela = nova()
        tela:call("nav", "docker")
        expect(tela:get("view")):toBe("docker")
        tela:call("nav")
        expect(tela:get("view")):toBe("docker")
    end)
end)

describe("nav · abas e campos", function()
    test("cada aba grava a sua chave", function()
        local tela = nova()
        tela:call("project_tab", "jobs")
        tela:call("deploy_engine_tab", "historico")
        tela:call("deploy_tab", "logs")
        tela:call("tab", "domains")
        tela:call("select_provider_tab", "github")
        tela:call("docker_tab", "images")
        expect(tela:get("project_tab")):toBe("jobs")
        expect(tela:get("deploy_engine_tab")):toBe("historico")
        expect(tela:get("deploy_tab")):toBe("logs")
        expect(tela:get("tab")):toBe("domains")
        expect(tela:get("provider_tab")):toBe("github")
        expect(tela:get("docker_tab")):toBe("images")
    end)

    test("o setter genérico field grava a chave com o valor", function()
        local tela = nova()
        tela:call("field", "qualquer_chave")
        expect(tela:get("qualquer_chave")):toBe("")
    end)

    test("a busca guarda o texto como veio e não quebra sem snapshot", function()
        local tela = nova()
        tela:call("search_changed", "Minha API")
        expect(tela:get("search")):toBe("Minha API")
        tela:call("search_changed", "")
        expect(tela:get("search")):toBe("")
    end)
end)
