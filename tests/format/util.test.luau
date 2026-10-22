--!nonstrict
local Util = require("format/util")

--- termo vazio ou nil sempre casa (a busca é filtro, não requisito)
function test_busca__termo_vazio_ou_nil_sempre_casa_a_busca_e_filtro_nao()
    assert_eq(Util.matches("", { "qualquer" }), true)
    assert_eq(Util.matches(nil, {}), true)
end

--- casa por trecho, sem diferenciar caixa do campo
function test_busca__casa_por_trecho_sem_diferenciar_caixa_do_campo()
    assert_eq(Util.matches("api", { "Minha-API-gateway" }), true)
    assert_eq(Util.matches("worker", { "api", "db" }), false)
end

--- o termo é literal, não padrão Lua
function test_busca__o_termo_e_literal_nao_padrao_lua()
    assert_eq(Util.matches("a.b", { "a.b" }), true)
    assert_eq(Util.matches("a.b", { "axb" }), false)
    assert_eq(Util.matches("%", { "100%" }), true)
end

--- campos que não são texto são ignorados
function test_busca__campos_que_nao_sao_texto_sao_ignorados()
    assert_eq(Util.matches("8080", { 8080, nil, true }), false)
    assert_eq(Util.matches("8080", { 8080, "porta 8080" }), true)
end

--- ellipsis não mexe no que cabe
function test_texto__ellipsis_nao_mexe_no_que_cabe()
    assert_eq(Util.ellipsis("curto", 10), "curto")
    assert_eq(Util.ellipsis("exato", 5), "exato")
    assert_eq(Util.ellipsis(nil, 5), "")
end

--- ellipsis corta em caracteres, não em bytes, e anexa …
function test_texto__ellipsis_corta_em_caracteres_nao_em_bytes_e_anexa()
    assert_eq(Util.ellipsis("abcdefgh", 3), "abc…")
    assert_eq(Util.ellipsis("ação-longa", 4), "ação…")
end

--- short_reason fica com a primeira linha não vazia, aparada
function test_texto__short_reason_fica_com_a_primeira_linha_nao_vazia_aparada()
    assert_eq(
        Util.short_reason("\n\n   falhou o build  \nlinha dois"),
        "falhou o build"
    )
end

--- short_reason trunca no limite pedido e tem padrão de 140
function test_texto__short_reason_trunca_no_limite_pedido_e_tem_padrao_de_140()
    assert_eq(Util.short_reason("abcdefghij", 4), "abcd…")
    local longa = string.rep("x", 200)
    assert_eq(utf8.len(Util.short_reason(longa)), 141)
end

--- short_reason devolve vazio sem motivo
function test_texto__short_reason_devolve_vazio_sem_motivo()
    assert_eq(Util.short_reason(nil), "")
    assert_eq(Util.short_reason(42), "")
    assert_eq(Util.short_reason(" \n \r\n"), "")
end

--- strip_ansi tira cor, cursor, OSC, CR e NUL
function test_texto__strip_ansi_tira_cor_cursor_osc_cr_e_nul()
    assert_eq(Util.strip_ansi("\27[2m\27[32mok\27[0m"), "ok")
    assert_eq(Util.strip_ansi("a\27[2Kb\27[1;5Hc"), "abc")
    assert_eq(Util.strip_ansi("\27]0;título\7texto"), "texto")
    assert_eq(Util.strip_ansi("linha\r\0"), "linha")
    assert_eq(Util.strip_ansi(nil), "")
end

--- strip_ansi não mexe em texto limpo
function test_texto__strip_ansi_nao_mexe_em_texto_limpo()
    assert_eq(
        Util.strip_ansi("sem [colchetes] nem ESC"),
        "sem [colchetes] nem ESC"
    )
end

--- encode_array força [] quando vazio (tabela vazia viraria {})
function test_arrays__encode_array_forca_quando_vazio_tabela_vazia_viraria()
    assert_eq(Util.encode_array({}), "[]")
    assert_ne(json.encode({}), "[]")
end

--- encode_array codifica a lista quando há itens
function test_arrays__encode_array_codifica_a_lista_quando_ha_itens()
    local back = json.decode(Util.encode_array({ { a = 1 }, { a = 2 } }))
    assert_eq(#back, 2)
    assert_eq(back[2].a, 2)
end

--- status_label_color e status_kind concordam em todos os estados
function test_estados__status_label_color_e_status_kind_concordam_em_todos_os()
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
        assert_eq(label, caso[2])
        assert_eq(Util.status_kind(caso[1]), caso[3])
    end
end

--- status com erro (tabela) ou desconhecido cai em Error/bad
function test_estados__status_com_erro_tabela_ou_desconhecido_cai_em_error()
    local label, cor = Util.status_label_color({ Error = "boom" })
    assert_eq(label, "Error")
    assert_eq(cor, "#F85149")
    assert_eq(Util.status_kind({ Error = "boom" }), "bad")
    assert_eq(Util.status_kind("Qualquer"), "bad")
    assert_eq(Util.status_kind(nil), "bad")
end

--- estado de deploy: rótulo, cor e kind
function test_estados__estado_de_deploy_rotulo_cor_e_kind()
    local label, cor = Util.state_label_color("Live")
    assert_eq(label, "LIVE")
    assert_eq(cor, "#3FB950")
    assert_eq(Util.state_label_color("Failed"), "FAILED")
    assert_eq(Util.state_label_color("PreDeployCheck"), "PRÉ-DEPLOY CHECK")
    assert_eq(Util.state_label_color("BuildingImage"), "BUILDING")
    assert_eq(Util.state_label_color(nil), "BUILDING")
    assert_eq(Util.state_kind("Live"), "ok")
    assert_eq(Util.state_kind("Failed"), "bad")
    assert_eq(Util.state_kind("Stopped"), "muted")
    assert_eq(Util.state_kind("BuildingImage"), "info")
end

--- in_use_kind
function test_estados__in_use_kind()
    assert_eq(Util.in_use_kind(true), "ok")
    assert_eq(Util.in_use_kind(false), "muted")
end

--- container_state normaliza a caixa e classifica
function test_estados__container_state_normaliza_a_caixa_e_classifica()
    local rotulo, kind = Util.container_state("RUNNING")
    assert_eq(rotulo, "running")
    assert_eq(kind, "ok")
    assert_eq(select(2, Util.container_state("restarting")), "info")
    assert_eq(select(2, Util.container_state("paused")), "warn")
    assert_eq(select(2, Util.container_state("created")), "info")
    assert_eq(select(2, Util.container_state("dead")), "bad")
end

--- container_state: parado ou desconhecido é muted; vazio vira exited
function test_estados__container_state_parado_ou_desconhecido_e_muted_vazio()
    local rotulo, kind = Util.container_state("removing")
    assert_eq(rotulo, "removing")
    assert_eq(kind, "muted")
    assert_eq(Util.container_state(nil), "exited")
    assert_eq(Util.container_state(""), "exited")
end

--- container_stopped: só ativo (running/restarting/paused) não é removível
function test_estados__container_stopped_so_ativo_running_restarting_paused()
    assert_eq(Util.container_stopped("running"), false)
    assert_eq(Util.container_stopped("Restarting"), false)
    assert_eq(Util.container_stopped("paused"), false)
    assert_eq(Util.container_stopped("exited"), true)
    assert_eq(Util.container_stopped(nil), true)
end

--- source_summary de cada origem
function test_dominio_do_servico__source_summary_de_cada_origem()
    assert_eq(
        Util.source_summary({ Registry = { image = "nginx:1" } }),
        "nginx:1"
    )
    assert_eq(
        Util.source_summary({
            Git = { url = "https://x/r.git", branch = "main" },
        }),
        "https://x/r.git @ main"
    )
    assert_eq(
        Util.source_summary({ Archive = { original_filename = "app.zip" } }),
        "app.zip"
    )
    assert_eq(Util.source_summary({ Archive = { archive_id = "a1" } }), "a1")
    assert_eq(Util.source_summary({ Archive = {} }), "zip enviado")
    assert_eq(Util.source_summary({ Compose = {} }), "docker-compose")
end

--- source_summary de origem ausente ou desconhecida é —
function test_dominio_do_servico__source_summary_de_origem_ausente_ou()
    assert_eq(Util.source_summary(nil), "—")
    assert_eq(Util.source_summary("Git"), "—")
    assert_eq(Util.source_summary({}), "—")
    assert_eq(Util.source_summary({ Registry = {} }), "—")
end

--- domain_routes usa a lista nova e converte tls para booleano
function test_dominio_do_servico__domain_routes_usa_a_lista_nova_e_converte()
    local rotas = Util.domain_routes({
        domains = {
            { domain = "a.com", port = 80, tls = true },
            { domain = "b.com" },
        },
    } :: any)
    assert_eq(#rotas, 2)
    assert_eq(rotas[1].tls, true)
    assert_eq(rotas[2].tls, false)
    assert_eq(rotas[1].port, 80)
end

--- domain_routes cai no domain/tls_enabled legado
function test_dominio_do_servico__domain_routes_cai_no_domain_tls_enabled()
    local rotas =
        Util.domain_routes({ domain = "velho.com", tls_enabled = true } :: any)
    assert_eq(#rotas, 1)
    assert_eq(rotas[1].domain, "velho.com")
    assert_eq(rotas[1].tls, true)
    assert_nil(rotas[1].port)
end

--- a lista nova vence o legado, e vazio não gera rota
function test_dominio_do_servico__a_lista_nova_vence_o_legado_e_vazio_nao()
    local rotas = Util.domain_routes(
        { domains = { { domain = "novo.com" } }, domain = "velho.com" } :: any
    )
    assert_eq(#rotas, 1)
    assert_eq(rotas[1].domain, "novo.com")
    assert_eq(#Util.domain_routes({ domain = "" } :: any), 0)
    assert_eq(#Util.domain_routes({} :: any), 0)
end

--- pre_deploy_checks: a fila nova vence o id legado
function test_dominio_do_servico__pre_deploy_checks_a_fila_nova_vence_o_id()
    assert_eq(
        Util.pre_deploy_checks({
            pre_deploy_job_ids = { "a", "b" },
            pre_deploy_job_id = "z",
        }),
        { "a", "b" }
    )
    assert_eq(
        Util.pre_deploy_checks({
            pre_deploy_job_ids = {},
            pre_deploy_job_id = "z",
        }),
        { "z" }
    )
    assert_eq(Util.pre_deploy_checks({ pre_deploy_job_id = "" }), {})
    assert_eq(Util.pre_deploy_checks({}), {})
end

--- service_pair_list normaliza o snapshot
function test_dominio_do_servico__service_pair_list_normaliza_o_snapshot()
    local pares = Util.service_pair_list({
        { service = { name = "api" }, project_name = "loja" },
        { service = { name = "db" } },
    })
    assert_eq(#pares, 2)
    assert_eq(pares[1].proj, "loja")
    assert_eq(pares[2].proj, "")
    assert_eq(#Util.service_pair_list(nil), 0)
end

--- segue os breakpoints 560/900 da largura da janela
function test_orcamento_de_colunas__segue_os_breakpoints_560_900_da_largura()
    local largura = viewport().width
    local b = Util.column_budgets()
    if largura < 560 then
        assert_eq(b.svc, 12)
    elseif largura < 900 then
        assert_eq(b.svc, 17)
    else
        assert_eq(b.svc, 28)
    end
    for _, campo in { "svc", "proj", "state", "img" } do
        assert_eq(type((b :: any)[campo]), "number")
    end
end
