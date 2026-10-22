--!nonstrict
local Dashboard = require("format/dashboard")
local Util = require("format/util")

local env = _G :: any

-- grid_cols lê o global `ctx` (a gaveta lateral come largura da grade).
local function com_menu(aberto)
    env.ctx = { menu = aberto and "true" or "false" }
end

local function par(nome, projeto, extras)
    local svc = {
        id = "id-" .. nome,
        status = "Running",
        spec = { name = nome, port = 8080, project_id = "p-" .. projeto },
        containers = {},
    }
    for k, v in extras or {} do
        svc[k] = v
    end
    return { svc = svc, proj = projeto }
end

--- filtra por serviço ou projeto e formata o estado
function test_deployments__filtra_por_servico_ou_projeto_e_formata_o_estado()
    local entradas = {
        {
            service_name = "api",
            project_name = "loja",
            deployment = {
                state = "Live",
                started_at = "2026-03-01T10:00:00Z",
                finished_at = "2026-03-01T10:00:30Z",
            },
        },
        {
            service_name = "web",
            project_name = "blog",
            deployment = {
                state = "Failed",
                started_at = "2026-03-01T10:00:00Z",
                finished_at = "2026-03-01T10:00:05Z",
            },
        },
    }
    local todas = json.decode(Dashboard.deployments(entradas, ""))
    assert_eq(#todas, 2)
    assert_eq(todas[1].state_label, "LIVE")
    assert_eq(todas[1].state_kind, "ok")
    assert_eq(todas[1].duration, "30s")
    assert_eq(todas[1].start_iso, "2026-03-01T10:00:00Z")
    assert_eq(todas[2].state_kind, "bad")

    local so_blog = json.decode(Dashboard.deployments(entradas, "blog"))
    assert_eq(#so_blog, 1)
    assert_eq(so_blog[1].service, "web")
    assert_eq(Dashboard.deployments(entradas, "zzz"), "[]")
    assert_eq(Dashboard.deployments(nil, nil), "[]")
end

--- status, porta e métricas
function test_cards_de_servico__status_porta_e_metricas()
    local cartoes = json.decode(Dashboard.services({ par("api", "loja") }, {
        ["id-api"] = {
            cpu_percent = 12.34,
            mem_used_bytes = 5 * 1024 * 1024,
        },
    }, ""))
    assert_eq(#cartoes, 1)
    assert_eq(cartoes[1].name, "api")
    assert_eq(cartoes[1].project, "loja")
    assert_eq(cartoes[1].port, "8080")
    assert_eq(cartoes[1].status_label, "Running")
    assert_eq(cartoes[1].cpu, "12.3%")
    assert_eq(cartoes[1].mem, "5 MB")
    assert_eq(cartoes[1].filler, "0")
end

--- sem métricas o card mostra —
function test_cards_de_servico__sem_metricas_o_card_mostra()
    local c =
        json.decode(Dashboard.services({ par("api", "loja") }, nil, ""))[1]
    assert_eq(c.cpu, "—")
    assert_eq(c.mem, "—")
    assert_eq(c.container_name, "—")
    assert_eq(c.container_extra, "")
end

--- o container primário é o live; senão o primeiro em execução; +N quando há
--- mais
function test_cards_de_servico__o_container_primario_e_o_live_senao_o()
    local com_live = par("a", "p", {
        live_container_id = "idb",
        containers = {
            { id = "ida", name = "c-a", state = "exited" },
            { id = "idb", name = "c-b", state = "exited" },
            { id = "idc", name = "c-c", state = "running" },
        },
    })
    local c = json.decode(Dashboard.services({ com_live }, nil, ""))[1]
    assert_eq(c.container_name, "c-b")
    assert_eq(c.container_extra, "+2")

    local sem_live = par("a", "p", {
        containers = {
            { id = "ida", name = "c-a", state = "exited" },
            { id = "idc", name = "c-c", state = "running" },
        },
    })
    c = json.decode(Dashboard.services({ sem_live }, nil, ""))[1]
    assert_eq(c.container_name, "c-c")
    assert_eq(c.container_id, "idc")
end

--- o selo de aquecimento só existe quando há warm
function test_cards_de_servico__o_selo_de_aquecimento_so_existe_quando_ha()
    local quente = par("a", "p")
    quente.warm = { warm = true, reason = "build ok" }
    local linhas =
        json.decode(Dashboard.services({ quente, par("b", "p") }, nil, ""))
    assert_eq(linhas[1].has_warm, "true")
    assert_eq(linhas[1].warm_label, "quente")
    assert_eq(linhas[1].warm_reason, "build ok")
    assert_eq(linhas[2].has_warm, "false")
    assert_eq(linhas[2].warm_label, "")
end

--- a busca casa serviço ou projeto
function test_cards_de_servico__a_busca_casa_servico_ou_projeto()
    local pares = { par("api", "loja"), par("worker", "blog") }
    assert_eq(#json.decode(Dashboard.services(pares, nil, "blog")), 1)
    assert_eq(#json.decode(Dashboard.services(pares, nil, "api")), 1)
    assert_eq(#json.decode(Dashboard.services(pares, nil, "")), 2)
    assert_eq(Dashboard.services(pares, nil, "zzz"), "[]")
end

local function linhas_para(n)
    local pares = {}
    for i = 1, n do
        table.insert(pares, par("s" .. i, "p"))
    end
    return json.decode(Dashboard.service_rows(pares, nil, ""))
end

--- 1 a 3 colunas, todas as fileiras com a mesma largura
function test_grade__1_a_3_colunas_todas_as_fileiras_com_a_mesma_largura()
    com_menu(false)
    local linhas = linhas_para(7)
    local colunas = #linhas[1].cards
    assert_eq(colunas >= 1 and colunas <= 3, true)
    for _, linha in linhas do
        assert_eq(#linha.cards, colunas)
    end
end

--- a última fileira é completada com cards vazios (a grade não tem grid)
function test_grade__a_ultima_fileira_e_completada_com_cards_vazios_a_grade()
    com_menu(false)
    local linhas = linhas_para(7)
    local colunas = #linhas[1].cards
    assert_eq(#linhas, math.ceil(7 / colunas))
    local reais, vazios = 0, 0
    for _, linha in linhas do
        for _, card in linha.cards do
            if card.filler == "1" then
                vazios += 1
            else
                reais += 1
            end
        end
    end
    assert_eq(reais, 7)
    assert_eq(vazios, #linhas * colunas - 7)
end

--- o card vazio carrega os campos dos dois contratos, como texto
function test_grade__o_card_vazio_carrega_os_campos_dos_dois_contratos_como()
    com_menu(false)
    local linhas = linhas_para(1)
    local vazio
    for _, card in linhas[1].cards do
        if card.filler == "1" then
            vazio = card
        end
    end
    if vazio then
        for _, campo in
            {
                "id",
                "name",
                "project",
                "port",
                "status_label",
                "cpu",
                "mem",
                "description",
                "service_count",
                "can_delete",
            }
        do
            assert_eq(vazio[campo], "")
        end
    end
end

--- a gaveta aberta nunca dá mais colunas que a fechada
function test_grade__a_gaveta_aberta_nunca_da_mais_colunas_que_a_fechada()
    com_menu(false)
    local fechada = #linhas_para(9)[1].cards
    com_menu(true)
    local aberta = #linhas_para(9)[1].cards
    assert_eq(aberta <= fechada, true)
    assert_eq(aberta >= 1, true)
end

--- sem serviços não há fileiras
function test_grade__sem_servicos_nao_ha_fileiras()
    com_menu(false)
    assert_eq(Dashboard.service_rows({}, nil, ""), "[]")
end

--- project_rows segue a mesma regra de grade
function test_grade__project_rows_segue_a_mesma_regra_de_grade()
    com_menu(false)
    local projetos = {}
    for i = 1, 4 do
        table.insert(projetos, { id = "p" .. i, name = "proj" .. i })
    end
    local linhas = json.decode(Dashboard.project_rows(projetos, {}, ""))
    local colunas = #linhas[1].cards
    for _, linha in linhas do
        assert_eq(#linha.cards, colunas)
    end
    assert_eq(#linhas, math.ceil(4 / colunas))
end

--- conta serviços e os que estão rodando, e só deixa apagar projeto vazio
function test_projetos__conta_servicos_e_os_que_estao_rodando_e_so_deixa()
    local pares = {
        par("a", "x"), -- project_id "p-x"
        par("b", "x", { status = "Stopped" }),
    }
    local projetos = {
        { id = "p-x", name = "x", description = "meu projeto" },
        { id = "p-y", name = "y" },
    }
    local cartoes = json.decode(Dashboard.projects(projetos, pares, ""))
    assert_eq(cartoes[1].service_count, "2")
    assert_eq(cartoes[1].running_count, "1")
    assert_eq(cartoes[1].can_delete, "0")
    assert_eq(cartoes[1].description, "meu projeto")
    assert_eq(cartoes[2].service_count, "0")
    assert_eq(cartoes[2].can_delete, "1")
    assert_eq(cartoes[2].description, "")
end

--- a busca olha nome e descrição
function test_projetos__a_busca_olha_nome_e_descricao()
    local projetos = {
        { id = "1", name = "loja", description = "vendas" },
        { id = "2", name = "blog" },
    }
    assert_eq(#json.decode(Dashboard.projects(projetos, {}, "vend")), 1)
    assert_eq(#json.decode(Dashboard.projects(projetos, {}, "blog")), 1)
    assert_eq(Dashboard.projects(nil, {}, ""), "[]")
end

--- docker_rows ordena por nome e resume a imagem
function test_docker__docker_rows_ordena_por_nome_e_resume_a_imagem()
    local linhas = json.decode(Dashboard.docker_rows({
        par("zeta", "p", { live_container_id = "0123456789abcdefff" }),
        par("alfa", "p"),
    }, ""))
    assert_eq(linhas[1].name, "alfa")
    assert_eq(linhas[2].name, "zeta")
    assert_eq(linhas[2].container, "0123456789ab")
    assert_eq(linhas[1].container, "—")
    assert_eq(linhas[1].status_kind, "ok")
end

local imagens = {
    {
        id = "sha256:aaaaaaaaaaaaaaaa",
        tags = { "web:1" },
        size_bytes = 2048,
        containers = 1,
        project = "loja",
        service = "web",
        created = "2026-03-01T10:00:00Z",
    },
    {
        id = "sha256:bbbbbbbbbbbbbbbb",
        tags = {},
        size_bytes = 1024,
        containers = 0,
    },
    { id = "cccc", tags = { "api:2" }, containers = 0 },
}

--- imagens: ordenadas por tag, sem sha256: e com <none> para as sem tag
function test_docker__imagens_ordenadas_por_tag_sem_sha256_e_com_none_para_as()
    local linhas = json.decode(Dashboard.docker_images(imagens, "", false))
    assert_eq(#linhas, 3)
    -- ordem por tags unidas: "" < "api:2" < "web:1"
    assert_eq(linhas[1].tags, "<none>")
    assert_eq(linhas[2].tags, "api:2")
    assert_eq(linhas[3].tags, "web:1")
    assert_eq(linhas[3].id_full, "aaaaaaaaaaaaaaaa")
    assert_eq(linhas[3].id, "aaaaaaaaaaaa")
end

--- imagens: em uso, dono e tamanhos crus para ordenar
function test_docker__imagens_em_uso_dono_e_tamanhos_crus_para_ordenar()
    local linhas = json.decode(Dashboard.docker_images(imagens, "", false))
    local web = linhas[3]
    assert_eq(web.in_use_label, "EM USO")
    assert_eq(web.in_use_kind, "ok")
    assert_eq(
        web.owner,
        Util.ellipsis("loja / web", Util.column_budgets().proj)
    )
    assert_eq(web.size, "2 KB")
    assert_eq(web.size_bytes, 2048)
    assert_eq(web.created_iso, "2026-03-01T10:00:00Z")
    assert_eq(linhas[1].in_use_label, "SEM USO")
    assert_eq(linhas[1].project, "—")
    assert_eq(linhas[2].size_bytes, 0)
end

--- imagens: 'somente em uso' esconde as órfãs, e a busca olha tags e dono
function test_docker__imagens_somente_em_uso_esconde_as_orfas_e_a_busca_olha()
    local em_uso = json.decode(Dashboard.docker_images(imagens, "", true))
    assert_eq(#em_uso, 1)
    assert_eq(em_uso[1].tags, "web:1")
    assert_eq(#json.decode(Dashboard.docker_images(imagens, "loja", false)), 1)
    assert_eq(#json.decode(Dashboard.docker_images(imagens, "api", false)), 1)
end

--- volumes: filtro de uso, tamanho desconhecido e dono
function test_docker__volumes_filtro_de_uso_tamanho_desconhecido_e_dono()
    local volumes = {
        {
            name = "dados",
            driver = "local",
            mountpoint = "/v/dados",
            in_use = true,
            size_bytes = 5 * 1024 * 1024,
        },
        {
            name = "antigo",
            driver = "local",
            mountpoint = "/v/antigo",
            in_use = false,
        },
        {
            name = "neg",
            driver = "nfs",
            mountpoint = "/v/n",
            in_use = false,
            size_bytes = -1,
        },
    }
    local todos = json.decode(Dashboard.docker_volumes(volumes, "", false))
    assert_eq(#todos, 3)
    assert_eq(todos[1].name, "antigo")
    assert_eq(todos[1].size, "—")
    assert_eq(todos[1].size_bytes, -1)
    assert_eq(todos[2].name, "dados")
    assert_eq(todos[2].size, "5 MB")
    assert_eq(todos[2].in_use_label, "EM USO")
    assert_eq(todos[3].size, "—")

    local em_uso = json.decode(Dashboard.docker_volumes(volumes, "", true))
    assert_eq(#em_uso, 1)
    assert_eq(em_uso[1].name_full, "dados")
    assert_eq(#json.decode(Dashboard.docker_volumes(volumes, "nfs", false)), 1)
end

--- redes: ordem, contagem de containers e filtro
function test_docker__redes_ordem_contagem_de_containers_e_filtro()
    local redes = {
        {
            name = "zz",
            id = "n2",
            driver = "bridge",
            scope = "local",
            in_use = false,
        },
        {
            name = "aa",
            id = "n1",
            driver = "bridge",
            scope = "local",
            in_use = true,
            container_count = 3,
            project = "loja",
        },
    }
    local linhas = json.decode(Dashboard.docker_networks(redes, "", false))
    assert_eq(linhas[1].name, "aa")
    assert_eq(linhas[1].containers, "3")
    assert_eq(linhas[1].project, "loja")
    assert_eq(linhas[2].containers, "0")
    assert_eq(linhas[2].project, "—")
    assert_eq(#json.decode(Dashboard.docker_networks(redes, "", true)), 1)
end

--- containers: dono, removível só parado, imagem sem sha256:
function test_docker__containers_dono_removivel_so_parado_imagem_sem_sha256()
    local linhas = json.decode(Dashboard.docker_containers({
        {
            id = "0123456789abcdef",
            name = "rp_api",
            image = "sha256:abcdef",
            state = "running",
            project = "loja",
            service = "api",
        },
        {
            id = "b",
            name = "rp_db",
            image = "pg:16",
            state = "exited",
            managed = true,
        },
        { id = "c", name = "outro", image = "x", state = "created" },
    }, ""))
    assert_eq(#linhas, 3)
    -- ordenados por nome: outro, rp_api, rp_db
    assert_eq(linhas[1].name, "outro")
    assert_eq(linhas[1].owner, "—")
    assert_eq(linhas[2].id, "0123456789ab")
    assert_eq(linhas[2].image, "abcdef")
    assert_eq(linhas[2].can_remove, "0")
    assert_eq(linhas[2].state_kind, "ok")
    assert_eq(
        linhas[3].owner,
        Util.ellipsis("rustploy", Util.column_budgets().state)
    )
    assert_eq(linhas[3].can_remove, "1")
end

--- containers: a busca olha nome, imagem, estado e dono
function test_docker__containers_a_busca_olha_nome_imagem_estado_e_dono()
    local lista = {
        { name = "a", image = "pg:16", state = "running" },
        {
            name = "b",
            image = "x",
            state = "exited",
            project = "loja",
            service = "web",
        },
    }
    assert_eq(#json.decode(Dashboard.docker_containers(lista, "pg")), 1)
    assert_eq(#json.decode(Dashboard.docker_containers(lista, "exited")), 1)
    assert_eq(#json.decode(Dashboard.docker_containers(lista, "loja")), 1)
    assert_eq(Dashboard.docker_containers(nil, ""), "[]")
end

--- ingress: uma linha por rota, com a porta do upstream
function test_ingress_portas_e_monitoramento__ingress_uma_linha_por_rota_com()
    local a = par("api", "loja")
    a.svc.spec.domains =
        { { domain = "a.com", port = 3000, tls = true }, { domain = "b.com" } }
    local texto, total = Dashboard.ingress({ a })
    local linhas = json.decode(texto)
    assert_eq(total, 2)
    assert_eq(linhas[1].url, "https://a.com")
    assert_eq(linhas[1].upstream, ":3000")
    assert_eq(linhas[1].tls, "TLS")
    assert_eq(linhas[2].url, "http://b.com")
    assert_eq(linhas[2].upstream, ":8080")
    assert_eq(linhas[2].tls, "—")
end

--- ingress ignora domínio em branco e entende o campo legado
function test_ingress_portas_e_monitoramento__ingress_ignora_dominio_em()
    local vazio = par("a", "p")
    vazio.svc.spec.domains = { { domain = "   " } }
    local legado = par("b", "p")
    legado.svc.spec.domain = "velho.com"
    local _, total = Dashboard.ingress({ vazio, legado, par("c", "p") })
    assert_eq(total, 1)
    local texto, zero = Dashboard.ingress({})
    assert_eq(texto, "[]")
    assert_eq(zero, 0)
end

--- portas de host: só quem tem host_port, em ordem numérica
function test_ingress_portas_e_monitoramento__portas_de_host_so_quem_tem_host()
    local a, b = par("a", "p"), par("b", "p")
    a.svc.spec.host_port = 9000
    b.svc.spec.host_port = 80
    local texto, total = Dashboard.host_ports({ a, b, par("c", "p") })
    local linhas = json.decode(texto)
    assert_eq(total, 2)
    assert_eq(linhas[1].host_port, "80")
    assert_eq(linhas[2].host_port, "9000")
    assert_eq(linhas[1].container_port, "8080")
    assert_eq(linhas[1].host_port_n, 80)
end

--- monitoramento: só serviços com métricas vivas, com valores crus
function test_ingress_portas_e_monitoramento__monitoramento_so_servicos_com()
    local linhas = json.decode(
        Dashboard.monitoring({ par("api", "loja"), par("web", "loja") }, {
            ["id-api"] = {
                cpu_percent = 50,
                mem_used_bytes = 2048,
                net_rx_bytes = 1024,
                net_tx_bytes = 0,
            },
        })
    )
    assert_eq(#linhas, 1)
    assert_eq(linhas[1].name, "api")
    assert_eq(linhas[1].cpu, "50.0%")
    assert_eq(linhas[1].mem, "2 KB")
    assert_eq(linhas[1].rx, "1 KB")
    assert_eq(linhas[1].tx, "—")
    assert_eq(linhas[1].cpu_n, 50)
    assert_eq(linhas[1].mem_n, 2048)
    assert_eq(Dashboard.monitoring({ par("a", "p") }, nil), "[]")
end

local function info(estado, extras)
    local base = {
        state = estado,
        service_name = "api",
        project_name = "loja",
        elapsed_secs = 75,
        current_state_secs = 5,
        service_id = "s1",
        deployment_id = "d1",
        states = {},
    }
    for k, v in extras or {} do
        base[k] = v
    end
    return base
end

local function status_dos_passos(i)
    local passos = json.decode(Dashboard.deploy_engine_detail_steps(i))
    local lista = {}
    for _, passo in passos do
        table.insert(lista, passo.status)
    end
    return lista, passos
end

--- são oito passos, do 'Fila' ao 'Live'
function test_motor_de_deploy__sao_oito_passos_do_fila_ao_live()
    local _, passos = status_dos_passos(info("Pending"))
    assert_eq(#passos, 8)
    assert_eq(passos[1].text, "● Fila")
    assert_eq(passos[8].text, "○ Live")
end

--- em andamento: os anteriores feitos, o atual marcado, os seguintes pendentes
function test_motor_de_deploy__em_andamento_os_anteriores_feitos_o_atual()
    assert_eq(status_dos_passos(info("BuildingImage")), {
        "done",
        "done",
        "done",
        "current",
        "pending",
        "pending",
        "pending",
        "pending",
    })
    assert_eq(status_dos_passos(info("Pending")), {
        "current",
        "pending",
        "pending",
        "pending",
        "pending",
        "pending",
        "pending",
        "pending",
    })
    assert_eq(status_dos_passos(info("Draining")), {
        "done",
        "done",
        "done",
        "done",
        "done",
        "done",
        "current",
        "pending",
    })
end

--- os quatro estados de 'Obter' caem no mesmo passo
function test_motor_de_deploy__os_quatro_estados_de_obter_caem_no_mesmo_passo()
    for _, estado in
        { "PullingImage", "CloningRepo", "BuildingImage", "ComposingUp" }
    do
        assert_eq(status_dos_passos(info(estado))[4], "current")
    end
end

--- Live, Stopped e Pruning terminam com tudo feito
function test_motor_de_deploy__live_stopped_e_pruning_terminam_com_tudo_feito()
    for _, estado in { "Live", "Stopped", "Pruning" } do
        local lista = status_dos_passos(info(estado))
        for _, status in lista do
            assert_eq(status, "done")
        end
    end
end

--- falha marca o passo em que estava, achado no histórico
function test_motor_de_deploy__falha_marca_o_passo_em_que_estava_achado_no()
    local falhou = info("Failed", {
        states = {
            { from = "Pending", to = "BuildingImage" },
            { from = "BuildingImage", to = "HealthcheckPolling" },
            { from = "HealthcheckPolling", to = "Failed" },
        },
    })
    assert_eq(status_dos_passos(falhou), {
        "done",
        "done",
        "done",
        "done",
        "done",
        "failed",
        "pending",
        "pending",
    })
end

--- falha sem histórico não marca nenhum passo como atual
function test_motor_de_deploy__falha_sem_historico_nao_marca_nenhum_passo()
    local lista = status_dos_passos(info("Failed"))
    for _, status in lista do
        assert_ne(status, "current")
    end
end

--- estado desconhecido deixa tudo pendente
function test_motor_de_deploy__estado_desconhecido_deixa_tudo_pendente()
    local lista = status_dos_passos(info("Qualquer"))
    for _, status in lista do
        assert_eq(status, "pending")
    end
end

--- detalhe: duração entre transições, tipo e motivo
function test_motor_de_deploy__detalhe_duracao_entre_transicoes_tipo_e_motivo()
    local linhas = json.decode(Dashboard.deploy_engine_detail(info("Failed", {
        states = {
            { to = "Pending", at = "2026-03-01T10:00:00Z" },
            { to = "BuildingImage", at = "2026-03-01T10:00:10Z" },
            {
                to = "Failed",
                at = "2026-03-01T10:01:10Z",
                message = "\nerro no build\nlinha 2",
            },
        },
    })))
    assert_eq(#linhas, 3)
    assert_eq(linhas[1].label, "Pending")
    assert_eq(linhas[1].dur, "10s")
    assert_eq(linhas[1].kind, "ok")
    assert_eq(linhas[2].dur, "1m 0s")
    assert_eq(linhas[3].kind, "bad")
    assert_eq(linhas[3].dur, "—")
    assert_eq(linhas[3].msg, "erro no build")
end

--- detalhe: a transição corrente mostra o tempo no estado e fica 'info'
function test_motor_de_deploy__detalhe_a_transicao_corrente_mostra_o_tempo_no()
    local linhas =
        json.decode(Dashboard.deploy_engine_detail(info("BuildingImage", {
            current_state_secs = 42,
            states = {
                { to = "Pending", at = "2026-03-01T10:00:00Z" },
                { to = "BuildingImage", at = "2026-03-01T10:00:10Z" },
            },
        })))
    assert_eq(linhas[2].dur, "42s")
    assert_eq(linhas[2].kind, "info")
    assert_eq(linhas[1].kind, "ok")
end

--- detalhe: timestamp inválido não dá duração negativa
function test_motor_de_deploy__detalhe_timestamp_invalido_nao_da_duracao()
    local linhas = json.decode(Dashboard.deploy_engine_detail(info("Live", {
        states = {
            { to = "Pending", at = "lixo" },
            { to = "Live", at = "lixo" },
        },
    })))
    assert_eq(linhas[1].dur, "0s")
end

--- executando agora traz estado, tempos e os passos
function test_motor_de_deploy__executando_agora_traz_estado_tempos_e_os()
    local linhas =
        json.decode(Dashboard.deploy_engine_active({ info("BuildingImage") }))
    assert_eq(#linhas, 1)
    assert_eq(linhas[1].service, "api")
    assert_eq(linhas[1].state_label, "BUILDING")
    assert_eq(linhas[1].total, "1m 15s")
    assert_eq(linhas[1].phase, "5s")
    assert_eq(linhas[1].deployment_id, "d1")
    assert_eq(#linhas[1].steps, 8)
    assert_eq(Dashboard.deploy_engine_active(nil), "[]")
end

--- a fila numera de 1 e guarda o id para cancelar
function test_motor_de_deploy__a_fila_numera_de_1_e_guarda_o_id_para_cancelar()
    local linhas = json.decode(Dashboard.deploy_engine_queued({
        info("Pending", { deployment_id = "q1" }),
        info("Pending", { deployment_id = "q2" }),
    }))
    assert_eq(linhas[1].pos, "1")
    assert_eq(linhas[2].pos, "2")
    assert_eq(linhas[2].deployment_id, "q2")
    assert_eq(Dashboard.deploy_engine_queued({}), "[]")
end

--- o histórico escolhe o ícone pelo resultado
function test_motor_de_deploy__o_historico_escolhe_o_icone_pelo_resultado()
    local linhas = json.decode(Dashboard.deploy_engine_recent({
        info("Live", { started_at = "2026-03-01T10:00:00Z" }),
        info("Failed"),
        info("Stopped"),
    }))
    assert_eq(linhas[1].icon, "✓")
    assert_eq(linhas[2].icon, "✕")
    assert_eq(linhas[3].icon, "○")
    assert_eq(linhas[1].duration, "1m 15s")
    assert_match(linhas[1].start, "^%d%d:%d%d:%d%d$")
    assert_eq(linhas[1].start_iso, "2026-03-01T10:00:00Z")
    assert_eq(linhas[2].start_iso, "")
    assert_eq(linhas[1].elapsed_secs, 75)
end
