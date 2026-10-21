--!nonstrict
local SD = require("format/service_detail")

local function postgres_vars()
    return {
        { key = "POSTGRES_DB", value = { Plain = "app" } },
        { key = "POSTGRES_USER", value = { Plain = "u" } },
        { key = "POSTGRES_PASSWORD", value = { Plain = "p" } },
    }
end

describe("service_detail · origem e healthcheck", function()
    test("source_summary_parts de cada origem", function()
        local kind, detalhe, motor = SD.source_summary_parts({ Registry = { image = "nginx:1" } })
        expect(kind):toBe("Registry")
        expect(detalhe):toBe("nginx:1")
        expect(motor):toBe("—")

        kind, detalhe, motor = SD.source_summary_parts({ Git = { url = "https://x/r.git", branch = "main" } })
        expect(kind):toBe("Git")
        expect(detalhe):toBe("https://x/r.git @ main")
        expect(motor):toBe("Dockerfile")

        kind, detalhe, motor = SD.source_summary_parts({ Git = { url = "u", branch = "b", dockerfile_path = "docker/App.Dockerfile" } })
        expect(motor):toBe("docker/App.Dockerfile")

        kind, detalhe = SD.source_summary_parts({ Archive = { original_filename = "app.zip" } })
        expect(kind):toBe("Zip")
        expect(detalhe):toBe("app.zip")

        kind, detalhe, motor = SD.source_summary_parts({ Compose = {} })
        expect(kind):toBe("Compose")
        expect(detalhe):toBe("docker-compose")
        expect(motor):toBe("Compose")
    end)

    test("source_summary_parts de origem ausente", function()
        local kind, detalhe, motor = SD.source_summary_parts(nil)
        expect(kind):toBe("—")
        expect(detalhe):toBe("—")
        expect(motor):toBe("—")
        expect(SD.source_summary_parts({})):toBe("—")
    end)

    test("healthcheck desligado", function()
        expect(SD.healthcheck_summary({ kind = "None" })):toBe("disabled")
    end)

    test("healthcheck HTTP mostra caminho e status esperado", function()
        local texto = SD.healthcheck_summary({
            kind = { Http = { path = "/health", expected_status = 200 } },
            interval_secs = 10, timeout_secs = 5, retries = 3,
        })
        expect(texto):toBe("HTTP /health → 200 · every 10s · timeout 5s · 3 retries")
    end)

    test("healthcheck TCP, Docker e tipo desconhecido", function()
        local campos = { interval_secs = 1, timeout_secs = 2, retries = 4 }
        expect(SD.healthcheck_summary({ kind = "Tcp", interval_secs = 1, timeout_secs = 2, retries = 4 }))
            :toBe("TCP · every 1s · timeout 2s · 4 retries")
        expect(SD.healthcheck_summary({ kind = "DockerNative", interval_secs = 1, timeout_secs = 2, retries = 4 }))
            :toBe("Docker · every 1s · timeout 2s · 4 retries")
        expect(SD.healthcheck_summary({ kind = "Novo", interval_secs = 1, timeout_secs = 2, retries = 4 }))
            :toBe("Novo · every 1s · timeout 2s · 4 retries")
        expect(campos.retries):toBe(4)
    end)
end)

describe("service_detail · containers", function()
    test("cor por estado e id encurtado", function()
        local linhas = json.decode(SD.containers({
            { id = "abcdef0123456789", name = "api", state = "running" },
            { id = "b", name = "db", state = "restarting" },
            { id = "c", name = "x", state = "exited" },
            { id = "d" },
        }))
        expect(#linhas):toBe(4)
        expect(linhas[1].id_short):toBe("abcdef012345")
        expect(linhas[1].id):toBe("abcdef0123456789")
        expect(linhas[1].state_color):toBe("#3FB950")
        expect(linhas[2].state_color):toBe("#D29922")
        expect(linhas[3].state_color):toBe("#8B949E")
        expect(linhas[4].name):toBe("—")
        expect(linhas[4].state):toBe("—")
    end)

    test("sem containers dá []", function()
        expect(SD.containers(nil)):toBe("[]")
        expect(SD.containers({})):toBe("[]")
    end)
end)

describe("service_detail · variáveis de ambiente", function()
    test("segredo aparece por referência, com cadeado, e se distingue do texto igual", function()
        local linhas = json.decode(SD.env_json_with_comments({
            { key = "A", value = { Secret = "t" } },
            { key = "B", value = { Plain = "secret:t" } },
        }, {}))
        expect(linhas[1].kind):toBe("secret")
        expect(linhas[1].value):toBe("🔒 secret:t")
        expect(linhas[2].kind):toBe("plain")
        expect(linhas[2].value):toBe("secret:t")
    end)

    test("a chave longa trunca só na exibição", function()
        local longa = string.rep("K", 40)
        local linha = json.decode(SD.env_json_with_comments({ { key = longa, value = { Plain = "1" } } }, {}))[1]
        expect(linha.key):toBe(longa)
        expect(utf8.len(linha.key_display)):toBe(31)
    end)

    test("comentários voltam para junto da chave a que estavam ancorados", function()
        local linhas = json.decode(SD.env_json_with_comments(
            { { key = "A", value = { Plain = "1" } }, { key = "B", value = { Plain = "2" } } },
            { { before_key = "B", text = "# sobre B" }, { text = "# no fim" } }
        ))
        expect(#linhas):toBe(4)
        expect(linhas[1].key):toBe("A")
        expect(linhas[2].kind):toBe("comment")
        expect(linhas[2].key):toBe("__c0")
        expect(linhas[2].value):toBe("# sobre B")
        expect(linhas[3].key):toBe("B")
        expect(linhas[4].key):toBe("__c1")
        expect(linhas[4].value):toBe("# no fim")
    end)

    test("o .env sai com segredo entre <secret:> e comentários nos lugares", function()
        local texto = SD.env_dotenv_with_comments(
            { { key = "A", value = { Plain = "1" } }, { key = "B", value = { Secret = "S" } } },
            { { before_key = "B", text = "# b" }, { text = "# fim" } }
        )
        expect(texto):toBe("A=1\n# b\nB=<secret:S>\n# fim")
    end)

    test("o .env faz ida e volta com o parser de .env", function()
        local H = require("helpers")
        local vars = {
            { key = "A", value = { Plain = "1" } },
            { key = "B", value = { Secret = "S" } },
            { key = "URL", value = { Plain = "x=y" } },
        }
        local texto = SD.env_dotenv_with_comments(vars, {})
        local lidas = H.parse_dotenv(texto)
        expect(#lidas):toBe(3)
        for i, v in vars do
            expect(lidas[i].key):toBe(v.key)
            expect(lidas[i].value.Plain):toBe(v.value.Plain)
            expect(lidas[i].value.Secret):toBe(v.value.Secret)
        end
    end)

    test("vazio dá [] e string vazia", function()
        expect(SD.env_json_with_comments(nil, nil)):toBe("[]")
        expect(SD.env_dotenv_with_comments(nil, nil)):toBe("")
    end)

    test("secret_rows só carrega nomes", function()
        local linhas = json.decode(SD.secret_rows({ "DB", string.rep("S", 40) }))
        expect(linhas[1].name):toBe("DB")
        expect(utf8.len(linhas[2].name_display)):toBe(31)
        expect(SD.secret_rows(nil)):toBe("[]")
    end)
end)

describe("service_detail · logs", function()
    test("stderr é vermelho, ANSI some e a hora é formatada", function()
        local linhas = json.decode(SD.logs_json({
            { stream = "Stdout", line = "\27[32mok\27[0m", timestamp = "2026-03-01T10:00:00Z" },
            { stream = "Stderr", line = "falhou", timestamp = "2026-03-01T10:00:01Z" },
        }))
        expect(linhas[1].line):toBe("ok")
        expect(linhas[1].color):toBe("#9DA7B3")
        expect(linhas[2].color):toBe("#F85149")
        expect(linhas[1].time):toMatch("^%d%d:%d%d:%d%d$")
    end)

    test("só a cauda de 500 linhas é materializada", function()
        local entradas = {}
        for i = 1, 600 do
            table.insert(entradas, { stream = "Stdout", line = "l" .. i, timestamp = "2026-03-01T10:00:00Z" })
        end
        local linhas = json.decode(SD.logs_json(entradas))
        expect(#linhas):toBe(500)
        expect(linhas[1].line):toBe("l101")
        expect(linhas[500].line):toBe("l600")
    end)

    test("linha absurda é cortada em 2000 caracteres", function()
        local linhas = json.decode(SD.logs_json({ { stream = "Stdout", line = string.rep("x", 5000), timestamp = "2026-03-01T10:00:00Z" } }))
        expect(utf8.len(linhas[1].line)):toBe(2001)
    end)

    test("build_logs_json é o mesmo formatador", function()
        expect(SD.build_logs_json == SD.logs_json):toBe(true)
        expect(SD.logs_json(nil)):toBe("[]")
    end)

    test("join_log_lines junta tudo, sem o teto de linhas", function()
        local entradas = {}
        for i = 1, 600 do
            table.insert(entradas, { line = "l" .. i, timestamp = "2026-03-01T10:00:00Z" })
        end
        local texto = SD.join_log_lines(entradas)
        local n = 0
        for _ in string.gmatch(texto, "[^\n]+") do
            n += 1
        end
        expect(n):toBe(600)
        expect(SD.join_log_lines(nil)):toBe("")
    end)
end)

describe("service_detail · deployments e domínios", function()
    test("linha de deployment: id, estado, duração e se pode apagar", function()
        local linhas = json.decode(SD.deployments_detail({
            { id = "0123456789abcdefXYZ", image = "img:1", state = "Live", started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:01:05Z" },
            { id = "b", state = "BuildingImage", started_at = "2026-03-01T10:00:00Z" },
        }))
        expect(linhas[1].id):toBe("0123456789ab")
        expect(linhas[1].id_full):toBe("0123456789abcdefXYZ")
        expect(linhas[1].state_label):toBe("LIVE")
        expect(linhas[1].state_kind):toBe("ok")
        expect(linhas[1].duration):toBe("1m 5s")
        expect(linhas[1].can_delete):toBe("1")
        expect(linhas[2].can_delete):toBe("0")
    end)

    test("todo estado terminal pode ser apagado, nenhum em andamento", function()
        for estado, esperado in { Live = "1", Stopped = "1", Failed = "1", Pruning = "1", PreDeployCheck = "0", BuildingImage = "0" } do
            local linha = json.decode(SD.deployments_detail({ { id = "x", state = estado, started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:00:01Z" } }))[1]
            expect(linha.can_delete):toBe(esperado)
        end
    end)

    test("a rota sem porta própria herda a do serviço", function()
        local linhas = json.decode(SD.domains_json({
            port = 80,
            domains = { { domain = "a.com", port = 8080, tls = true }, { domain = "b.com" } },
        } :: any))
        expect(linhas[1].port):toBe("8080")
        expect(linhas[1].tls):toBe("true")
        expect(linhas[1].tls_label):toBe("TLS")
        expect(linhas[2].port):toBe("80")
        expect(linhas[2].tls):toBe("false")
        expect(linhas[2].tls_label):toBe("—")
    end)

    test("sem domínio dá []", function()
        expect(SD.domains_json({ port = 80 } :: any)):toBe("[]")
    end)
end)

describe("service_detail · nomes e hosts", function()
    test("safe_name: minúsculas, não-alfanumérico vira _ colapsado e sem bordas", function()
        expect(SD.safe_name("Meu App!")):toBe("meu_app")
        expect(SD.safe_name("--a--b--")):toBe("a_b")
        expect(SD.safe_name("API v2.0")):toBe("api_v2_0")
        expect(SD.safe_name("já")):toBe("j")
        expect(SD.safe_name("")):toBe("")
        expect(SD.safe_name("___")):toBe("")
    end)

    test("compose_host: ingress_service declarado vence", function()
        expect(SD.compose_host("services:\n  web:\n", "proxy")):toBe("proxy")
    end)

    test("compose_host: primeira chave de services:", function()
        expect(SD.compose_host("version: '3'\nservices:\n  web:\n    image: x\n  db:\n    image: y\n", nil)):toBe("web")
        expect(SD.compose_host("services:\n\n  # app\n  api-1.x:\n", "")):toBe("api-1.x")
    end)

    test("compose_host: sem services: ou com o bloco vazio dá nil", function()
        expect(SD.compose_host(nil, nil)):toBeNil()
        expect(SD.compose_host("version: '3'\n", nil)):toBeNil()
        expect(SD.compose_host("services:\nvolumes:\n  v:\n", nil)):toBeNil()
    end)
end)

describe("service_detail · URL interna", function()
    test("esquema por tipo de banco e host rp_<nome>", function()
        expect(SD.internal_url("postgres", "app", 5432)):toBe("postgresql://rp_app:5432")
        expect(SD.internal_url("PostgreSQL", "app", 5432)):toBe("postgresql://rp_app:5432")
        expect(SD.internal_url("mariadb", "app", 3306)):toBe("mysql://rp_app:3306")
        expect(SD.internal_url("redis", "app", 6379)):toBe("redis://rp_app:6379")
        expect(SD.internal_url("mongo", "app", 27017)):toBe("mongodb://rp_app:27017")
        expect(SD.internal_url("rabbitmq", "app", 5672)):toBe("amqp://rp_app:5672")
        expect(SD.internal_url("nats", "app", 4222)):toBe("nats://rp_app:4222")
    end)

    test("serviço comum é http, e kafka é host:porta puro", function()
        expect(SD.internal_url(nil, "app", 80)):toBe("http://rp_app:80")
        expect(SD.internal_url("kafka", "app", 9092)):toBe("rp_app:9092")
    end)

    test("serviço compose usa o nome do YAML, não rp_<nome>", function()
        expect(SD.internal_url(nil, "app", 80, "web")):toBe("http://web:80")
    end)
end)

describe("service_detail · URL externa", function()
    test("domínio HTTP tem prioridade e respeita o TLS", function()
        expect(SD.external_url("app.com", true, 5432, "postgres", "https://1.2.3.4:8443", {})):toBe("https://app.com")
        expect(SD.external_url("app.com//", false, nil, nil, nil, nil)):toBe("http://app.com")
    end)

    test("domínio só com espaços não conta", function()
        expect(SD.external_url("   ", false, nil, nil, nil, nil)):toBe("—")
    end)

    test("sem domínio nem porta publicada, não há URL", function()
        expect(SD.external_url(nil, false, nil, "postgres", "https://h", {})):toBe("—")
        expect(SD.external_url("", false, "", "postgres", "https://h", {})):toBe("—")
    end)

    test("postgres vira string JDBC com as credenciais das env vars", function()
        expect(SD.external_url(nil, false, 5432, "postgres", "https://1.2.3.4:8443", postgres_vars()))
            :toBe("jdbc:postgresql://1.2.3.4:5432/app?user=u&password=p")
    end)

    test("postgres sem credenciais devolve a base intacta", function()
        expect(SD.external_url(nil, false, 5432, "postgresql", "https://1.2.3.4", {}))
            :toBe("jdbc:postgresql://1.2.3.4:5432")
    end)

    test("mysql e mariadb: usuário, senha e banco no userinfo", function()
        local vars = {
            { key = "MYSQL_DATABASE", value = { Plain = "d" } },
            { key = "MYSQL_USER", value = { Plain = "u" } },
            { key = "MYSQL_PASSWORD", value = { Plain = "p" } },
        }
        expect(SD.external_url(nil, false, 3306, "mysql", "https://h:1", vars)):toBe("mysql://u:p@h:3306/d")
        expect(SD.external_url(nil, false, 3306, "mariadb", "https://h:1", vars)):toBe("mariadb://u:p@h:3306/d")
    end)

    test("redis só tem senha: userinfo começa em :", function()
        local vars = { { key = "REDIS_PASSWORD", value = { Plain = "pw" } } }
        expect(SD.external_url(nil, false, 6379, "redis", "https://h", vars)):toBe("redis://:pw@h:6379")
    end)

    test("mongodb leva barra final e authSource=admin quando há usuário", function()
        local vars = {
            { key = "MONGO_INITDB_ROOT_USERNAME", value = { Plain = "root" } },
            { key = "MONGO_INITDB_ROOT_PASSWORD", value = { Plain = "pw" } },
        }
        expect(SD.external_url(nil, false, 27017, "mongodb", "https://h", vars)):toBe("mongodb://root:pw@h:27017/?authSource=admin")
        expect(SD.external_url(nil, false, 27017, "mongo", "https://h", {})):toBe("mongodb://h:27017/")
    end)

    test("rabbitmq e nats", function()
        local vars = {
            { key = "RABBITMQ_DEFAULT_USER", value = { Plain = "guest" } },
            { key = "RABBITMQ_DEFAULT_PASS", value = { Plain = "guest" } },
        }
        expect(SD.external_url(nil, false, 5672, "rabbitmq", "https://h", vars)):toBe("amqp://guest:guest@h:5672")
        expect(SD.external_url(nil, false, 4222, "nats", "https://h", {})):toBe("nats://h:4222")
    end)

    test("sem esquema de banco (kafka, serviço comum) é host:porta puro", function()
        expect(SD.external_url(nil, false, 9092, "kafka", "https://h", {})):toBe("h:9092")
        expect(SD.external_url(nil, false, 8080, nil, "https://h", {})):toBe("h:8080")
    end)

    test("senha com caracteres reservados é percent-encoded", function()
        local vars = {
            { key = "MYSQL_USER", value = { Plain = "u@x" } },
            { key = "MYSQL_PASSWORD", value = { Plain = "p@ss:w/d?#" } },
        }
        expect(SD.external_url(nil, false, 3306, "mysql", "https://h", vars)):toBe("mysql://u%40x:p%40ss%3Aw%2Fd%3F%23@h:3306")
    end)

    test("segredo (referência) não vira credencial", function()
        local vars = { { key = "REDIS_PASSWORD", value = { Secret = "S" } } }
        expect(SD.external_url(nil, false, 6379, "redis", "https://h", vars)):toBe("redis://h:6379")
    end)

    test("o host sai do api_url, ou <host> quando ele falta", function()
        expect(SD.external_url(nil, false, 1, "kafka", "http://10.0.0.5:9797/x", {})):toBe("10.0.0.5:1")
        expect(SD.external_url(nil, false, 1, "kafka", "srv.com", {})):toBe("srv.com:1")
        expect(SD.external_url(nil, false, 1, "kafka", nil, {})):toBe("<host>:1")
        expect(SD.external_url(nil, false, 1, "kafka", "   ", {})):toBe("<host>:1")
    end)
end)
