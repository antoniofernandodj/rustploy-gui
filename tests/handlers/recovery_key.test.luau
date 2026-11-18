--!nonstrict
-- Settings → Chave de recuperação: sem conexão os handlers são inertes, a tela
-- nasce sem chave, e "Guardei" esquece a privada da memória da tela.

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem sessão, gerar não faz nada (nem toast, nem privada na tela)
function test_recovery_key__sem_conexao_e_inerte()
    local tela = nova({})
    tela:call("recovery_key_generate")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("recovery_key_generated"), "false")
    assert_eq(tela:get("recovery_key_private"), "")
    -- a tela nasce "sem chave": é a flag `missing` (não o inverso de
    -- `configured`) que mostra o botão de gerar
    assert_eq(tela:get("recovery_key_missing"), "true")
end

--- "Guardei em lugar seguro" apaga a privada e o conteúdo do arquivo do estado
--- da tela
function test_recovery_key__dismiss_esquece_a_privada()
    local tela = nova({
        recovery_key_generated = "true",
        recovery_key_private = "AGE-SECRET-KEY-1ABC",
        recovery_key_contents = "# x\nAGE-SECRET-KEY-1ABC",
    })
    tela:call("recovery_key_dismiss")
    assert_eq(tela:get("recovery_key_generated"), "false")
    assert_eq(tela:get("recovery_key_private"), "")
    assert_eq(tela:get("recovery_key_contents"), "")
end

--- o formulário do arquivo de recuperação começa com o repositório, a branch e
--- a conta que o Git Sync já usa
function test_recovery_key__formulario_comeca_com_o_git_sync()
    local tela = nova({
        state_git_form_remote = "https://github.com/org/infra.git",
        state_git_form_branch = "estado",
        state_git_form_provider_id = "p1",
    })
    tela:eval([[ require("handlers/recovery_key").load() ]])
    assert_eq(
        tela:get("recovery_key_infra_remote"),
        "https://github.com/org/infra.git"
    )
    assert_eq(tela:get("recovery_key_infra_branch"), "estado")
    assert_eq(tela:get("recovery_key_provider_id"), "p1")
    tela:call("recovery_key_provider_pick", "p2")
    assert_eq(tela:get("recovery_key_provider_id"), "p2")
end

--- sem repositório, com SSH ou sem conta (para https), o que falta é dito
--- antes de ir ao daemon; remoto local dispensa a conta
function test_recovery_key__o_que_falta_para_gerar()
    local tela = nova({})
    local function falta(remote, provider_id)
        tela:set("recovery_key_infra_remote", remote)
        tela:set("recovery_key_provider_id", provider_id)
        tela:eval([[
            ctx.falta = require("handlers/recovery_key").missing_field() or ""
        ]])
        return tela:get("falta")
    end
    assert_true(falta("", "p1"):find("infra repository", 1, true) ~= nil)
    local ssh = falta("git@github.com:o/i.git", "p1")
    assert_true(ssh:find("https", 1, true) ~= nil, ssh)
    assert_true(
        falta("https://github.com/o/i.git", ""):find("Git account", 1, true)
            ~= nil
    )
    assert_eq(falta("https://github.com/o/i.git", "p1"), "")
    assert_eq(falta("file:///srv/infra.git", ""), "")
end
