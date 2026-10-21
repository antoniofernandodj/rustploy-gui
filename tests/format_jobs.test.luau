--!nonstrict
local Jobs = require("format/jobs")
local Util = require("format/util")

describe("format/jobs · recorrência", function()
    test("sem recorrência é manual", function()
        expect(Jobs.recurrence_label(nil)):toBe("manual")
    end)

    test("intervalo, diária e semanal", function()
        expect(Jobs.recurrence_label({ IntervalHours = 6 })):toBe("a cada 6h")
        expect(Jobs.recurrence_label({ Daily = { hour = 3, minute = 5 } })):toBe("diariamente às 03:05")
        expect(Jobs.recurrence_label({ Weekly = { weekday = 0, hour = 9, minute = 30 } })):toBe("semanalmente seg às 09:30")
        expect(Jobs.recurrence_label({ Weekly = { weekday = 6, hour = 23, minute = 0 } })):toBe("semanalmente dom às 23:00")
    end)

    test("o dia da semana dá a volta (módulo 7)", function()
        expect(Jobs.recurrence_label({ Weekly = { weekday = 7, hour = 0, minute = 0 } })):toContain("seg")
        expect(Jobs.recurrence_label({ Weekly = { weekday = 9, hour = 0, minute = 0 } })):toContain("qua")
    end)

    test("forma desconhecida vira traço", function()
        expect(Jobs.recurrence_label({ Mensal = {} })):toBe("—")
    end)
end)

describe("format/jobs · estado", function()
    test("última execução: nunca, rodando, ok, falhou", function()
        local label, kind = Jobs.run_status(nil)
        expect(label):toBe("nunca rodou")
        expect(kind):toBe("muted")
        label, kind = Jobs.run_status({})
        expect(label):toBe("rodando…")
        expect(kind):toBe("warn")
        label, kind = Jobs.run_status({ success = true })
        expect(label):toBe("ok")
        expect(kind):toBe("ok")
        label, kind = Jobs.run_status({ success = false })
        expect(label):toBe("falhou")
        expect(kind):toBe("bad")
    end)

    test("aquecimento: aquecendo vence quente, e nil conta como frio", function()
        expect(Jobs.warm_status({ warming = true, warm = true })):toBe("aquecendo…")
        expect(Jobs.warm_status({ warm = true })):toBe("quente")
        expect(Jobs.warm_status({})):toBe("frio")
        expect(Jobs.warm_status(nil)):toBe("frio")
        expect(select(2, Jobs.warm_status({ warm = true }))):toBe("ok")
        expect(select(2, Jobs.warm_status({ warming = true }))):toBe("warn")
    end)

    test("serviço sem build não tem selo", function()
        local label, kind = Jobs.service_warm_status(nil)
        expect(label):toBe("")
        expect(kind):toBe("muted")
        expect(Jobs.service_warm_status({ warm = true })):toBe("quente")
    end)
end)

describe("format/jobs · tela Schedules", function()
    local function resumo(sobrescrita)
        local base = {
            job = { id = "j1", name = "migrate", recurrence = { IntervalHours = 2 }, enabled = true },
            project_name = "loja",
            trigger_service_name = "api",
            last_run = { id = "r1", success = true },
        }
        for k, v in sobrescrita or {} do
            base[k] = v
        end
        return base
    end

    test("uma linha por job, com o total", function()
        local json_texto, total = Jobs.summaries({ resumo(), resumo({ job = { id = "j2", name = "x", enabled = false } }) }, nil)
        expect(total):toBe(2)
        local linhas = json.decode(json_texto)
        expect(#linhas):toBe(2)
        expect(linhas[1].id):toBe("j1")
        expect(linhas[1].recurrence):toBe("a cada 2h")
        expect(linhas[1].enabled_label):toBe("Pausar")
        expect(linhas[2].enabled_label):toBe("Ativar")
        expect(linhas[1].last_run_label):toBe("ok")
        expect(linhas[1].last_run_id):toBe("r1")
    end)

    test("o dono mostra projeto / serviço gatilho, ou só o projeto quando autônomo", function()
        local autonomo = resumo()
        autonomo.trigger_service_name = nil
        local linhas = json.decode((Jobs.summaries({ resumo(), autonomo }, nil)))
        -- O orçamento de caracteres depende da largura da janela (ver
        -- Util.column_budgets), então o esperado passa pelo mesmo ellipsis.
        local orcamento = Util.column_budgets().proj
        expect(linhas[1].owner):toBe(Util.ellipsis("loja / api", orcamento))
        expect(linhas[2].owner):toBe(Util.ellipsis("loja", orcamento))
        expect(linhas[1].trigger_service):toBe("api")
    end)

    test("o nome comprido é truncado na exibição e guardado inteiro", function()
        local longo = string.rep("n", 80)
        local linha = json.decode((Jobs.summaries({ resumo({ job = { id = "j", name = longo } }) }, nil)))[1]
        expect(linha.name_full):toBe(longo)
        expect(utf8.len(linha.name) < 80):toBe(true)
    end)

    test("running reflete o servidor OU o clique em voo", function()
        local rodando = resumo({ last_run = {} })
        local parado = resumo()
        local linhas = json.decode((Jobs.summaries({ rodando, parado }, nil)))
        expect(linhas[1].running):toBe(true)
        expect(linhas[2].running):toBe(false)

        linhas = json.decode((Jobs.summaries({ parado }, { j1 = true })))
        expect(linhas[1].running):toBe(true)
        linhas = json.decode((Jobs.summaries({ parado }, { j1 = false })))
        expect(linhas[1].running):toBe(false)
    end)

    test("próxima execução e aquecimento", function()
        local linha = json.decode((Jobs.summaries({
            resumo({
                job = { id = "j", name = "n", next_run_at = "2026-03-01T10:00:00Z" },
                warm = { warm = true, warmed_at = "2026-03-01T09:00:00Z", reason = "build ok" },
            }),
        }, nil)))[1]
        expect(linha.next_run_at):toMatch("^%d%d/%d%d %d%d:%d%d$")
        expect(linha.is_warm):toBe(true)
        expect(linha.is_warming):toBe(false)
        expect(linha.warm_label):toBe("quente")
        expect(linha.warm_reason):toBe("build ok")
        expect(linha.warmed_at_label):toMatch("^%d%d/%d%d")
    end)

    test("sem next_run_at nem aquecimento, os campos têm padrão seguro", function()
        local linha = json.decode((Jobs.summaries({ resumo() }, nil)))[1]
        expect(linha.next_run_at):toBe("—")
        expect(linha.is_warm):toBe(false)
        expect(linha.warm_label):toBe("frio")
        expect(linha.warm_reason):toBe("")
        expect(linha.warmed_at_label):toBe("")
    end)

    test("job que nunca rodou", function()
        local nunca = resumo()
        nunca.last_run = nil
        local linha = json.decode((Jobs.summaries({ nunca }, nil)))[1]
        expect(linha.last_run_label):toBe("nunca rodou")
        expect(linha.last_run_id):toBe("")
        expect(linha.running):toBe(false)
    end)

    test("sem jobs dá [] e zero", function()
        local texto, total = Jobs.summaries(nil, nil)
        expect(texto):toBe("[]")
        expect(total):toBe(0)
    end)
end)

describe("format/jobs · fila de pré-deploy", function()
    local jobs = { { id = "a", name = "migrar" }, { id = "b", name = "seed" }, { id = "c", name = "limpar" } }

    test("a fila respeita a ordem configurada e resolve o nome", function()
        local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_ids = { "c", "a" } }, jobs))
        expect(#fila):toBe(2)
        expect(fila[1].name):toBe("limpar")
        expect(fila[1].index):toBe("1")
        expect(fila[2].name):toBe("migrar")
        expect(fila[2].index):toBe("2")
    end)

    test("um job apagado por fora aparece como removido, para dar para tirá-lo da fila", function()
        local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_ids = { "zzz" } }, jobs))
        expect(fila[1].id):toBe("zzz")
        expect(fila[1].name):toBe("(job removido: zzz)")
    end)

    test("o id legado vale quando a fila nova está vazia", function()
        local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_id = "b" }, jobs))
        expect(fila[1].name):toBe("seed")
    end)

    test("os disponíveis são os que ainda não estão na fila", function()
        local livres = json.decode(Jobs.pre_deploy_available({ pre_deploy_job_ids = { "a" } }, jobs))
        expect(#livres):toBe(2)
        expect(livres[1].id):toBe("b")
        expect(livres[2].id):toBe("c")
    end)

    test("fila e disponíveis juntos cobrem todos os jobs, sem repetir", function()
        local spec = { pre_deploy_job_ids = { "b" } }
        local na_fila = json.decode(Jobs.pre_deploy_queue(spec, jobs))
        local livres = json.decode(Jobs.pre_deploy_available(spec, jobs))
        expect(#na_fila + #livres):toBe(#jobs)
    end)

    test("sem jobs dá []", function()
        expect(Jobs.pre_deploy_queue({}, nil)):toBe("[]")
        expect(Jobs.pre_deploy_available({}, nil)):toBe("[]")
    end)
end)

describe("format/jobs · histórico", function()
    test("cada execução com seu estado, código de saída e horários", function()
        local linhas = json.decode(Jobs.runs({
            { id = "r1", started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:00:09Z", exit_code = 0, success = true },
            { id = "r2", started_at = "2026-03-01T10:00:00Z", exit_code = 1, success = false },
            { id = "r3", started_at = "2026-03-01T10:00:00Z" },
        }))
        expect(linhas[1].status_label):toBe("ok")
        expect(linhas[1].exit_code):toBe("0")
        expect(linhas[1].finished_at):toMatch("^%d%d/%d%d %d%d:%d%d:%d%d$")
        expect(linhas[2].status_label):toBe("falhou")
        expect(linhas[2].status_kind):toBe("bad")
        expect(linhas[2].finished_at):toBe("—")
        expect(linhas[3].status_label):toBe("rodando…")
        expect(linhas[3].exit_code):toBe("—")
    end)

    test("sem execuções dá []", function()
        expect(Jobs.runs(nil)):toBe("[]")
    end)
end)
