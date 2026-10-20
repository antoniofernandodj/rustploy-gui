local Running = require("format/running")

local function service(overrides)
    local base = {
        service_id = "s1",
        name = "api",
        status = "Running",
        kind = "git",
        kind_label = "App · Git",
        branch = "main",
        repo_url = "https://example.com/r.git",
        port = 8080,
        domains = { "app.example.com" },
        webhook = "https://host/webhook/s1/secrettoken",
        pre_deploy_checks = { { job_id = "j1", name = "migrate" } },
    }
    for key, value in pairs(overrides or {}) do
        base[key] = value
    end
    return base
end

local function dashboard(services)
    return { { project_id = "p1", project_name = "loja", services = services } }
end

describe("format/running", function()
    test("mascara o token do webhook por padrão", function()
        local encoded = Running.running(dashboard({ service() }), {}, "", {})
        local projects = json.decode(encoded)
        expect(projects[1].rows[1].cards[1].webhook_shown):toBe("https://host/webhook/s1/••••••••")
        expect(projects[1].rows[1].cards[1].webhook):toBe("https://host/webhook/s1/secrettoken")
    end)

    test("mostra o webhook inteiro quando revelado", function()
        local encoded = Running.running(dashboard({ service() }), {}, "", { s1 = true })
        local projects = json.decode(encoded)
        expect(projects[1].rows[1].cards[1].webhook_shown):toBe("https://host/webhook/s1/secrettoken")
        expect(projects[1].rows[1].cards[1].reveal_label):toBe("Ocultar")
    end)

    test("lista os pré-deploy checks na ordem", function()
        local checks = { { job_id = "a", name = "migrate" }, { job_id = "b", name = "seed" } }
        local encoded = Running.running(dashboard({ service({ pre_deploy_checks = checks }) }), {}, "", {})
        expect(json.decode(encoded)[1].rows[1].cards[1].checks):toBe("1. migrate\n2. seed")
    end)

    test("banco mostra o motor e a porta", function()
        local db = service({ kind = "database", engine = "postgres", branch = nil, port = 5432 })
        local encoded = Running.running(dashboard({ db }), {}, "", {})
        expect(json.decode(encoded)[1].rows[1].cards[1].detail):toBe("motor: postgres · porta 5432")
    end)

    test("serviço sem webhook avisa", function()
        local without_webhook = service()
        without_webhook.webhook = nil
        local encoded = Running.running(dashboard({ without_webhook }), {}, "", {})
        local card = json.decode(encoded)[1].rows[1].cards[1]
        expect(card.has_webhook):toBe("false")
        expect(card.webhook_shown):toBe("sem webhook")
    end)

    test("a busca filtra serviços e some com projeto sem resultado", function()
        local encoded, total = Running.running(dashboard({ service() }), {}, "zzz", {})
        expect(encoded):toBe("[]")
        expect(total):toBe(0)
    end)
end)
