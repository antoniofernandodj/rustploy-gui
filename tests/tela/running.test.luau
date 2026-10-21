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

--- mascara o token do webhook por padrão
function test_mascara_o_token_do_webhook_por_padrao()
    local encoded = Running.running(dashboard({ service() }), {}, "", {})
    local projects = json.decode(encoded)
    assert_eq(projects[1].rows[1].cards[1].webhook_shown, "https://host/webhook/s1/••••••••")
    assert_eq(projects[1].rows[1].cards[1].webhook, "https://host/webhook/s1/secrettoken")
end

--- mostra o webhook inteiro quando revelado
function test_mostra_o_webhook_inteiro_quando_revelado()
    local encoded = Running.running(dashboard({ service() }), {}, "", { s1 = true })
    local projects = json.decode(encoded)
    assert_eq(projects[1].rows[1].cards[1].webhook_shown, "https://host/webhook/s1/secrettoken")
    assert_eq(projects[1].rows[1].cards[1].reveal_label, "Ocultar")
end

--- lista os pré-deploy checks na ordem
function test_lista_os_pre_deploy_checks_na_ordem()
    local checks = { { job_id = "a", name = "migrate" }, { job_id = "b", name = "seed" } }
    local encoded = Running.running(dashboard({ service({ pre_deploy_checks = checks }) }), {}, "", {})
    assert_eq(json.decode(encoded)[1].rows[1].cards[1].checks, "1. migrate\n2. seed")
end

--- banco mostra o motor e a porta
function test_banco_mostra_o_motor_e_a_porta()
    local db = service({ kind = "database", engine = "postgres", branch = nil, port = 5432 })
    local encoded = Running.running(dashboard({ db }), {}, "", {})
    assert_eq(json.decode(encoded)[1].rows[1].cards[1].detail, "motor: postgres · porta 5432")
end

--- serviço sem webhook avisa
function test_servico_sem_webhook_avisa()
    local without_webhook = service()
    without_webhook.webhook = nil
    local encoded = Running.running(dashboard({ without_webhook }), {}, "", {})
    local card = json.decode(encoded)[1].rows[1].cards[1]
    assert_eq(card.has_webhook, "false")
    assert_eq(card.webhook_shown, "sem webhook")
end

--- a busca filtra serviços e some com projeto sem resultado
function test_a_busca_filtra_servicos_e_some_com_projeto_sem_resultado()
    local encoded, total = Running.running(dashboard({ service() }), {}, "zzz", {})
    assert_eq(encoded, "[]")
    assert_eq(total, 0)
end
