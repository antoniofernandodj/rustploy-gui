--!nonstrict
-- Settings → Sincronização → "Limpar configuração" (`state_git_clear`) e o projeto editado no
-- lugar (`project_title_change`). O `State.api` é um falso injetado na VM da tela com `tela:eval`
-- (cada `component()` tem a sua VM); ele guarda o último comando enviado ao daemon.
--
-- `confirm` suspende o handler: `tela:answer(true | false)` o retoma com o clique do usuário.

local function nova()
    local tela = component("views/app.gv", {})
    tela:call("init")
    return tela
end

local function com_api(tela)
    tela:eval([[
        local State = require("state")
        State.enviados = {}
        State.api = {
            rpc_checked = function(_self, comando)
                local nome = next(comando)
                table.insert(State.enviados, nome)
                State.ultimo = comando
                return true, {}
            end,
            -- Stream.refresh_now (chamado ao fim das ações) só lê; sem snapshot no teste.
            rpc = function() return false, "sem snapshot no teste" end,
        }
    ]])
end

local function enviados(tela)
    tela:eval([[ ctx.enviados = table.concat(require("state").enviados, ",") ]])
    return tela:get("enviados")
end

--- o botão só aparece com algo gravado: modo ligado, repositório ou conta
function test_state_git_clear__flag_de_configurado()
    local tela = nova()
    tela:eval([[
        local status = { mode = "off" }
        for k, v in pairs(require("format").state_git_context(status, nil)) do ctx[k] = v end
    ]])
    assert_eq(tela:get("state_git_is_configured"), "false")
    tela:eval([[
        local status = { mode = "off", remote = "https://github.com/x/y.git" }
        for k, v in pairs(require("format").state_git_context(status, nil)) do ctx[k] = v end
    ]])
    assert_eq(tela:get("state_git_is_configured"), "true")
    tela:eval([[
        local status = { mode = "sync" }
        for k, v in pairs(require("format").state_git_context(status, nil)) do ctx[k] = v end
    ]])
    assert_eq(tela:get("state_git_is_configured"), "true")
end

--- recusar a confirmação não manda nada ao daemon
function test_state_git_clear__recusar_nao_envia()
    local tela = nova()
    com_api(tela)
    tela:call("state_git_clear")
    tela:answer(false)
    assert_eq(enviados(tela), "")
end

--- confirmar manda StateGitConfigure em `off` sem repositório/branch/conta e limpa o formulário
function test_state_git_clear__confirmar_desliga_e_limpa_o_formulario()
    local tela = nova()
    com_api(tela)
    tela:set("state_git_form_mode", "sync")
    tela:set("state_git_form_remote", "https://github.com/x/y.git")
    tela:set("state_git_form_provider_id", "gp_1")
    tela:call("state_git_clear")
    tela:answer(true)
    assert_eq(enviados(tela), "StateGitConfigure")
    tela:eval([[
        local cmd = require("state").ultimo.StateGitConfigure
        ctx.mode = cmd.mode
        ctx.tem_remote = tostring(cmd.remote ~= nil)
        ctx.tem_provider = tostring(cmd.provider_id ~= nil)
    ]])
    assert_eq(tela:get("mode"), "off")
    assert_eq(tela:get("tem_remote"), "false")
    assert_eq(tela:get("tem_provider"), "false")
    assert_eq(tela:get("state_git_form_mode"), "off")
    assert_eq(tela:get("state_git_form_remote"), "")
    assert_eq(tela:get("state_git_form_provider_id"), "")
end

--- projeto: digitar o nome marca "pendente" (o stream não pisa no campo) e não grava na hora
function test_project_title__digitar_marca_pendente_sem_gravar_na_hora()
    local tela = nova()
    com_api(tela)
    tela:set("selected_project_id", "prj_1")
    tela:set("project_name", "Antigo")
    tela:call("project_title_change", "Novo nome")
    assert_eq(tela:get("edit_project_name"), "Novo nome")
    assert_eq(tela:get("project_edit_pending"), "true")
    assert_eq(enviados(tela), "")
end
