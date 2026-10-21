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

describe("format/dashboard · deployments", function()
    test("filtra por serviço ou projeto e formata o estado", function()
        local entradas = {
            { service_name = "api", project_name = "loja", deployment = { state = "Live", started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:00:30Z" } },
            { service_name = "web", project_name = "blog", deployment = { state = "Failed", started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:00:05Z" } },
        }
        local todas = json.decode(Dashboard.deployments(entradas, ""))
        expect(#todas):toBe(2)
        expect(todas[1].state_label):toBe("LIVE")
        expect(todas[1].state_kind):toBe("ok")
        expect(todas[1].duration):toBe("30s")
        expect(todas[1].start_iso):toBe("2026-03-01T10:00:00Z")
        expect(todas[2].state_kind):toBe("bad")

        local so_blog = json.decode(Dashboard.deployments(entradas, "blog"))
        expect(#so_blog):toBe(1)
        expect(so_blog[1].service):toBe("web")
        expect(Dashboard.deployments(entradas, "zzz")):toBe("[]")
        expect(Dashboard.deployments(nil, nil)):toBe("[]")
    end)
end)

describe("format/dashboard · cards de serviço", function()
    test("status, porta e métricas", function()
        local cartoes = json.decode(Dashboard.services(
            { par("api", "loja") },
            { ["id-api"] = { cpu_percent = 12.34, mem_used_bytes = 5 * 1024 * 1024 } },
            ""
        ))
        expect(#cartoes):toBe(1)
        expect(cartoes[1].name):toBe("api")
        expect(cartoes[1].project):toBe("loja")
        expect(cartoes[1].port):toBe("8080")
        expect(cartoes[1].status_label):toBe("Running")
        expect(cartoes[1].cpu):toBe("12.3%")
        expect(cartoes[1].mem):toBe("5 MB")
        expect(cartoes[1].filler):toBe("0")
    end)

    test("sem métricas o card mostra —", function()
        local c = json.decode(Dashboard.services({ par("api", "loja") }, nil, ""))[1]
        expect(c.cpu):toBe("—")
        expect(c.mem):toBe("—")
        expect(c.container_name):toBe("—")
        expect(c.container_extra):toBe("")
    end)

    test("o container primário é o live; senão o primeiro em execução; +N quando há mais", function()
        local com_live = par("a", "p", {
            live_container_id = "idb",
            containers = {
                { id = "ida", name = "c-a", state = "exited" },
                { id = "idb", name = "c-b", state = "exited" },
                { id = "idc", name = "c-c", state = "running" },
            },
        })
        local c = json.decode(Dashboard.services({ com_live }, nil, ""))[1]
        expect(c.container_name):toBe("c-b")
        expect(c.container_extra):toBe("+2")

        local sem_live = par("a", "p", {
            containers = {
                { id = "ida", name = "c-a", state = "exited" },
                { id = "idc", name = "c-c", state = "running" },
            },
        })
        c = json.decode(Dashboard.services({ sem_live }, nil, ""))[1]
        expect(c.container_name):toBe("c-c")
        expect(c.container_id):toBe("idc")
    end)

    test("o selo de aquecimento só existe quando há warm", function()
        local quente = par("a", "p")
        quente.warm = { warm = true, reason = "build ok" }
        local linhas = json.decode(Dashboard.services({ quente, par("b", "p") }, nil, ""))
        expect(linhas[1].has_warm):toBe("true")
        expect(linhas[1].warm_label):toBe("quente")
        expect(linhas[1].warm_reason):toBe("build ok")
        expect(linhas[2].has_warm):toBe("false")
        expect(linhas[2].warm_label):toBe("")
    end)

    test("a busca casa serviço ou projeto", function()
        local pares = { par("api", "loja"), par("worker", "blog") }
        expect(#json.decode(Dashboard.services(pares, nil, "blog"))):toBe(1)
        expect(#json.decode(Dashboard.services(pares, nil, "api"))):toBe(1)
        expect(#json.decode(Dashboard.services(pares, nil, ""))):toBe(2)
        expect(Dashboard.services(pares, nil, "zzz")):toBe("[]")
    end)
end)

describe("format/dashboard · grade", function()
    local function linhas_para(n)
        local pares = {}
        for i = 1, n do
            table.insert(pares, par("s" .. i, "p"))
        end
        return json.decode(Dashboard.service_rows(pares, nil, ""))
    end

    test("1 a 3 colunas, todas as fileiras com a mesma largura", function()
        com_menu(false)
        local linhas = linhas_para(7)
        local colunas = #linhas[1].cards
        expect(colunas >= 1 and colunas <= 3):toBe(true)
        for _, linha in linhas do
            expect(#linha.cards):toBe(colunas)
        end
    end)

    test("a última fileira é completada com cards vazios (a grade não tem grid)", function()
        com_menu(false)
        local linhas = linhas_para(7)
        local colunas = #linhas[1].cards
        expect(#linhas):toBe(math.ceil(7 / colunas))
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
        expect(reais):toBe(7)
        expect(vazios):toBe(#linhas * colunas - 7)
    end)

    test("o card vazio carrega os campos dos dois contratos, como texto", function()
        com_menu(false)
        local linhas = linhas_para(1)
        local vazio
        for _, card in linhas[1].cards do
            if card.filler == "1" then
                vazio = card
            end
        end
        if vazio then
            for _, campo in { "id", "name", "project", "port", "status_label", "cpu", "mem", "description", "service_count", "can_delete" } do
                expect(vazio[campo]):toBe("")
            end
        end
    end)

    test("a gaveta aberta nunca dá mais colunas que a fechada", function()
        com_menu(false)
        local fechada = #linhas_para(9)[1].cards
        com_menu(true)
        local aberta = #linhas_para(9)[1].cards
        expect(aberta <= fechada):toBe(true)
        expect(aberta >= 1):toBe(true)
    end)

    test("sem serviços não há fileiras", function()
        com_menu(false)
        expect(Dashboard.service_rows({}, nil, "")):toBe("[]")
    end)

    test("project_rows segue a mesma regra de grade", function()
        com_menu(false)
        local projetos = {}
        for i = 1, 4 do
            table.insert(projetos, { id = "p" .. i, name = "proj" .. i })
        end
        local linhas = json.decode(Dashboard.project_rows(projetos, {}, ""))
        local colunas = #linhas[1].cards
        for _, linha in linhas do
            expect(#linha.cards):toBe(colunas)
        end
        expect(#linhas):toBe(math.ceil(4 / colunas))
    end)
end)

describe("format/dashboard · projetos", function()
    test("conta serviços e os que estão rodando, e só deixa apagar projeto vazio", function()
        local pares = {
            par("a", "x"), -- project_id "p-x"
            par("b", "x", { status = "Stopped" }),
        }
        local projetos = {
            { id = "p-x", name = "x", description = "meu projeto" },
            { id = "p-y", name = "y" },
        }
        local cartoes = json.decode(Dashboard.projects(projetos, pares, ""))
        expect(cartoes[1].service_count):toBe("2")
        expect(cartoes[1].running_count):toBe("1")
        expect(cartoes[1].can_delete):toBe("0")
        expect(cartoes[1].description):toBe("meu projeto")
        expect(cartoes[2].service_count):toBe("0")
        expect(cartoes[2].can_delete):toBe("1")
        expect(cartoes[2].description):toBe("")
    end)

    test("a busca olha nome e descrição", function()
        local projetos = { { id = "1", name = "loja", description = "vendas" }, { id = "2", name = "blog" } }
        expect(#json.decode(Dashboard.projects(projetos, {}, "vend"))):toBe(1)
        expect(#json.decode(Dashboard.projects(projetos, {}, "blog"))):toBe(1)
        expect(Dashboard.projects(nil, {}, "")):toBe("[]")
    end)
end)

describe("format/dashboard · docker", function()
    test("docker_rows ordena por nome e resume a imagem", function()
        local linhas = json.decode(Dashboard.docker_rows({
            par("zeta", "p", { live_container_id = "0123456789abcdefff" }),
            par("alfa", "p"),
        }, ""))
        expect(linhas[1].name):toBe("alfa")
        expect(linhas[2].name):toBe("zeta")
        expect(linhas[2].container):toBe("0123456789ab")
        expect(linhas[1].container):toBe("—")
        expect(linhas[1].status_kind):toBe("ok")
    end)

    local imagens = {
        { id = "sha256:aaaaaaaaaaaaaaaa", tags = { "web:1" }, size_bytes = 2048, containers = 1, project = "loja", service = "web", created = "2026-03-01T10:00:00Z" },
        { id = "sha256:bbbbbbbbbbbbbbbb", tags = {}, size_bytes = 1024, containers = 0 },
        { id = "cccc", tags = { "api:2" }, containers = 0 },
    }

    test("imagens: ordenadas por tag, sem sha256: e com <none> para as sem tag", function()
        local linhas = json.decode(Dashboard.docker_images(imagens, "", false))
        expect(#linhas):toBe(3)
        -- ordem por tags unidas: "" < "api:2" < "web:1"
        expect(linhas[1].tags):toBe("<none>")
        expect(linhas[2].tags):toBe("api:2")
        expect(linhas[3].tags):toBe("web:1")
        expect(linhas[3].id_full):toBe("aaaaaaaaaaaaaaaa")
        expect(linhas[3].id):toBe("aaaaaaaaaaaa")
    end)

    test("imagens: em uso, dono e tamanhos crus para ordenar", function()
        local linhas = json.decode(Dashboard.docker_images(imagens, "", false))
        local web = linhas[3]
        expect(web.in_use_label):toBe("EM USO")
        expect(web.in_use_kind):toBe("ok")
        expect(web.owner):toBe(Util.ellipsis("loja / web", Util.column_budgets().proj))
        expect(web.size):toBe("2 KB")
        expect(web.size_bytes):toBe(2048)
        expect(web.created_iso):toBe("2026-03-01T10:00:00Z")
        expect(linhas[1].in_use_label):toBe("SEM USO")
        expect(linhas[1].project):toBe("—")
        expect(linhas[2].size_bytes):toBe(0)
    end)

    test("imagens: 'somente em uso' esconde as órfãs, e a busca olha tags e dono", function()
        local em_uso = json.decode(Dashboard.docker_images(imagens, "", true))
        expect(#em_uso):toBe(1)
        expect(em_uso[1].tags):toBe("web:1")
        expect(#json.decode(Dashboard.docker_images(imagens, "loja", false))):toBe(1)
        expect(#json.decode(Dashboard.docker_images(imagens, "api", false))):toBe(1)
    end)

    test("volumes: filtro de uso, tamanho desconhecido e dono", function()
        local volumes = {
            { name = "dados", driver = "local", mountpoint = "/v/dados", in_use = true, size_bytes = 5 * 1024 * 1024 },
            { name = "antigo", driver = "local", mountpoint = "/v/antigo", in_use = false },
            { name = "neg", driver = "nfs", mountpoint = "/v/n", in_use = false, size_bytes = -1 },
        }
        local todos = json.decode(Dashboard.docker_volumes(volumes, "", false))
        expect(#todos):toBe(3)
        expect(todos[1].name):toBe("antigo")
        expect(todos[1].size):toBe("—")
        expect(todos[1].size_bytes):toBe(-1)
        expect(todos[2].name):toBe("dados")
        expect(todos[2].size):toBe("5 MB")
        expect(todos[2].in_use_label):toBe("EM USO")
        expect(todos[3].size):toBe("—")

        local em_uso = json.decode(Dashboard.docker_volumes(volumes, "", true))
        expect(#em_uso):toBe(1)
        expect(em_uso[1].name_full):toBe("dados")
        expect(#json.decode(Dashboard.docker_volumes(volumes, "nfs", false))):toBe(1)
    end)

    test("redes: ordem, contagem de containers e filtro", function()
        local redes = {
            { name = "zz", id = "n2", driver = "bridge", scope = "local", in_use = false },
            { name = "aa", id = "n1", driver = "bridge", scope = "local", in_use = true, container_count = 3, project = "loja" },
        }
        local linhas = json.decode(Dashboard.docker_networks(redes, "", false))
        expect(linhas[1].name):toBe("aa")
        expect(linhas[1].containers):toBe("3")
        expect(linhas[1].project):toBe("loja")
        expect(linhas[2].containers):toBe("0")
        expect(linhas[2].project):toBe("—")
        expect(#json.decode(Dashboard.docker_networks(redes, "", true))):toBe(1)
    end)

    test("containers: dono, removível só parado, imagem sem sha256:", function()
        local linhas = json.decode(Dashboard.docker_containers({
            { id = "0123456789abcdef", name = "rp_api", image = "sha256:abcdef", state = "running", project = "loja", service = "api" },
            { id = "b", name = "rp_db", image = "pg:16", state = "exited", managed = true },
            { id = "c", name = "outro", image = "x", state = "created" },
        }, ""))
        expect(#linhas):toBe(3)
        -- ordenados por nome: outro, rp_api, rp_db
        expect(linhas[1].name):toBe("outro")
        expect(linhas[1].owner):toBe("—")
        expect(linhas[2].id):toBe("0123456789ab")
        expect(linhas[2].image):toBe("abcdef")
        expect(linhas[2].can_remove):toBe("0")
        expect(linhas[2].state_kind):toBe("ok")
        expect(linhas[3].owner):toBe(Util.ellipsis("rustploy", Util.column_budgets().state))
        expect(linhas[3].can_remove):toBe("1")
    end)

    test("containers: a busca olha nome, imagem, estado e dono", function()
        local lista = {
            { name = "a", image = "pg:16", state = "running" },
            { name = "b", image = "x", state = "exited", project = "loja", service = "web" },
        }
        expect(#json.decode(Dashboard.docker_containers(lista, "pg"))):toBe(1)
        expect(#json.decode(Dashboard.docker_containers(lista, "exited"))):toBe(1)
        expect(#json.decode(Dashboard.docker_containers(lista, "loja"))):toBe(1)
        expect(Dashboard.docker_containers(nil, "")):toBe("[]")
    end)
end)

describe("format/dashboard · ingress, portas e monitoramento", function()
    test("ingress: uma linha por rota, com a porta do upstream", function()
        local a = par("api", "loja")
        a.svc.spec.domains = { { domain = "a.com", port = 3000, tls = true }, { domain = "b.com" } }
        local texto, total = Dashboard.ingress({ a })
        local linhas = json.decode(texto)
        expect(total):toBe(2)
        expect(linhas[1].url):toBe("https://a.com")
        expect(linhas[1].upstream):toBe(":3000")
        expect(linhas[1].tls):toBe("TLS")
        expect(linhas[2].url):toBe("http://b.com")
        expect(linhas[2].upstream):toBe(":8080")
        expect(linhas[2].tls):toBe("—")
    end)

    test("ingress ignora domínio em branco e entende o campo legado", function()
        local vazio = par("a", "p")
        vazio.svc.spec.domains = { { domain = "   " } }
        local legado = par("b", "p")
        legado.svc.spec.domain = "velho.com"
        local _, total = Dashboard.ingress({ vazio, legado, par("c", "p") })
        expect(total):toBe(1)
        local texto, zero = Dashboard.ingress({})
        expect(texto):toBe("[]")
        expect(zero):toBe(0)
    end)

    test("portas de host: só quem tem host_port, em ordem numérica", function()
        local a, b = par("a", "p"), par("b", "p")
        a.svc.spec.host_port = 9000
        b.svc.spec.host_port = 80
        local texto, total = Dashboard.host_ports({ a, b, par("c", "p") })
        local linhas = json.decode(texto)
        expect(total):toBe(2)
        expect(linhas[1].host_port):toBe("80")
        expect(linhas[2].host_port):toBe("9000")
        expect(linhas[1].container_port):toBe("8080")
        expect(linhas[1].host_port_n):toBe(80)
    end)

    test("monitoramento: só serviços com métricas vivas, com valores crus", function()
        local linhas = json.decode(Dashboard.monitoring(
            { par("api", "loja"), par("web", "loja") },
            { ["id-api"] = { cpu_percent = 50, mem_used_bytes = 2048, net_rx_bytes = 1024, net_tx_bytes = 0 } }
        ))
        expect(#linhas):toBe(1)
        expect(linhas[1].name):toBe("api")
        expect(linhas[1].cpu):toBe("50.0%")
        expect(linhas[1].mem):toBe("2 KB")
        expect(linhas[1].rx):toBe("1 KB")
        expect(linhas[1].tx):toBe("—")
        expect(linhas[1].cpu_n):toBe(50)
        expect(linhas[1].mem_n):toBe(2048)
        expect(Dashboard.monitoring({ par("a", "p") }, nil)):toBe("[]")
    end)
end)

describe("format/dashboard · motor de deploy", function()
    local function info(estado, extras)
        local base = { state = estado, service_name = "api", project_name = "loja", elapsed_secs = 75, current_state_secs = 5, service_id = "s1", deployment_id = "d1", states = {} }
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

    test("são oito passos, do 'Fila' ao 'Live'", function()
        local _, passos = status_dos_passos(info("Pending"))
        expect(#passos):toBe(8)
        expect(passos[1].text):toBe("● Fila")
        expect(passos[8].text):toBe("○ Live")
    end)

    test("em andamento: os anteriores feitos, o atual marcado, os seguintes pendentes", function()
        expect(status_dos_passos(info("BuildingImage"))):toEqual({ "done", "done", "done", "current", "pending", "pending", "pending", "pending" })
        expect(status_dos_passos(info("Pending"))):toEqual({ "current", "pending", "pending", "pending", "pending", "pending", "pending", "pending" })
        expect(status_dos_passos(info("Draining"))):toEqual({ "done", "done", "done", "done", "done", "done", "current", "pending" })
    end)

    test("os quatro estados de 'Obter' caem no mesmo passo", function()
        for _, estado in { "PullingImage", "CloningRepo", "BuildingImage", "ComposingUp" } do
            expect(status_dos_passos(info(estado))[4]):toBe("current")
        end
    end)

    test("Live, Stopped e Pruning terminam com tudo feito", function()
        for _, estado in { "Live", "Stopped", "Pruning" } do
            local lista = status_dos_passos(info(estado))
            for _, status in lista do
                expect(status):toBe("done")
            end
        end
    end)

    test("falha marca o passo em que estava, achado no histórico", function()
        local falhou = info("Failed", {
            states = {
                { from = "Pending", to = "BuildingImage" },
                { from = "BuildingImage", to = "HealthcheckPolling" },
                { from = "HealthcheckPolling", to = "Failed" },
            },
        })
        expect(status_dos_passos(falhou)):toEqual({ "done", "done", "done", "done", "done", "failed", "pending", "pending" })
    end)

    test("falha sem histórico não marca nenhum passo como atual", function()
        local lista = status_dos_passos(info("Failed"))
        for _, status in lista do
            expect(status).never:toBe("current")
        end
    end)

    test("estado desconhecido deixa tudo pendente", function()
        local lista = status_dos_passos(info("Qualquer"))
        for _, status in lista do
            expect(status):toBe("pending")
        end
    end)

    test("detalhe: duração entre transições, tipo e motivo", function()
        local linhas = json.decode(Dashboard.deploy_engine_detail(info("Failed", {
            states = {
                { to = "Pending", at = "2026-03-01T10:00:00Z" },
                { to = "BuildingImage", at = "2026-03-01T10:00:10Z" },
                { to = "Failed", at = "2026-03-01T10:01:10Z", message = "\nerro no build\nlinha 2" },
            },
        })))
        expect(#linhas):toBe(3)
        expect(linhas[1].label):toBe("Pending")
        expect(linhas[1].dur):toBe("10s")
        expect(linhas[1].kind):toBe("ok")
        expect(linhas[2].dur):toBe("1m 0s")
        expect(linhas[3].kind):toBe("bad")
        expect(linhas[3].dur):toBe("—")
        expect(linhas[3].msg):toBe("erro no build")
    end)

    test("detalhe: a transição corrente mostra o tempo no estado e fica 'info'", function()
        local linhas = json.decode(Dashboard.deploy_engine_detail(info("BuildingImage", {
            current_state_secs = 42,
            states = {
                { to = "Pending", at = "2026-03-01T10:00:00Z" },
                { to = "BuildingImage", at = "2026-03-01T10:00:10Z" },
            },
        })))
        expect(linhas[2].dur):toBe("42s")
        expect(linhas[2].kind):toBe("info")
        expect(linhas[1].kind):toBe("ok")
    end)

    test("detalhe: timestamp inválido não dá duração negativa", function()
        local linhas = json.decode(Dashboard.deploy_engine_detail(info("Live", {
            states = { { to = "Pending", at = "lixo" }, { to = "Live", at = "lixo" } },
        })))
        expect(linhas[1].dur):toBe("0s")
    end)

    test("executando agora traz estado, tempos e os passos", function()
        local linhas = json.decode(Dashboard.deploy_engine_active({ info("BuildingImage") }))
        expect(#linhas):toBe(1)
        expect(linhas[1].service):toBe("api")
        expect(linhas[1].state_label):toBe("BUILDING")
        expect(linhas[1].total):toBe("1m 15s")
        expect(linhas[1].phase):toBe("5s")
        expect(linhas[1].deployment_id):toBe("d1")
        expect(#linhas[1].steps):toBe(8)
        expect(Dashboard.deploy_engine_active(nil)):toBe("[]")
    end)

    test("a fila numera de 1 e guarda o id para cancelar", function()
        local linhas = json.decode(Dashboard.deploy_engine_queued({ info("Pending", { deployment_id = "q1" }), info("Pending", { deployment_id = "q2" }) }))
        expect(linhas[1].pos):toBe("1")
        expect(linhas[2].pos):toBe("2")
        expect(linhas[2].deployment_id):toBe("q2")
        expect(Dashboard.deploy_engine_queued({})):toBe("[]")
    end)

    test("o histórico escolhe o ícone pelo resultado", function()
        local linhas = json.decode(Dashboard.deploy_engine_recent({
            info("Live", { started_at = "2026-03-01T10:00:00Z" }),
            info("Failed"),
            info("Stopped"),
        }))
        expect(linhas[1].icon):toBe("✓")
        expect(linhas[2].icon):toBe("✕")
        expect(linhas[3].icon):toBe("○")
        expect(linhas[1].duration):toBe("1m 15s")
        expect(linhas[1].start):toMatch("^%d%d:%d%d:%d%d$")
        expect(linhas[1].start_iso):toBe("2026-03-01T10:00:00Z")
        expect(linhas[2].start_iso):toBe("")
        expect(linhas[1].elapsed_secs):toBe(75)
    end)
end)
