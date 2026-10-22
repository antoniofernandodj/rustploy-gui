--!nonstrict
local SD = require("format/service_detail")

local function postgres_vars()
    return {
        { key = "POSTGRES_DB", value = { Plain = "app" } },
        { key = "POSTGRES_USER", value = { Plain = "u" } },
        { key = "POSTGRES_PASSWORD", value = { Plain = "p" } },
    }
end

--- source_summary_parts de cada origem
function test_origem_e_healthcheck__source_summary_parts_de_cada_origem()
    local kind, detalhe, motor =
        SD.source_summary_parts({ Registry = { image = "nginx:1" } })
    assert_eq(kind, "Registry")
    assert_eq(detalhe, "nginx:1")
    assert_eq(motor, "—")

    kind, detalhe, motor = SD.source_summary_parts({
        Git = { url = "https://x/r.git", branch = "main" },
    })
    assert_eq(kind, "Git")
    assert_eq(detalhe, "https://x/r.git @ main")
    assert_eq(motor, "Dockerfile")

    kind, detalhe, motor = SD.source_summary_parts({
        Git = {
            url = "u",
            branch = "b",
            dockerfile_path = "docker/App.Dockerfile",
        },
    })
    assert_eq(motor, "docker/App.Dockerfile")

    kind, detalhe = SD.source_summary_parts({
        Archive = { original_filename = "app.zip" },
    })
    assert_eq(kind, "Zip")
    assert_eq(detalhe, "app.zip")

    kind, detalhe, motor = SD.source_summary_parts({ Compose = {} })
    assert_eq(kind, "Compose")
    assert_eq(detalhe, "docker-compose")
    assert_eq(motor, "Compose")
end

--- source_summary_parts de origem ausente
function test_origem_e_healthcheck__source_summary_parts_de_origem_ausente()
    local kind, detalhe, motor = SD.source_summary_parts(nil)
    assert_eq(kind, "—")
    assert_eq(detalhe, "—")
    assert_eq(motor, "—")
    assert_eq(SD.source_summary_parts({}), "—")
end

--- healthcheck desligado
function test_origem_e_healthcheck__healthcheck_desligado()
    assert_eq(SD.healthcheck_summary({ kind = "None" }), "disabled")
end

--- healthcheck HTTP mostra caminho e status esperado
function test_origem_e_healthcheck__healthcheck_http_mostra_caminho_e_status()
    local texto = SD.healthcheck_summary({
        kind = { Http = { path = "/health", expected_status = 200 } },
        interval_secs = 10,
        timeout_secs = 5,
        retries = 3,
    })
    assert_eq(
        texto,
        "HTTP /health → 200 · every 10s · timeout 5s · 3 retries"
    )
end

--- healthcheck TCP, Docker e tipo desconhecido
function test_origem_e_healthcheck__healthcheck_tcp_docker_e_tipo()
    local campos = { interval_secs = 1, timeout_secs = 2, retries = 4 }
    assert_eq(
        SD.healthcheck_summary({
            kind = "Tcp",
            interval_secs = 1,
            timeout_secs = 2,
            retries = 4,
        }),
        "TCP · every 1s · timeout 2s · 4 retries"
    )
    assert_eq(
        SD.healthcheck_summary({
            kind = "DockerNative",
            interval_secs = 1,
            timeout_secs = 2,
            retries = 4,
        }),
        "Docker · every 1s · timeout 2s · 4 retries"
    )
    assert_eq(
        SD.healthcheck_summary({
            kind = "Novo",
            interval_secs = 1,
            timeout_secs = 2,
            retries = 4,
        }),
        "Novo · every 1s · timeout 2s · 4 retries"
    )
    assert_eq(campos.retries, 4)
end

--- cor por estado e id encurtado
function test_containers__cor_por_estado_e_id_encurtado()
    local linhas = json.decode(SD.containers({
        { id = "abcdef0123456789", name = "api", state = "running" },
        { id = "b", name = "db", state = "restarting" },
        { id = "c", name = "x", state = "exited" },
        { id = "d" },
    }))
    assert_eq(#linhas, 4)
    assert_eq(linhas[1].id_short, "abcdef012345")
    assert_eq(linhas[1].id, "abcdef0123456789")
    assert_eq(linhas[1].state_color, "#3FB950")
    assert_eq(linhas[2].state_color, "#D29922")
    assert_eq(linhas[3].state_color, "#8B949E")
    assert_eq(linhas[4].name, "—")
    assert_eq(linhas[4].state, "—")
end

--- sem containers dá []
function test_containers__sem_containers_da()
    assert_eq(SD.containers(nil), "[]")
    assert_eq(SD.containers({}), "[]")
end

--- segredo aparece por referência, com cadeado, e se distingue do texto igual
function test_variaveis_de_ambiente__segredo_aparece_por_referencia_com()
    local linhas = json.decode(SD.env_json_with_comments({
        { key = "A", value = { Secret = "t" } },
        { key = "B", value = { Plain = "secret:t" } },
    }, {}))
    assert_eq(linhas[1].kind, "secret")
    assert_eq(linhas[1].value, "🔒 secret:t")
    assert_eq(linhas[2].kind, "plain")
    assert_eq(linhas[2].value, "secret:t")
end

--- a chave longa trunca só na exibição
function test_variaveis_de_ambiente__a_chave_longa_trunca_so_na_exibicao()
    local longa = string.rep("K", 40)
    local linha = json.decode(
        SD.env_json_with_comments(
            { { key = longa, value = { Plain = "1" } } },
            {}
        )
    )[1]
    assert_eq(linha.key, longa)
    assert_eq(utf8.len(linha.key_display), 31)
end

--- comentários voltam para junto da chave a que estavam ancorados
function test_variaveis_de_ambiente__comentarios_voltam_para_junto_da_chave_a()
    local linhas = json.decode(SD.env_json_with_comments({
        { key = "A", value = { Plain = "1" } },
        { key = "B", value = { Plain = "2" } },
    }, {
        { before_key = "B", text = "# sobre B" },
        { text = "# no fim" },
    }))
    assert_eq(#linhas, 4)
    assert_eq(linhas[1].key, "A")
    assert_eq(linhas[2].kind, "comment")
    assert_eq(linhas[2].key, "__c0")
    assert_eq(linhas[2].value, "# sobre B")
    assert_eq(linhas[3].key, "B")
    assert_eq(linhas[4].key, "__c1")
    assert_eq(linhas[4].value, "# no fim")
end

--- o .env sai com segredo entre <secret:> e comentários nos lugares
function test_variaveis_de_ambiente__o_env_sai_com_segredo_entre_secret_e()
    local texto = SD.env_dotenv_with_comments({
        { key = "A", value = { Plain = "1" } },
        { key = "B", value = { Secret = "S" } },
    }, { { before_key = "B", text = "# b" }, { text = "# fim" } })
    assert_eq(texto, "A=1\n# b\nB=<secret:S>\n# fim")
end

--- o .env faz ida e volta com o parser de .env
function test_variaveis_de_ambiente__o_env_faz_ida_e_volta_com_o_parser_de()
    local H = require("helpers")
    local vars = {
        { key = "A", value = { Plain = "1" } },
        { key = "B", value = { Secret = "S" } },
        { key = "URL", value = { Plain = "x=y" } },
    }
    local texto = SD.env_dotenv_with_comments(vars, {})
    local lidas = H.parse_dotenv(texto)
    assert_eq(#lidas, 3)
    for i, v in vars do
        assert_eq(lidas[i].key, v.key)
        assert_eq(lidas[i].value.Plain, v.value.Plain)
        assert_eq(lidas[i].value.Secret, v.value.Secret)
    end
end

--- vazio dá [] e string vazia
function test_variaveis_de_ambiente__vazio_da_e_string_vazia()
    assert_eq(SD.env_json_with_comments(nil, nil), "[]")
    assert_eq(SD.env_dotenv_with_comments(nil, nil), "")
end

--- secret_rows só carrega nomes
function test_variaveis_de_ambiente__secret_rows_so_carrega_nomes()
    local linhas = json.decode(SD.secret_rows({ "DB", string.rep("S", 40) }))
    assert_eq(linhas[1].name, "DB")
    assert_eq(utf8.len(linhas[2].name_display), 31)
    assert_eq(SD.secret_rows(nil), "[]")
end

--- stderr é vermelho, ANSI some e a hora é formatada
function test_logs__stderr_e_vermelho_ansi_some_e_a_hora_e_formatada()
    local linhas = json.decode(SD.logs_json({
        {
            stream = "Stdout",
            line = "\27[32mok\27[0m",
            timestamp = "2026-03-01T10:00:00Z",
        },
        {
            stream = "Stderr",
            line = "falhou",
            timestamp = "2026-03-01T10:00:01Z",
        },
    }))
    assert_eq(linhas[1].line, "ok")
    assert_eq(linhas[1].color, "#9DA7B3")
    assert_eq(linhas[2].color, "#F85149")
    assert_match(linhas[1].time, "^%d%d:%d%d:%d%d$")
end

--- só a cauda de 500 linhas é materializada
function test_logs__so_a_cauda_de_500_linhas_e_materializada()
    local entradas = {}
    for i = 1, 600 do
        table.insert(entradas, {
            stream = "Stdout",
            line = "l" .. i,
            timestamp = "2026-03-01T10:00:00Z",
        })
    end
    local linhas = json.decode(SD.logs_json(entradas))
    assert_eq(#linhas, 500)
    assert_eq(linhas[1].line, "l101")
    assert_eq(linhas[500].line, "l600")
end

--- linha absurda é cortada em 2000 caracteres
function test_logs__linha_absurda_e_cortada_em_2000_caracteres()
    local linhas = json.decode(SD.logs_json({
        {
            stream = "Stdout",
            line = string.rep("x", 5000),
            timestamp = "2026-03-01T10:00:00Z",
        },
    }))
    assert_eq(utf8.len(linhas[1].line), 2001)
end

--- build_logs_json é o mesmo formatador
function test_logs__build_logs_json_e_o_mesmo_formatador()
    assert_eq(SD.build_logs_json == SD.logs_json, true)
    assert_eq(SD.logs_json(nil), "[]")
end

--- join_log_lines junta tudo, sem o teto de linhas
function test_logs__join_log_lines_junta_tudo_sem_o_teto_de_linhas()
    local entradas = {}
    for i = 1, 600 do
        table.insert(
            entradas,
            { line = "l" .. i, timestamp = "2026-03-01T10:00:00Z" }
        )
    end
    local texto = SD.join_log_lines(entradas)
    local n = 0
    for _ in string.gmatch(texto, "[^\n]+") do
        n += 1
    end
    assert_eq(n, 600)
    assert_eq(SD.join_log_lines(nil), "")
end

--- linha de deployment: id, estado, duração e se pode apagar
function test_deployments_e_dominios__linha_de_deployment_id_estado_duracao_e()
    local linhas = json.decode(SD.deployments_detail({
        {
            id = "0123456789abcdefXYZ",
            image = "img:1",
            state = "Live",
            started_at = "2026-03-01T10:00:00Z",
            finished_at = "2026-03-01T10:01:05Z",
        },
        {
            id = "b",
            state = "BuildingImage",
            started_at = "2026-03-01T10:00:00Z",
        },
    }))
    assert_eq(linhas[1].id, "0123456789ab")
    assert_eq(linhas[1].id_full, "0123456789abcdefXYZ")
    assert_eq(linhas[1].state_label, "LIVE")
    assert_eq(linhas[1].state_kind, "ok")
    assert_eq(linhas[1].duration, "1m 5s")
    assert_eq(linhas[1].can_delete, "1")
    assert_eq(linhas[2].can_delete, "0")
end

--- todo estado terminal pode ser apagado, nenhum em andamento
function test_deployments_e_dominios__todo_estado_terminal_pode_ser_apagado()
    for estado, esperado in
        {
            Live = "1",
            Stopped = "1",
            Failed = "1",
            Pruning = "1",
            PreDeployCheck = "0",
            BuildingImage = "0",
        }
    do
        local linha = json.decode(SD.deployments_detail({
            {
                id = "x",
                state = estado,
                started_at = "2026-03-01T10:00:00Z",
                finished_at = "2026-03-01T10:00:01Z",
            },
        }))[1]
        assert_eq(linha.can_delete, esperado)
    end
end

--- a rota sem porta própria herda a do serviço
function test_deployments_e_dominios__a_rota_sem_porta_propria_herda_a_do()
    local linhas = json.decode(SD.domains_json({
        port = 80,
        domains = {
            { domain = "a.com", port = 8080, tls = true },
            { domain = "b.com" },
        },
    } :: any))
    assert_eq(linhas[1].port, "8080")
    assert_eq(linhas[1].tls, "true")
    assert_eq(linhas[1].tls_label, "TLS")
    assert_eq(linhas[2].port, "80")
    assert_eq(linhas[2].tls, "false")
    assert_eq(linhas[2].tls_label, "—")
end

--- sem domínio dá []
function test_deployments_e_dominios__sem_dominio_da()
    assert_eq(SD.domains_json({ port = 80 } :: any), "[]")
end

--- safe_name: minúsculas, não-alfanumérico vira _ colapsado e sem bordas
function test_nomes_e_hosts__safe_name_minusculas_nao_alfanumerico_vira()
    assert_eq(SD.safe_name("Meu App!"), "meu_app")
    assert_eq(SD.safe_name("--a--b--"), "a_b")
    assert_eq(SD.safe_name("API v2.0"), "api_v2_0")
    assert_eq(SD.safe_name("já"), "j")
    assert_eq(SD.safe_name(""), "")
    assert_eq(SD.safe_name("___"), "")
end

--- compose_host: ingress_service declarado vence
function test_nomes_e_hosts__compose_host_ingress_service_declarado_vence()
    assert_eq(SD.compose_host("services:\n  web:\n", "proxy"), "proxy")
end

--- compose_host: primeira chave de services:
function test_nomes_e_hosts__compose_host_primeira_chave_de_services()
    assert_eq(
        SD.compose_host(
            "version: '3'\nservices:\n  web:\n    image: x\n  db:\n    image: "
                .. "y\n",
            nil
        ),
        "web"
    )
    assert_eq(
        SD.compose_host("services:\n\n  # app\n  api-1.x:\n", ""),
        "api-1.x"
    )
end

--- compose_host: sem services: ou com o bloco vazio dá nil
function test_nomes_e_hosts__compose_host_sem_services_ou_com_o_bloco_vazio()
    assert_nil(SD.compose_host(nil, nil))
    assert_nil(SD.compose_host("version: '3'\n", nil))
    assert_nil(SD.compose_host("services:\nvolumes:\n  v:\n", nil))
end

--- esquema por tipo de banco e host rp_<nome>
function test_url_interna__esquema_por_tipo_de_banco_e_host_rp_nome()
    assert_eq(
        SD.internal_url("postgres", "app", 5432),
        "postgresql://rp_app:5432"
    )
    assert_eq(
        SD.internal_url("PostgreSQL", "app", 5432),
        "postgresql://rp_app:5432"
    )
    assert_eq(SD.internal_url("mariadb", "app", 3306), "mysql://rp_app:3306")
    assert_eq(SD.internal_url("redis", "app", 6379), "redis://rp_app:6379")
    assert_eq(SD.internal_url("mongo", "app", 27017), "mongodb://rp_app:27017")
    assert_eq(SD.internal_url("rabbitmq", "app", 5672), "amqp://rp_app:5672")
    assert_eq(SD.internal_url("nats", "app", 4222), "nats://rp_app:4222")
end

--- serviço comum é http, e kafka é host:porta puro
function test_url_interna__servico_comum_e_http_e_kafka_e_host_porta_puro()
    assert_eq(SD.internal_url(nil, "app", 80), "http://rp_app:80")
    assert_eq(SD.internal_url("kafka", "app", 9092), "rp_app:9092")
end

--- serviço compose usa o nome do YAML, não rp_<nome>
function test_url_interna__servico_compose_usa_o_nome_do_yaml_nao_rp_nome()
    assert_eq(SD.internal_url(nil, "app", 80, "web"), "http://web:80")
end

--- domínio HTTP tem prioridade e respeita o TLS
function test_url_externa__dominio_http_tem_prioridade_e_respeita_o_tls()
    assert_eq(
        SD.external_url(
            "app.com",
            true,
            5432,
            "postgres",
            "https://1.2.3.4:8443",
            {}
        ),
        "https://app.com"
    )
    assert_eq(
        SD.external_url("app.com//", false, nil, nil, nil, nil),
        "http://app.com"
    )
end

--- domínio só com espaços não conta
function test_url_externa__dominio_so_com_espacos_nao_conta()
    assert_eq(SD.external_url("   ", false, nil, nil, nil, nil), "—")
end

--- sem domínio nem porta publicada, não há URL
function test_url_externa__sem_dominio_nem_porta_publicada_nao_ha_url()
    assert_eq(
        SD.external_url(nil, false, nil, "postgres", "https://h", {}),
        "—"
    )
    assert_eq(
        SD.external_url("", false, "", "postgres", "https://h", {}),
        "—"
    )
end

--- postgres vira string JDBC com as credenciais das env vars
function test_url_externa__postgres_vira_string_jdbc_com_as_credenciais_das()
    assert_eq(
        SD.external_url(
            nil,
            false,
            5432,
            "postgres",
            "https://1.2.3.4:8443",
            postgres_vars()
        ),
        "jdbc:postgresql://1.2.3.4:5432/app?user=u&password=p"
    )
end

--- postgres sem credenciais devolve a base intacta
function test_url_externa__postgres_sem_credenciais_devolve_a_base_intacta()
    assert_eq(
        SD.external_url(nil, false, 5432, "postgresql", "https://1.2.3.4", {}),
        "jdbc:postgresql://1.2.3.4:5432"
    )
end

--- mysql e mariadb: usuário, senha e banco no userinfo
function test_url_externa__mysql_e_mariadb_usuario_senha_e_banco_no_userinfo()
    local vars = {
        { key = "MYSQL_DATABASE", value = { Plain = "d" } },
        { key = "MYSQL_USER", value = { Plain = "u" } },
        { key = "MYSQL_PASSWORD", value = { Plain = "p" } },
    }
    assert_eq(
        SD.external_url(nil, false, 3306, "mysql", "https://h:1", vars),
        "mysql://u:p@h:3306/d"
    )
    assert_eq(
        SD.external_url(nil, false, 3306, "mariadb", "https://h:1", vars),
        "mariadb://u:p@h:3306/d"
    )
end

--- redis só tem senha: userinfo começa em :
function test_url_externa__redis_so_tem_senha_userinfo_comeca_em()
    local vars = { { key = "REDIS_PASSWORD", value = { Plain = "pw" } } }
    assert_eq(
        SD.external_url(nil, false, 6379, "redis", "https://h", vars),
        "redis://:pw@h:6379"
    )
end

--- mongodb leva barra final e authSource=admin quando há usuário
function test_url_externa__mongodb_leva_barra_final_e_authsource_admin_quando()
    local vars = {
        { key = "MONGO_INITDB_ROOT_USERNAME", value = { Plain = "root" } },
        { key = "MONGO_INITDB_ROOT_PASSWORD", value = { Plain = "pw" } },
    }
    assert_eq(
        SD.external_url(nil, false, 27017, "mongodb", "https://h", vars),
        "mongodb://root:pw@h:27017/?authSource=admin"
    )
    assert_eq(
        SD.external_url(nil, false, 27017, "mongo", "https://h", {}),
        "mongodb://h:27017/"
    )
end

--- rabbitmq e nats
function test_url_externa__rabbitmq_e_nats()
    local vars = {
        { key = "RABBITMQ_DEFAULT_USER", value = { Plain = "guest" } },
        { key = "RABBITMQ_DEFAULT_PASS", value = { Plain = "guest" } },
    }
    assert_eq(
        SD.external_url(nil, false, 5672, "rabbitmq", "https://h", vars),
        "amqp://guest:guest@h:5672"
    )
    assert_eq(
        SD.external_url(nil, false, 4222, "nats", "https://h", {}),
        "nats://h:4222"
    )
end

--- sem esquema de banco (kafka, serviço comum) é host:porta puro
function test_url_externa__sem_esquema_de_banco_kafka_servico_comum_e_host()
    assert_eq(
        SD.external_url(nil, false, 9092, "kafka", "https://h", {}),
        "h:9092"
    )
    assert_eq(
        SD.external_url(nil, false, 8080, nil, "https://h", {}),
        "h:8080"
    )
end

--- senha com caracteres reservados é percent-encoded
function test_url_externa__senha_com_caracteres_reservados_e_percent_encoded()
    local vars = {
        { key = "MYSQL_USER", value = { Plain = "u@x" } },
        { key = "MYSQL_PASSWORD", value = { Plain = "p@ss:w/d?#" } },
    }
    assert_eq(
        SD.external_url(nil, false, 3306, "mysql", "https://h", vars),
        "mysql://u%40x:p%40ss%3Aw%2Fd%3F%23@h:3306"
    )
end

--- segredo (referência) não vira credencial
function test_url_externa__segredo_referencia_nao_vira_credencial()
    local vars = { { key = "REDIS_PASSWORD", value = { Secret = "S" } } }
    assert_eq(
        SD.external_url(nil, false, 6379, "redis", "https://h", vars),
        "redis://h:6379"
    )
end

--- o host sai do api_url, ou <host> quando ele falta
function test_url_externa__o_host_sai_do_api_url_ou_host_quando_ele_falta()
    assert_eq(
        SD.external_url(nil, false, 1, "kafka", "http://10.0.0.5:9797/x", {}),
        "10.0.0.5:1"
    )
    assert_eq(
        SD.external_url(nil, false, 1, "kafka", "srv.com", {}),
        "srv.com:1"
    )
    assert_eq(SD.external_url(nil, false, 1, "kafka", nil, {}), "<host>:1")
    assert_eq(SD.external_url(nil, false, 1, "kafka", "   ", {}), "<host>:1")
end
