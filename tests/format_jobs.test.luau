--!nonstrict
local Jobs = require("format/jobs")
local Util = require("format/util")

--- sem recorrência é manual
function test_format_jobs_recorrencia__sem_recorrencia_e_manual()
    assert_eq(Jobs.recurrence_label(nil), "manual")
end

--- intervalo, diária e semanal
function test_format_jobs_recorrencia__intervalo_diaria_e_semanal()
    assert_eq(Jobs.recurrence_label({ IntervalHours = 6 }), "a cada 6h")
    assert_eq(Jobs.recurrence_label({ Daily = { hour = 3, minute = 5 } }), "diariamente às 03:05")
    assert_eq(Jobs.recurrence_label({ Weekly = { weekday = 0, hour = 9, minute = 30 } }), "semanalmente seg às 09:30")
    assert_eq(Jobs.recurrence_label({ Weekly = { weekday = 6, hour = 23, minute = 0 } }), "semanalmente dom às 23:00")
end

--- o dia da semana dá a volta (módulo 7)
function test_format_jobs_recorrencia__o_dia_da_semana_da_a_volta_modulo_7()
    assert_has(Jobs.recurrence_label({ Weekly = { weekday = 7, hour = 0, minute = 0 } }), "seg")
    assert_has(Jobs.recurrence_label({ Weekly = { weekday = 9, hour = 0, minute = 0 } }), "qua")
end

--- forma desconhecida vira traço
function test_format_jobs_recorrencia__forma_desconhecida_vira_traco()
    assert_eq(Jobs.recurrence_label({ Mensal = {} }), "—")
end

--- última execução: nunca, rodando, ok, falhou
function test_format_jobs_estado__ultima_execucao_nunca_rodando_ok_falhou()
    local label, kind = Jobs.run_status(nil)
    assert_eq(label, "nunca rodou")
    assert_eq(kind, "muted")
    label, kind = Jobs.run_status({})
    assert_eq(label, "rodando…")
    assert_eq(kind, "warn")
    label, kind = Jobs.run_status({ success = true })
    assert_eq(label, "ok")
    assert_eq(kind, "ok")
    label, kind = Jobs.run_status({ success = false })
    assert_eq(label, "falhou")
    assert_eq(kind, "bad")
end

--- aquecimento: aquecendo vence quente, e nil conta como frio
function test_format_jobs_estado__aquecimento_aquecendo_vence_quente_e_nil_conta_como_frio()
    assert_eq(Jobs.warm_status({ warming = true, warm = true }), "aquecendo…")
    assert_eq(Jobs.warm_status({ warm = true }), "quente")
    assert_eq(Jobs.warm_status({}), "frio")
    assert_eq(Jobs.warm_status(nil), "frio")
    assert_eq(select(2, Jobs.warm_status({ warm = true })), "ok")
    assert_eq(select(2, Jobs.warm_status({ warming = true })), "warn")
end

--- serviço sem build não tem selo
function test_format_jobs_estado__servico_sem_build_nao_tem_selo()
    local label, kind = Jobs.service_warm_status(nil)
    assert_eq(label, "")
    assert_eq(kind, "muted")
    assert_eq(Jobs.service_warm_status({ warm = true }), "quente")
end

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

--- uma linha por job, com o total
function test_format_jobs_tela_schedules__uma_linha_por_job_com_o_total()
    local json_texto, total = Jobs.summaries({ resumo(), resumo({ job = { id = "j2", name = "x", enabled = false } }) }, nil)
    assert_eq(total, 2)
    local linhas = json.decode(json_texto)
    assert_eq(#linhas, 2)
    assert_eq(linhas[1].id, "j1")
    assert_eq(linhas[1].recurrence, "a cada 2h")
    assert_eq(linhas[1].enabled_label, "Pausar")
    assert_eq(linhas[2].enabled_label, "Ativar")
    assert_eq(linhas[1].last_run_label, "ok")
    assert_eq(linhas[1].last_run_id, "r1")
end

--- o dono mostra projeto / serviço gatilho, ou só o projeto quando autônomo
function test_format_jobs_tela_schedules__o_dono_mostra_projeto_servico_gatilho_ou_so_o_projeto_quando_autonomo()
    local autonomo = resumo()
    autonomo.trigger_service_name = nil
    local linhas = json.decode((Jobs.summaries({ resumo(), autonomo }, nil)))
    -- O orçamento de caracteres depende da largura da janela (ver
    -- Util.column_budgets), então o esperado passa pelo mesmo ellipsis.
    local orcamento = Util.column_budgets().proj
    assert_eq(linhas[1].owner, Util.ellipsis("loja / api", orcamento))
    assert_eq(linhas[2].owner, Util.ellipsis("loja", orcamento))
    assert_eq(linhas[1].trigger_service, "api")
end

--- o nome comprido é truncado na exibição e guardado inteiro
function test_format_jobs_tela_schedules__o_nome_comprido_e_truncado_na_exibicao_e_guardado_inteiro()
    local longo = string.rep("n", 80)
    local linha = json.decode((Jobs.summaries({ resumo({ job = { id = "j", name = longo } }) }, nil)))[1]
    assert_eq(linha.name_full, longo)
    assert_eq(utf8.len(linha.name) < 80, true)
end

--- running reflete o servidor OU o clique em voo
function test_format_jobs_tela_schedules__running_reflete_o_servidor_ou_o_clique_em_voo()
    local rodando = resumo({ last_run = {} })
    local parado = resumo()
    local linhas = json.decode((Jobs.summaries({ rodando, parado }, nil)))
    assert_eq(linhas[1].running, true)
    assert_eq(linhas[2].running, false)

    linhas = json.decode((Jobs.summaries({ parado }, { j1 = true })))
    assert_eq(linhas[1].running, true)
    linhas = json.decode((Jobs.summaries({ parado }, { j1 = false })))
    assert_eq(linhas[1].running, false)
end

--- próxima execução e aquecimento
function test_format_jobs_tela_schedules__proxima_execucao_e_aquecimento()
    local linha = json.decode((Jobs.summaries({
        resumo({
            job = { id = "j", name = "n", next_run_at = "2026-03-01T10:00:00Z" },
            warm = { warm = true, warmed_at = "2026-03-01T09:00:00Z", reason = "build ok" },
        }),
    }, nil)))[1]
    assert_match(linha.next_run_at, "^%d%d/%d%d %d%d:%d%d$")
    assert_eq(linha.is_warm, true)
    assert_eq(linha.is_warming, false)
    assert_eq(linha.warm_label, "quente")
    assert_eq(linha.warm_reason, "build ok")
    assert_match(linha.warmed_at_label, "^%d%d/%d%d")
end

--- sem next_run_at nem aquecimento, os campos têm padrão seguro
function test_format_jobs_tela_schedules__sem_next_run_at_nem_aquecimento_os_campos_tem_padrao_seguro()
    local linha = json.decode((Jobs.summaries({ resumo() }, nil)))[1]
    assert_eq(linha.next_run_at, "—")
    assert_eq(linha.is_warm, false)
    assert_eq(linha.warm_label, "frio")
    assert_eq(linha.warm_reason, "")
    assert_eq(linha.warmed_at_label, "")
end

--- job que nunca rodou
function test_format_jobs_tela_schedules__job_que_nunca_rodou()
    local nunca = resumo()
    nunca.last_run = nil
    local linha = json.decode((Jobs.summaries({ nunca }, nil)))[1]
    assert_eq(linha.last_run_label, "nunca rodou")
    assert_eq(linha.last_run_id, "")
    assert_eq(linha.running, false)
end

--- sem jobs dá [] e zero
function test_format_jobs_tela_schedules__sem_jobs_da_e_zero()
    local texto, total = Jobs.summaries(nil, nil)
    assert_eq(texto, "[]")
    assert_eq(total, 0)
end

local jobs = { { id = "a", name = "migrar" }, { id = "b", name = "seed" }, { id = "c", name = "limpar" } }

--- a fila respeita a ordem configurada e resolve o nome
function test_format_jobs_fila_de_pre_deploy__a_fila_respeita_a_ordem_configurada_e_resolve_o_nome()
    local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_ids = { "c", "a" } }, jobs))
    assert_eq(#fila, 2)
    assert_eq(fila[1].name, "limpar")
    assert_eq(fila[1].index, "1")
    assert_eq(fila[2].name, "migrar")
    assert_eq(fila[2].index, "2")
end

--- um job apagado por fora aparece como removido, para dar para tirá-lo da fila
function test_format_jobs_fila_de_pre_deploy__um_job_apagado_por_fora_aparece_como_removido_para_dar_para_tira_lo_da_fila()
    local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_ids = { "zzz" } }, jobs))
    assert_eq(fila[1].id, "zzz")
    assert_eq(fila[1].name, "(job removido: zzz)")
end

--- o id legado vale quando a fila nova está vazia
function test_format_jobs_fila_de_pre_deploy__o_id_legado_vale_quando_a_fila_nova_esta_vazia()
    local fila = json.decode(Jobs.pre_deploy_queue({ pre_deploy_job_id = "b" }, jobs))
    assert_eq(fila[1].name, "seed")
end

--- os disponíveis são os que ainda não estão na fila
function test_format_jobs_fila_de_pre_deploy__os_disponiveis_sao_os_que_ainda_nao_estao_na_fila()
    local livres = json.decode(Jobs.pre_deploy_available({ pre_deploy_job_ids = { "a" } }, jobs))
    assert_eq(#livres, 2)
    assert_eq(livres[1].id, "b")
    assert_eq(livres[2].id, "c")
end

--- fila e disponíveis juntos cobrem todos os jobs, sem repetir
function test_format_jobs_fila_de_pre_deploy__fila_e_disponiveis_juntos_cobrem_todos_os_jobs_sem_repetir()
    local spec = { pre_deploy_job_ids = { "b" } }
    local na_fila = json.decode(Jobs.pre_deploy_queue(spec, jobs))
    local livres = json.decode(Jobs.pre_deploy_available(spec, jobs))
    assert_eq(#na_fila + #livres, #jobs)
end

--- sem jobs dá []
function test_format_jobs_fila_de_pre_deploy__sem_jobs_da()
    assert_eq(Jobs.pre_deploy_queue({}, nil), "[]")
    assert_eq(Jobs.pre_deploy_available({}, nil), "[]")
end

--- cada execução com seu estado, código de saída e horários
function test_format_jobs_historico__cada_execucao_com_seu_estado_codigo_de_saida_e_horarios()
    local linhas = json.decode(Jobs.runs({
        { id = "r1", started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:00:09Z", exit_code = 0, success = true },
        { id = "r2", started_at = "2026-03-01T10:00:00Z", exit_code = 1, success = false },
        { id = "r3", started_at = "2026-03-01T10:00:00Z" },
    }))
    assert_eq(linhas[1].status_label, "ok")
    assert_eq(linhas[1].exit_code, "0")
    assert_match(linhas[1].finished_at, "^%d%d/%d%d %d%d:%d%d:%d%d$")
    assert_eq(linhas[2].status_label, "falhou")
    assert_eq(linhas[2].status_kind, "bad")
    assert_eq(linhas[2].finished_at, "—")
    assert_eq(linhas[3].status_label, "rodando…")
    assert_eq(linhas[3].exit_code, "—")
end

--- sem execuções dá []
function test_format_jobs_historico__sem_execucoes_da()
    assert_eq(Jobs.runs(nil), "[]")
end
