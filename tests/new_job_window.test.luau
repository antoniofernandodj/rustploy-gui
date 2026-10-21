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

describe("novo job · init", function()
    test("abre escolhendo o projeto, com o formulário zerado", function()
        local tela = nova()
        expect(tela:get("new_job_step")):toBe("pick_project")
        expect(tela:get("new_job_name")):toBe("")
        expect(tela:get("new_job_compose")):toBe("")
        expect(tela:get("new_job_main_service")):toBe("")
        expect(tela:get("new_job_edit_id")):toBe("")
        expect(tela:get("new_job_error")):toBe("")
        expect(tela:get("new_job_busy")):toBe("")
    end)

    test("os padrões da recorrência: manual, a cada 6h, 03:00, segunda", function()
        local tela = nova()
        expect(tela:get("new_job_kind")):toBe("manual")
        expect(tela:get("new_job_hours")):toBe("6")
        expect(tela:get("new_job_time")):toBe("03:00")
        expect(tela:get("new_job_weekday")):toBe("0")
        expect(tela:get("new_job_enabled")):toBe("true")
    end)

    test("a fonte do compose começa em colado, com o caminho padrão", function()
        local tela = nova()
        expect(tela:get("new_job_source")):toBe("compose")
        expect(tela:get("new_job_compose_path")):toBe("docker-compose.yml")
        expect(tela:get("new_job_git_providers")):toBe("[]")
        expect(tela:get("new_job_git_repos")):toBe("[]")
    end)

    test("os catálogos semeados pelo pai ficam à disposição", function()
        local tela = nova({ new_job_projects = PROJETOS, new_job_services = SERVICOS })
        expect(tela:get("new_job_projects")):toBe(PROJETOS)
        expect(tela:get("new_job_services_all")):toBe(SERVICOS)
        expect(tela:get("new_job_services_filtered")):toBe("[]")
    end)

    test("sem catálogo os projetos nascem []", function()
        expect(nova():get("new_job_projects")):toBe("[]")
    end)

    test("os dias da semana vêm do formatador", function()
        expect(#json.decode(nova():get("weekdays") or "[]")):toBe(7)
    end)
end)

describe("novo job · modo edição", function()
    local function editando(job)
        return nova({ new_job_edit_job = json.encode(job) })
    end

    test("pula direto para o formulário e preenche o job", function()
        local tela = editando({ id = "j1", name = "migrar", main_service = "app", compose = "services: {}", enabled = true })
        expect(tela:get("new_job_edit_id")):toBe("j1")
        expect(tela:get("new_job_step")):toBe("form")
        expect(tela:get("new_job_name")):toBe("migrar")
        expect(tela:get("new_job_main_service")):toBe("app")
        expect(tela:get("new_job_compose")):toBe("services: {}")
        expect(tela:get("new_job_enabled")):toBe("true")
    end)

    test("job pausado vem desmarcado", function()
        expect(editando({ id = "j", enabled = false }):get("new_job_enabled")):toBe("false")
    end)

    test("recorrência de intervalo", function()
        local tela = editando({ id = "j", recurrence = { IntervalHours = 12 } })
        expect(tela:get("new_job_kind")):toBe("interval")
        expect(tela:get("new_job_hours")):toBe("12")
    end)

    test("recorrência diária vira HH:MM", function()
        local tela = editando({ id = "j", recurrence = { Daily = { hour = 7, minute = 5 } } })
        expect(tela:get("new_job_kind")):toBe("daily")
        expect(tela:get("new_job_time")):toBe("07:05")
    end)

    test("recorrência semanal guarda o dia e o horário", function()
        local tela = editando({ id = "j", recurrence = { Weekly = { weekday = 3, hour = 9, minute = 30 } } })
        expect(tela:get("new_job_kind")):toBe("weekly")
        expect(tela:get("new_job_weekday")):toBe("3")
        expect(tela:get("new_job_time")):toBe("09:30")
    end)

    test("sem recorrência (ou desconhecida) é manual com os padrões", function()
        for _, job in { { id = "j" }, { id = "j", recurrence = { Mensal = {} } } } do
            local tela = editando(job)
            expect(tela:get("new_job_kind")):toBe("manual")
            expect(tela:get("new_job_hours")):toBe("6")
            expect(tela:get("new_job_time")):toBe("03:00")
        end
    end)

    test("job com fonte git troca a fonte e os campos do picker", function()
        local tela = editando({
            id = "j",
            git_source = { provider_id = "gp1", branch = "main", compose_path = "ci/compose.yml" },
        })
        expect(tela:get("new_job_source")):toBe("git")
        expect(tela:get("new_job_git_provider_id")):toBe("gp1")
        expect(tela:get("new_job_git_branch")):toBe("main")
        expect(tela:get("new_job_compose_path")):toBe("ci/compose.yml")
        expect(tela:get("new_job_compose")):toBe("")
    end)

    test("git sem compose_path usa o padrão", function()
        local tela = editando({ id = "j", git_source = { branch = "dev" } })
        expect(tela:get("new_job_compose_path")):toBe("docker-compose.yml")
    end)

    test("as variáveis do job voltam como .env, com segredo e comentário", function()
        local tela = editando({
            id = "j",
            env_vars = { { key = "A", value = { Plain = "1" } }, { key = "B", value = { Secret = "S" } } },
            env_comments = { { before_key = "B", text = "# b" } },
        })
        expect(tela:get("new_job_env_text")):toBe("A=1\n# b\nB=<secret:S>")
    end)

    test("JSON de edição ilegível é ignorado: abre como job novo", function()
        local tela = nova({ new_job_edit_job = "isso não é json" })
        expect(tela:get("new_job_edit_id")):toBe("")
        expect(tela:get("new_job_step")):toBe("pick_project")
    end)
end)

describe("novo job · passos", function()
    local function com_catalogo()
        return nova({ new_job_projects = PROJETOS, new_job_services = SERVICOS })
    end

    test("escolher o projeto filtra os serviços dele e avança", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "p1")
        expect(tela:get("new_job_project_id")):toBe("p1")
        expect(tela:get("new_job_project_name")):toBe("loja")
        expect(tela:get("new_job_step")):toBe("pick_service")
        local nomes = {}
        for _, s in json.decode(tela:get("new_job_services_filtered") or "[]") do
            table.insert(nomes, s.name)
        end
        expect(nomes):toEqual({ "api", "web" })
    end)

    test("outro projeto, outros serviços", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "p2")
        expect(tela:get("new_job_project_name")):toBe("blog")
        expect(#json.decode(tela:get("new_job_services_filtered") or "[]")):toBe(1)
    end)

    test("projeto desconhecido não acha nome nem serviço, mas o passo avança", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "zzz")
        expect(tela:get("new_job_project_name")):toBe("")
        expect(tela:get("new_job_services_filtered")):toBe("[]")
    end)

    test("escolher o serviço gatilho guarda o nome e vai ao formulário", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "p1")
        tela:call("new_job_pick_service", "s2")
        expect(tela:get("new_job_service_id")):toBe("s2")
        expect(tela:get("new_job_service_name")):toBe("web")
        expect(tela:get("new_job_step")):toBe("form")
    end)

    test("job autônomo: sem serviço gatilho", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "p1")
        tela:call("new_job_pick_no_service")
        expect(tela:get("new_job_service_id")):toBe("")
        expect(tela:get("new_job_service_name")):toBe("nenhum (autônomo)")
        expect(tela:get("new_job_step")):toBe("form")
    end)

    test("voltar recua um passo por vez", function()
        local tela = com_catalogo()
        tela:call("new_job_pick_project", "p1")
        tela:call("new_job_pick_service", "s1")
        expect(tela:get("new_job_step")):toBe("form")
        tela:call("new_job_back")
        expect(tela:get("new_job_step")):toBe("pick_service")
        tela:call("new_job_back")
        expect(tela:get("new_job_step")):toBe("pick_project")
        tela:call("new_job_back")
        expect(tela:get("new_job_step")):toBe("pick_project")
    end)

    test("o tipo de recorrência e o setter genérico", function()
        local tela = nova()
        tela:call("new_job_kind", "weekly")
        expect(tela:get("new_job_kind")):toBe("weekly")
        tela:call("field", "new_job_name")
        expect(tela:get("new_job_name")):toBe("")
    end)
end)

describe("novo job · fonte git", function()
    test("trocar a fonte sem conexão só grava a escolha", function()
        local tela = nova()
        tela:call("new_job_source", "git")
        expect(tela:get("new_job_source")):toBe("git")
        expect(tela:get("new_job_git_message")):toBe("")
        tela:call("new_job_source", "compose")
        expect(tela:get("new_job_source")):toBe("compose")
    end)

    test("escolher a conta zera repositório, repos e branches", function()
        local tela = nova({ new_job_git_repo = "a/b", new_job_git_repos = "[1]", new_job_git_branches = "[1]" })
        tela:call("new_job_git_provider_pick", "gp1")
        expect(tela:get("new_job_git_provider_id")):toBe("gp1")
        expect(tela:get("new_job_git_repo")):toBe("")
        expect(tela:get("new_job_git_repos")):toBe("[]")
        expect(tela:get("new_job_git_branches")):toBe("[]")
    end)

    test("escolher o repositório adota a branch padrão dele", function()
        local repos = json.encode({
            { full_name = "a/b", clone_url = "u1", default_branch = "main" },
            { full_name = "a/c", clone_url = "u2", default_branch = "" },
        })
        local tela = nova({ new_job_git_repos = repos })
        tela:call("new_job_git_repo_pick", "a/b")
        expect(tela:get("new_job_git_repo")):toBe("a/b")
        expect(tela:get("new_job_git_branch")):toBe("main")
        expect(tela:get("new_job_git_branches")):toBe("[]")
    end)

    test("repositório sem branch padrão deixa a branch como estava", function()
        local repos = json.encode({ { full_name = "a/c", clone_url = "u2", default_branch = "" } })
        local tela = nova({ new_job_git_repos = repos })
        tela:call("new_job_git_repo_pick", "a/c")
        expect(tela:get("new_job_git_branch")):toBe("")
    end)
end)

describe("novo job · criar (só até a validação recusar)", function()
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

    test("sem conexão manda reabrir a janela", function()
        local tela = nova()
        tela:set("new_job_name", "x")
        tela:call("new_job_create")
        expect(tela:get("new_job_error")):toBe("sem conexão — reabra a janela pelo app")
    end)

    test("o nome é obrigatório, mesmo só de espaços", function()
        expect((erro_ao_criar({ new_job_name = "   " }))):toBe("informe um nome")
        expect((erro_ao_criar({}))):toBe("informe um nome")
    end)

    test("o main_service é obrigatório", function()
        local erro = erro_ao_criar({ new_job_name = "migrar", new_job_main_service = " " })
        expect(erro):toContain("main_service")
    end)

    test("fonte compose pede o docker-compose colado", function()
        local erro = erro_ao_criar({ new_job_name = "migrar", new_job_main_service = "app", new_job_compose = "  \n " })
        expect(erro):toBe("cole o docker-compose.yml do job")
    end)

    test("fonte git pede repositório e branch", function()
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
            expect((erro_ao_criar(campos, "git"))):toBe("selecione repositório e branch")
        end
    end)

    test("git com repositório que não está na lista pede para selecionar de novo", function()
        local erro = erro_ao_criar({
            new_job_name = "migrar", new_job_main_service = "app",
            new_job_git_repo = "a/b", new_job_git_branch = "main", new_job_git_repos = "[]",
        }, "git")
        expect(erro):toContain("não foi possível resolver a URL")
    end)

    test("o erro some quando o formulário passa a validar (limpa antes de ir à rede)", function()
        local tela = conectada({ new_job_name = "migrar", new_job_main_service = "app", new_job_compose = "services: {}" })
        tela:set("new_job_error", "velho")
        tela:call("new_job_create") -- passa da validação: o RPC suspende
        expect(tela:get("new_job_error")):toBe("")
        expect(tela:get("new_job_message")):toBe("criando…")
    end)

    test("o formulário recusado não deixa o botão travado", function()
        local _, tela = erro_ao_criar({ new_job_name = "migrar" })
        expect(tela:get("new_job_busy")):toBe("")
        expect(tela:get("new_job_message")):toBe("")
    end)
end)
