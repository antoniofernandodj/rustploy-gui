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

describe("connection · init", function()
    test("a janela nasce no login, na visão de deployments, desconectada", function()
        local tela = nova()
        expect(tela:get("screen")):toBe("login")
        expect(tela:get("view")):toBe("deployments")
        expect(tela:get("connected")):toBe("false")
        expect(tela:get("status_line")):toBe("pronto para conectar")
        expect(tela:get("menu")):toBe("true")
        expect(tela:get("search")):toBe("")
        expect(tela:get("error")):toBe("")
    end)

    test("o init não pisa no que já estava no contexto", function()
        local tela = nova({ view = "docker", menu = "false", search = "api", status_line = "x" })
        expect(tela:get("view")):toBe("docker")
        expect(tela:get("menu")):toBe("false")
        expect(tela:get("search")):toBe("api")
        expect(tela:get("status_line")):toBe("x")
    end)

    test("as listas nascem como [] e não nil (o for-each não pode ler literal)", function()
        local tela = nova()
        for _, chave in { "deployments", "projects", "services", "service_rows", "docker_images", "jobs_summary", "running", "project_services" } do
            expect(tela:get(chave)):toBe("[]")
        end
    end)

    test("os contadores nascem … e não 0: 0 afirmaria vazio antes do primeiro snapshot", function()
        local tela = nova()
        for _, chave in { "projects_count", "services_count", "jobs_count", "docker_images_count", "services_running", "deploy_engine_total_24h" } do
            expect(tela:get(chave)):toBe("…")
        end
        expect(tela:get("data_loading")):toBe("true")
    end)

    test("o contador já publicado não é trocado por …", function()
        local tela = nova({ projects_count = "7" })
        expect(tela:get("projects_count")):toBe("7")
    end)

    test("as coleções fixas dos widgets são JSON de {id,label}", function()
        local tela = nova()
        for _, chave in { "settings_tabs", "docker_cleanup_kinds", "git_provider_modes", "healthcheck_kinds", "weekdays" } do
            local itens = json.decode(tela:get(chave) or "")
            expect(#itens > 0):toBe(true)
            for _, item in itens do
                expect(type(item.id)):toBe("string")
                expect(type(item.label)):toBe("string")
            end
        end
        local abas = json.decode(tela:get("settings_tabs") or "")
        expect(abas[1].id):toBe("web")
    end)

    test("o init aponta o servidor da chave semeada", function()
        local tela = nova()
        expect(tela:get("access_key_target")):toBe("conecta em zz-teste.invalid:1")
    end)

    test("os checkboxes de IaC nascem desmarcados", function()
        local tela = nova()
        expect(tela:get("manifest_prune")):toBe("false")
        expect(tela:get("manifest_deploy")):toBe("false")
    end)
end)

describe("connection · campo do token", function()
    test("digitar uma chave válida mostra o servidor e limpa o erro", function()
        local tela = nova()
        tela:set("error_access_key", "velho")
        tela:call("access_key_input", AccessKey.encode("https://outro.invalid:9797", "t"))
        expect(tela:get("access_key_target")):toBe("conecta em outro.invalid:9797")
        expect(tela:get("error_access_key")):toBe("")
    end)

    test("uma chave inválida não mostra servidor nenhum", function()
        local tela = nova()
        tela:call("access_key_input", "isso-nao-e-base64!!")
        expect(tela:get("access_key_target")):toBe("")
        expect(tela:get("access_key")):toBe("isso-nao-e-base64!!")
    end)

    test("escolher um servidor salvo preenche o campo do mesmo jeito", function()
        local tela = nova()
        local chave = AccessKey.encode("https://salvo.invalid:1", "t")
        tela:call("choose_saved_server", chave)
        expect(tela:get("access_key")):toBe(chave)
        expect(tela:get("access_key_target")):toBe("conecta em salvo.invalid:1")
    end)

    test("a lista de servidores salvos é um array JSON", function()
        local tela = nova()
        expect(type(json.decode(tela:get("saved_servers") or "null"))):toBe("table")
    end)
end)

describe("connection · connect (só o que falha antes da rede)", function()
    test("sem token pede para colar", function()
        local tela = nova()
        tela:set("access_key", "")
        tela:call("connect")
        expect(tela:get("error_access_key")):toContain("cole o token")
        expect(tela:get("screen")):toBe("login")
        expect(tela:get("connected")):toBe("false")
    end)

    test("o token da API no lugar do de conexão é explicado", function()
        local tela = nova()
        tela:set("access_key", "0123456789abcdef0123456789abcdef")
        tela:call("connect")
        expect(tela:get("error_access_key")):toContain("não é um token de conexão")
        expect(tela:get("screen")):toBe("login")
    end)

    test("chave corrompida avisa e não muda de tela", function()
        local tela = nova()
        tela:set("access_key", "!!!!")
        tela:call("connect")
        expect(tela:get("error_access_key")):toContain("corrompido")
        expect(tela:get("api_token")):toBeNil()
    end)
end)

describe("connection · disconnect", function()
    test("apaga o contexto da sessão e volta ao login", function()
        local tela = nova()
        tela:set("api_token", "segredo")
        tela:set("api_url", "https://x")
        tela:set("running", "[{\"p\":1}]")
        tela:set("projeto_aberto", "loja")
        tela:set("screen", "shell")
        tela:set("connected", "true")
        tela:call("disconnect")
        expect(tela:get("screen")):toBe("login")
        expect(tela:get("connected")):toBe("false")
        expect(tela:get("status_line")):toBe("desconectado")
        expect(tela:get("api_token")):toBeNil()
        expect(tela:get("api_url")):toBeNil()
        expect(tela:get("projeto_aberto")):toBeNil()
    end)

    test("não enumera chaves: o init semeia os defaults de novo, como no boot", function()
        local tela = nova()
        tela:set("view", "docker")
        tela:set("chave_de_uma_tela_nova", "x")
        tela:call("disconnect")
        expect(tela:get("view")):toBe("deployments")
        expect(tela:get("chave_de_uma_tela_nova")):toBeNil()
        expect(tela:get("projects")):toBe("[]")
        expect(tela:get("projects_count")):toBe("…")
    end)
end)
