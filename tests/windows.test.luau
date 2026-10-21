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

describe("janela · exportar serviço", function()
    test("o init resume o plano", function()
        local tela = exportar()
        expect(tela:get("export_service")):toBe("api")
        expect(tela:get("export_project")):toBe("loja")
        expect(tela:get("export_service_vars")):toBe("A, S 🔒")
        expect(tela:get("export_service_count")):toBe("2")
        expect(tela:get("export_has_vars")):toBe("true")
        expect(tela:get("export_values")):toBe("true")
        expect(tela:get("export_error")):toBe("")
        expect(tela:get("export_yaml")):toBe("")
    end)

    test("as variáveis do projeto nascem marcadas só quando o serviço as cita", function()
        local tela = exportar()
        local vars = linhas(tela)
        expect(vars.DB.mark):toBe("☑")
        expect(vars.LOG.mark):toBe("☐")
        expect(vars.TOK.mark):toBe("☑")
        expect(tela:get("export_picked_count")):toBe("2")
    end)

    test("as etiquetas dizem se é secret e se o serviço a cita", function()
        local vars = linhas(exportar())
        expect(vars.DB.tag):toBe("citada pelo serviço")
        expect(vars.LOG.tag):toBe("")
        expect(vars.TOK.tag):toBe("secret · citada pelo serviço")
    end)

    test("alternar uma variável inverte só ela", function()
        local tela = exportar()
        tela:call("export_toggle", "LOG")
        expect(linhas(tela).LOG.mark):toBe("☑")
        expect(tela:get("export_picked_count")):toBe("3")
        tela:call("export_toggle", "LOG")
        expect(linhas(tela).LOG.mark):toBe("☐")
        expect(tela:get("export_picked_count")):toBe("2")
    end)

    test("todas, nenhuma e sugeridas", function()
        local tela = exportar()
        tela:call("export_all")
        expect(tela:get("export_picked_count")):toBe("3")
        tela:call("export_none")
        expect(tela:get("export_picked_count")):toBe("0")
        expect(linhas(tela).DB.mark):toBe("☐")
        tela:call("export_suggested")
        expect(tela:get("export_picked_count")):toBe("2")
        expect(linhas(tela).LOG.mark):toBe("☐")
    end)

    test("o plano bloqueado repassa o motivo", function()
        local plano = { service_name = "x", blocked = "serviço compose não exporta" }
        expect(exportar(plano):get("export_blocked")):toBe("serviço compose não exporta")
    end)

    test("plano vazio ou ilegível não quebra: sem variáveis e lista []", function()
        for _, texto in { "{}", "isso não é json" } do
            local tela = janela("views/service_export_window.gvb", { export_plan = texto })
            expect(tela:get("export_service")):toBe("")
            expect(tela:get("export_service_vars")):toBe("(este serviço não tem variáveis próprias)")
            expect(tela:get("export_service_count")):toBe("0")
            expect(tela:get("export_has_vars")):toBe("false")
            expect(tela:get("export_vars")):toBe("[]")
            expect(tela:get("export_picked_count")):toBe("0")
        end
    end)

    test("mostrar o pacote sem conexão explica o que fazer", function()
        local tela = exportar()
        tela:call("export_show")
        expect(tela:get("export_error")):toBe("sem conexão — reabra a janela pelo app")
        expect(tela:get("export_yaml")):toBe("")
    end)

    test("o setter field grava a chave pedida", function()
        local tela = exportar()
        tela:call("field", "export_values")
        expect(tela:get("export_values")):toBe("")
    end)
end)

-- ── Logs ao vivo ────────────────────────────────────────────────────────────

describe("janela · logs", function()
    local function semente(n)
        local linhas_log = {}
        for i = 1, n do
            table.insert(linhas_log, { line = "linha " .. i, timestamp = "2026-03-01T10:00:00Z" })
        end
        return json.encode(linhas_log)
    end

    test("o histórico semeado vira texto, uma linha por evento, terminado em \\n", function()
        local tela = janela("views/log_window.gvb", { log_window_seed = semente(3) })
        expect(tela:get("log_window_count")):toBe("3")
        local texto = tela:get("log_window_logs_text") or ""
        expect(texto):toMatch("^%d%d:%d%d:%d%d linha 1\n")
        expect(texto):toMatch("linha 3\n$")
        local n = 0
        for _ in string.gmatch(texto, "[^\n]+") do
            n += 1
        end
        expect(n):toBe(3)
    end)

    test("sem semente a janela abre vazia", function()
        local tela = janela("views/log_window.gvb")
        expect(tela:get("log_window_count")):toBe("0")
        expect(tela:get("log_window_logs_text")):toBe("")
    end)

    test("semente ilegível é tratada como vazia", function()
        local tela = janela("views/log_window.gvb", { log_window_seed = "não é json" })
        expect(tela:get("log_window_count")):toBe("0")
    end)

    test("o título padrão é Logs, e o que o pai mandou vale", function()
        expect(janela("views/log_window.gvb"):get("log_window_title")):toBe("Logs")
        expect(janela("views/log_window.gvb", { log_window_title = "api · build" }):get("log_window_title")):toBe("api · build")
    end)
end)

-- ── Novo projeto ────────────────────────────────────────────────────────────

describe("janela · novo projeto", function()
    test("o init zera mensagens e semeia os campos sem pisar no que veio", function()
        local tela = janela("views/new_project_form.gvb")
        expect(tela:get("new_project_name")):toBe("")
        expect(tela:get("new_project_description")):toBe("")
        expect(tela:get("new_project_error")):toBe("")
        expect(tela:get("new_project_message")):toBe("")
        local preenchida = janela("views/new_project_form.gvb", { new_project_name = "loja" })
        expect(preenchida:get("new_project_name")):toBe("loja")
    end)

    test("a falha de validação só avisa", function()
        local tela = janela("views/new_project_form.gvb")
        tela:call("new_project_show_validation_errors", "[]")
        expect(tela:toasts()[1].message):toBe("Corrija os campos destacados")
        expect(tela:toasts()[1].kind):toBe("warning")
    end)

    test("criar sem a conexão semeada manda reabrir a janela", function()
        local tela = janela("views/new_project_form.gvb", { new_project_name = "loja" })
        tela:call("submit_project")
        expect(tela:get("new_project_error")):toBe("sem conexão — reabra a janela pelo app")
        expect(tela:get("new_project_busy")):toBe("")
    end)
end)

-- ── Novo token do registry ──────────────────────────────────────────────────

describe("janela · novo token do registry", function()
    test("o init abre no formulário com escopo de leitura", function()
        local tela = janela("views/new_registry_token_window.gvb")
        expect(tela:get("new_registry_token_step")):toBe("form")
        expect(tela:get("new_registry_token_scope")):toBe("pull")
        expect(tela:get("new_registry_token_name")):toBe("")
        expect(tela:get("new_registry_token_login_command")):toBe("")
    end)

    test("os escopos oferecidos são pull e push", function()
        local escopos = json.decode(janela("views/new_registry_token_window.gvb"):get("new_registry_token_scopes") or "[]")
        expect(#escopos):toBe(2)
        expect(escopos[1].id):toBe("pull")
        expect(escopos[2].id):toBe("push")
    end)

    test("o host do registry vem do pai, com um padrão local", function()
        expect(janela("views/new_registry_token_window.gvb"):get("registry_host")):toBe("127.0.0.1:5100")
        expect(janela("views/new_registry_token_window.gvb", { registry_host = "r.exemplo.com" }):get("registry_host")):toBe("r.exemplo.com")
    end)

    test("criar sem conexão e a falha de validação", function()
        local tela = janela("views/new_registry_token_window.gvb")
        tela:call("new_registry_token_create")
        expect(tela:get("new_registry_token_error")):toBe("sem conexão — reabra a janela pelo app")
        expect(tela:get("new_registry_token_step")):toBe("form")
        tela:call("new_registry_token_show_validation_errors", "[]")
        expect(tela:toasts()[1].message):toBe("Informe o nome do token")
    end)
end)

-- ── Novo serviço ────────────────────────────────────────────────────────────

describe("janela · novo serviço", function()
    local function wizard(ctx_inicial)
        local base = { project_name = "loja", new_service_templates = "[]" }
        for k, v in ctx_inicial or {} do
            base[k] = v
        end
        return janela("views/new_service_window.gvb", base)
    end

    test("abre escolhendo o tipo, com o formulário zerado", function()
        local tela = wizard()
        expect(tela:get("new_service_step")):toBe("pick_type")
        expect(tela:get("new_service_name")):toBe("")
        expect(tela:get("new_service_template_search")):toBe("")
        expect(tela:get("new_service_busy")):toBe("")
    end)

    test("pedida para importar, abre direto no passo de importação", function()
        expect(wizard({ new_service_start = "import" }):get("new_service_step")):toBe("import_form")
    end)

    test("o passo de importação nasce zerado", function()
        local tela = wizard()
        expect(tela:get("import_text")):toBe("")
        expect(tela:get("import_report")):toBe("false")
        expect(tela:get("import_drop_domains")):toBe("false")
        expect(tela:get("import_deploy")):toBe("false")
    end)

    test("catálogo ilegível não derruba a janela", function()
        local tela = wizard({ new_service_templates = "não é json" })
        expect(tela:get("new_service_step")):toBe("pick_type")
    end)

    test("o setter field existe nesta janela (digitar nos inputs escreve no ctx)", function()
        local tela = wizard()
        tela:call("field", "new_service_name")
        expect(tela:get("new_service_name")):toBe("")
    end)
end)
