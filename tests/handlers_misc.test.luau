--!nonstrict
-- Handlers que só mexem no ctx, ou que não fazem nada sem conexão:
-- deploy_queue, secrets e bundle. Sem `State.api` eles têm de ser inertes —
-- nem toast, nem mudança de contexto —, porque o botão pode ser clicado no
-- instante em que a sessão cai.

local function nova(ctx_inicial)
    local tela = component("views/app.gvb", ctx_inicial)
    tela:call("init")
    return tela
end

describe("deploy_queue · sem conexão", function()
    test("cancelar, promover, reordenar e pausar são inertes", function()
        local tela = nova({ deploy_engine_paused = "false" })
        tela:call("queue_cancel", "d1")
        tela:call("queue_promote", "d1")
        tela:call("queue_reorder", "[\"d1\",\"d2\"]")
        tela:call("queue_toggle_pause")
        expect(#tela:toasts()):toBe(0)
        expect(tela:get("deploy_engine_paused")):toBe("false")
    end)

    test("id vazio também não faz nada", function()
        local tela = nova()
        tela:call("queue_cancel", "")
        tela:call("queue_promote", "")
        expect(#tela:toasts()):toBe(0)
    end)
end)

describe("deploy_queue · detalhe do deploy", function()
    -- O painel só faz sentido para um deploy ATIVO: open_detail marca o serviço e
    -- logo em seguida refresh_deploy_engine_detail procura esse id entre os
    -- deploys ativos do snapshot. Sem snapshot (ou sem esse id lá) o deploy já
    -- terminou, e o painel se fecha em vez de ficar apontando para o nada.
    test("sem um deploy ativo com esse id, o painel se fecha na hora", function()
        local tela = nova()
        tela:call("deploy_engine_open_detail", "svc-9")
        expect(tela:get("deploy_engine_detail_id")):toBe("")
        expect(tela:get("deploy_engine_detail_open")):toBe("false")
    end)

    test("fechar limpa o id e desmarca aberto", function()
        local tela = nova({ deploy_engine_detail_id = "svc-9", deploy_engine_detail_open = "true" })
        tela:call("deploy_engine_close_detail")
        expect(tela:get("deploy_engine_detail_id")):toBe("")
        expect(tela:get("deploy_engine_detail_open")):toBe("false")
    end)
end)

describe("secrets", function()
    test("secret_use arma o form em modo secret com o nome escolhido", function()
        local tela = nova()
        tela:call("secret_use", "DB_PASS")
        expect(tela:get("project_env_new_is_secret")):toBe("true")
        expect(tela:get("project_env_new_value")):toBe("DB_PASS")
        expect(tela:get("project_env_new_key")):toBe("DB_PASS")
    end)

    test("secret_use não pisa numa chave que o usuário já digitou", function()
        local tela = nova({ project_env_new_key = "MINHA_CHAVE" })
        tela:call("secret_use", "DB_PASS")
        expect(tela:get("project_env_new_key")):toBe("MINHA_CHAVE")
        expect(tela:get("project_env_new_value")):toBe("DB_PASS")
    end)

    test("secret_use trata chave só de espaços como vazia", function()
        local tela = nova({ project_env_new_key = "   " })
        tela:call("secret_use", "X")
        expect(tela:get("project_env_new_key")):toBe("X")
    end)

    test("o interruptor de secret alterna e limpa o valor digitado", function()
        local tela = nova({ project_env_new_value = "abc" })
        tela:call("project_env_secret_toggle")
        expect(tela:get("project_env_new_is_secret")):toBe("true")
        expect(tela:get("project_env_new_value")):toBe("")
        tela:set("project_env_new_value", "def")
        tela:call("project_env_secret_toggle")
        expect(tela:get("project_env_new_is_secret")):toBe("false")
        expect(tela:get("project_env_new_value")):toBe("")
    end)

    test("a falha de validação só avisa", function()
        local tela = nova()
        tela:call("secret_add_show_validation_errors", "[]")
        local avisos = tela:toasts()
        expect(#avisos):toBe(1)
        expect(avisos[1].kind):toBe("warning")
    end)

    test("adicionar sem projeto ou sem conexão não faz nada", function()
        local tela = nova({ project_secret_new_name = "A", project_secret_new_value = "1" })
        tela:call("secret_add")
        expect(#tela:toasts()):toBe(0)
        expect(tela:get("project_secret_new_name")):toBe("A")

        local com_projeto = nova({ selected_project_id = "p1", project_secret_new_name = "A", project_secret_new_value = "1" })
        com_projeto:call("secret_add")
        expect(#com_projeto:toasts()):toBe(0)
        expect(com_projeto:get("project_secret_new_name")):toBe("A")
    end)

    test("apagar sem projeto ou com nome vazio não pergunta nem faz nada", function()
        local tela = nova()
        tela:call("secret_delete", "X")
        local com_projeto = nova({ selected_project_id = "p1" })
        com_projeto:call("secret_delete", "")
        expect(#tela:toasts() + #com_projeto:toasts()):toBe(0)
    end)
end)

describe("bundle · exportar serviço", function()
    test("sem conexão ou sem serviço escolhido não abre janela nem avisa", function()
        local tela = nova({ selected_service = "svc-1" })
        tela:call("open_export_window", "")
        tela:call("open_export_window", "svc-2")
        expect(#tela:toasts()):toBe(0)
    end)
end)
