--!nonstrict
local Util = require("format/util")

describe("format/util · busca", function()
    test("termo vazio ou nil sempre casa (a busca é filtro, não requisito)", function()
        expect(Util.matches("", { "qualquer" })):toBe(true)
        expect(Util.matches(nil, {})):toBe(true)
    end)

    test("casa por trecho, sem diferenciar caixa do campo", function()
        expect(Util.matches("api", { "Minha-API-gateway" })):toBe(true)
        expect(Util.matches("worker", { "api", "db" })):toBe(false)
    end)

    test("o termo é literal, não padrão Lua", function()
        expect(Util.matches("a.b", { "a.b" })):toBe(true)
        expect(Util.matches("a.b", { "axb" })):toBe(false)
        expect(Util.matches("%", { "100%" })):toBe(true)
    end)

    test("campos que não são texto são ignorados", function()
        expect(Util.matches("8080", { 8080, nil, true })):toBe(false)
        expect(Util.matches("8080", { 8080, "porta 8080" })):toBe(true)
    end)
end)

describe("format/util · texto", function()
    test("ellipsis não mexe no que cabe", function()
        expect(Util.ellipsis("curto", 10)):toBe("curto")
        expect(Util.ellipsis("exato", 5)):toBe("exato")
        expect(Util.ellipsis(nil, 5)):toBe("")
    end)

    test("ellipsis corta em caracteres, não em bytes, e anexa …", function()
        expect(Util.ellipsis("abcdefgh", 3)):toBe("abc…")
        expect(Util.ellipsis("ação-longa", 4)):toBe("ação…")
    end)

    test("short_reason fica com a primeira linha não vazia, aparada", function()
        expect(Util.short_reason("\n\n   falhou o build  \nlinha dois")):toBe("falhou o build")
    end)

    test("short_reason trunca no limite pedido e tem padrão de 140", function()
        expect(Util.short_reason("abcdefghij", 4)):toBe("abcd…")
        local longa = string.rep("x", 200)
        expect(utf8.len(Util.short_reason(longa))):toBe(141)
    end)

    test("short_reason devolve vazio sem motivo", function()
        expect(Util.short_reason(nil)):toBe("")
        expect(Util.short_reason(42)):toBe("")
        expect(Util.short_reason(" \n \r\n")):toBe("")
    end)

    test("strip_ansi tira cor, cursor, OSC, CR e NUL", function()
        expect(Util.strip_ansi("\27[2m\27[32mok\27[0m")):toBe("ok")
        expect(Util.strip_ansi("a\27[2Kb\27[1;5Hc")):toBe("abc")
        expect(Util.strip_ansi("\27]0;título\7texto")):toBe("texto")
        expect(Util.strip_ansi("linha\r\0")):toBe("linha")
        expect(Util.strip_ansi(nil)):toBe("")
    end)

    test("strip_ansi não mexe em texto limpo", function()
        expect(Util.strip_ansi("sem [colchetes] nem ESC")):toBe("sem [colchetes] nem ESC")
    end)
end)

describe("format/util · arrays", function()
    test("encode_array força [] quando vazio (tabela vazia viraria {})", function()
        expect(Util.encode_array({})):toBe("[]")
        expect(json.encode({})).never:toBe("[]")
    end)

    test("encode_array codifica a lista quando há itens", function()
        local back = json.decode(Util.encode_array({ { a = 1 }, { a = 2 } }))
        expect(#back):toBe(2)
        expect(back[2].a):toBe(2)
    end)
end)

describe("format/util · estados", function()
    test("status_label_color e status_kind concordam em todos os estados", function()
        local casos = {
            { "Running", "Running", "ok" },
            { "Deploying", "Deploying", "info" },
            { "Queued", "Na fila", "muted" },
            { "Degraded", "Degraded", "warn" },
            { "Stopping", "Stopping", "muted" },
            { "Stopped", "Stopped", "muted" },
        }
        for _, caso in casos do
            local label = Util.status_label_color(caso[1])
            expect(label):toBe(caso[2])
            expect(Util.status_kind(caso[1])):toBe(caso[3])
        end
    end)

    test("status com erro (tabela) ou desconhecido cai em Error/bad", function()
        local label, cor = Util.status_label_color({ Error = "boom" })
        expect(label):toBe("Error")
        expect(cor):toBe("#F85149")
        expect(Util.status_kind({ Error = "boom" })):toBe("bad")
        expect(Util.status_kind("Qualquer")):toBe("bad")
        expect(Util.status_kind(nil)):toBe("bad")
    end)

    test("estado de deploy: rótulo, cor e kind", function()
        local label, cor = Util.state_label_color("Live")
        expect(label):toBe("LIVE")
        expect(cor):toBe("#3FB950")
        expect(Util.state_label_color("Failed")):toBe("FAILED")
        expect(Util.state_label_color("PreDeployCheck")):toBe("PRÉ-DEPLOY CHECK")
        expect(Util.state_label_color("BuildingImage")):toBe("BUILDING")
        expect(Util.state_label_color(nil)):toBe("BUILDING")
        expect(Util.state_kind("Live")):toBe("ok")
        expect(Util.state_kind("Failed")):toBe("bad")
        expect(Util.state_kind("Stopped")):toBe("muted")
        expect(Util.state_kind("BuildingImage")):toBe("info")
    end)

    test("in_use_kind", function()
        expect(Util.in_use_kind(true)):toBe("ok")
        expect(Util.in_use_kind(false)):toBe("muted")
    end)

    test("container_state normaliza a caixa e classifica", function()
        local rotulo, kind = Util.container_state("RUNNING")
        expect(rotulo):toBe("running")
        expect(kind):toBe("ok")
        expect(select(2, Util.container_state("restarting"))):toBe("info")
        expect(select(2, Util.container_state("paused"))):toBe("warn")
        expect(select(2, Util.container_state("created"))):toBe("info")
        expect(select(2, Util.container_state("dead"))):toBe("bad")
    end)

    test("container_state: parado ou desconhecido é muted; vazio vira exited", function()
        local rotulo, kind = Util.container_state("removing")
        expect(rotulo):toBe("removing")
        expect(kind):toBe("muted")
        expect(Util.container_state(nil)):toBe("exited")
        expect(Util.container_state("")):toBe("exited")
    end)

    test("container_stopped: só ativo (running/restarting/paused) não é removível", function()
        expect(Util.container_stopped("running")):toBe(false)
        expect(Util.container_stopped("Restarting")):toBe(false)
        expect(Util.container_stopped("paused")):toBe(false)
        expect(Util.container_stopped("exited")):toBe(true)
        expect(Util.container_stopped(nil)):toBe(true)
    end)
end)

describe("format/util · domínio do serviço", function()
    test("source_summary de cada origem", function()
        expect(Util.source_summary({ Registry = { image = "nginx:1" } })):toBe("nginx:1")
        expect(Util.source_summary({ Git = { url = "https://x/r.git", branch = "main" } })):toBe("https://x/r.git @ main")
        expect(Util.source_summary({ Archive = { original_filename = "app.zip" } })):toBe("app.zip")
        expect(Util.source_summary({ Archive = { archive_id = "a1" } })):toBe("a1")
        expect(Util.source_summary({ Archive = {} })):toBe("zip enviado")
        expect(Util.source_summary({ Compose = {} })):toBe("docker-compose")
    end)

    test("source_summary de origem ausente ou desconhecida é —", function()
        expect(Util.source_summary(nil)):toBe("—")
        expect(Util.source_summary("Git")):toBe("—")
        expect(Util.source_summary({})):toBe("—")
        expect(Util.source_summary({ Registry = {} })):toBe("—")
    end)

    test("domain_routes usa a lista nova e converte tls para booleano", function()
        local rotas = Util.domain_routes({
            domains = { { domain = "a.com", port = 80, tls = true }, { domain = "b.com" } },
        } :: any)
        expect(#rotas):toBe(2)
        expect(rotas[1].tls):toBe(true)
        expect(rotas[2].tls):toBe(false)
        expect(rotas[1].port):toBe(80)
    end)

    test("domain_routes cai no domain/tls_enabled legado", function()
        local rotas = Util.domain_routes({ domain = "velho.com", tls_enabled = true } :: any)
        expect(#rotas):toBe(1)
        expect(rotas[1].domain):toBe("velho.com")
        expect(rotas[1].tls):toBe(true)
        expect(rotas[1].port):toBeNil()
    end)

    test("a lista nova vence o legado, e vazio não gera rota", function()
        local rotas = Util.domain_routes({ domains = { { domain = "novo.com" } }, domain = "velho.com" } :: any)
        expect(#rotas):toBe(1)
        expect(rotas[1].domain):toBe("novo.com")
        expect(#Util.domain_routes({ domain = "" } :: any)):toBe(0)
        expect(#Util.domain_routes({} :: any)):toBe(0)
    end)

    test("pre_deploy_checks: a fila nova vence o id legado", function()
        expect(Util.pre_deploy_checks({ pre_deploy_job_ids = { "a", "b" }, pre_deploy_job_id = "z" })):toEqual({ "a", "b" })
        expect(Util.pre_deploy_checks({ pre_deploy_job_ids = {}, pre_deploy_job_id = "z" })):toEqual({ "z" })
        expect(Util.pre_deploy_checks({ pre_deploy_job_id = "" })):toEqual({})
        expect(Util.pre_deploy_checks({})):toEqual({})
    end)

    test("service_pair_list normaliza o snapshot", function()
        local pares = Util.service_pair_list({
            { service = { name = "api" }, project_name = "loja" },
            { service = { name = "db" } },
        })
        expect(#pares):toBe(2)
        expect(pares[1].proj):toBe("loja")
        expect(pares[2].proj):toBe("")
        expect(#Util.service_pair_list(nil)):toBe(0)
    end)
end)

describe("format/util · orçamento de colunas", function()
    test("segue os breakpoints 560/900 da largura da janela", function()
        local largura = viewport().width
        local b = Util.column_budgets()
        if largura < 560 then
            expect(b.svc):toBe(12)
        elseif largura < 900 then
            expect(b.svc):toBe(17)
        else
            expect(b.svc):toBe(28)
        end
        for _, campo in { "svc", "proj", "state", "img" } do
            expect(type((b :: any)[campo])):toBe("number")
        end
    end)
end)
