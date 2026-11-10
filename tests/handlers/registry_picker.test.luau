--!nonstrict
-- Sub-aba Registry do serviço: o select de repositório/tag monta a imagem do
-- registry embutido. Sem `State.api` as buscas de tags são inertes, então dá
-- para exercitar só a montagem da string.

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- repo + tag viram a imagem pelo loopback do registry
function test_registry_picker__repo_e_tag_montam_a_imagem()
    local tela = nova({ registry_loopback = "127.0.0.1:5100" })
    tela:call("registry_picker_repo_pick", "flow-client")
    assert_eq(tela:get("registry_picker_image"), "")
    tela:call("registry_picker_tag_pick", "staging")
    assert_eq(
        tela:get("registry_picker_image"),
        "127.0.0.1:5100/flow-client:staging"
    )
end

--- trocar o repositório zera a tag
function test_registry_picker__trocar_o_repo_zera_a_tag()
    local tela = nova({ registry_loopback = "127.0.0.1:5100" })
    tela:call("registry_picker_repo_pick", "a")
    tela:call("registry_picker_tag_pick", "v1")
    tela:call("registry_picker_repo_pick", "b")
    assert_eq(tela:get("registry_picker_tag"), "")
    assert_eq(tela:get("registry_picker_image"), "")
end

--- imagem existente é desmontada em repo e tag (host descartado)
function test_registry_picker__carrega_a_imagem_atual()
    local tela = nova({})
    tela:call("registry_picker_load", "127.0.0.1:5100/org/app:1.2")
    assert_eq(tela:get("registry_picker_repo"), "org/app")
    assert_eq(tela:get("registry_picker_tag"), "1.2")
end
