--!nonstrict
-- Linha de variável editável no lugar (handlers/env_rows.luau + os handlers
-- `*_env_row_*` de handlers/secrets.luau): chave e valor sem borda, "usar
-- secret" com lista, e nada grava sem OK + confirmação. O `State.api` é um
-- falso injetado na VM da tela com `tela:eval`; `confirm` suspende o handler e
-- `tela:answer(true | false)` o retoma.

local function nova()
    local tela = component("views/app.gv", {})
    tela:call("init")
    tela:set("selected_project_id", "prj_1")
    return tela
end

local LINHAS = '[{"key":"A","value":"1","kind":"plain","secret_name":""},'
    .. '{"key":"SENHA","value":"🔒 '
    .. 'secret:DB_PASS","kind":"secret","secret_name":"DB_PASS"}]'

-- Publica as linhas do projeto e os secrets que o select oferece (o que
-- stream.luau faz).
local function publica(tela, secrets)
    tela:eval([[
        local EnvRows = require("handlers/env_rows")
        EnvRows.publish("project", ]] .. string.format("%q", LINHAS) .. [[)
        local opcoes = {}
        for _, nome in ipairs({ ]] .. (secrets or "") .. [[ }) do
            table.insert(opcoes, { name = nome, label = nome })
        end
        EnvRows.set_secret_options("project", opcoes)
    ]])
end

-- Um campo (`campo`) da linha publicada `n` (1 = A, 2 = SENHA).
local function linha(tela, n, campo)
    tela:eval(
        string.format(
            [[ ctx.lido = tostring(json.decode(ctx.project_env)[%d].%s) ]],
            n,
            campo
        )
    )
    return tela:get("lido")
end

local function com_api(tela)
    tela:eval([[
        local State = require("state")
        State.enviados = {}
        State.api = {
            rpc_checked = function(_self, comando)
                local nome = next(comando)
                table.insert(State.enviados, nome)
                State["ultimo_" .. nome] = comando[nome]
                return true, {}
            end,
            rpc = function() return false, "sem snapshot no teste" end,
        }
    ]])
end

local function enviados(tela)
    tela:eval(
        [[ ctx.enviados = table.concat(require("state").enviados, ",") ]]
    )
    return tela:get("enviados")
end

--- cada linha ganha as chaves dos seus campos, com o que está gravado, e nasce
--- sem alteração
function test_env_rows__publica_os_campos_com_o_valor_gravado()
    local tela = nova()
    publica(tela, '"DB_PASS"')
    assert_eq(linha(tela, 1, "dirty"), "false")
    assert_eq(linha(tela, 1, "use_secret"), "false")
    assert_eq(tela:get(linha(tela, 1, "bind_key")), "A")
    assert_eq(tela:get(linha(tela, 1, "bind_value")), "1")
    -- a variável que aponta para um secret mostra a lista, com o secret
    -- escolhido
    assert_eq(linha(tela, 2, "use_secret"), "true")
    assert_eq(tela:get(linha(tela, 2, "bind_secret")), "DB_PASS")
end

--- digitar só muda o rascunho: aparece o OK, nada vai ao daemon
function test_env_rows__digitar_marca_a_linha_sem_gravar()
    local tela = nova()
    com_api(tela)
    publica(tela)
    tela:call("project_env_row_key:A", "B")
    assert_eq(linha(tela, 1, "dirty"), "true")
    assert_eq(tela:get(linha(tela, 1, "bind_key")), "B")
    assert_eq(enviados(tela), "")
end

--- o snapshot republica a lista sem apagar o que está sendo digitado
function test_env_rows__o_rascunho_sobrevive_ao_snapshot()
    local tela = nova()
    publica(tela)
    tela:call("project_env_row_value:A", "novo")
    publica(tela)
    assert_eq(tela:get(linha(tela, 1, "bind_value")), "novo")
    assert_eq(linha(tela, 1, "dirty"), "true")
end

--- ✕ desfaz: volta ao gravado e o OK some
function test_env_rows__desfazer_volta_ao_gravado()
    local tela = nova()
    publica(tela)
    tela:call("project_env_row_key:A", "B")
    tela:call("project_env_row_reset:A")
    assert_eq(linha(tela, 1, "dirty"), "false")
    assert_eq(tela:get(linha(tela, 1, "bind_key")), "A")
end

--- marcar "usar secret" troca o valor pela lista; desmarcar de novo não deixa
--- alteração
function test_env_rows__usar_secret_liga_e_desliga()
    local tela = nova()
    publica(tela, '"DB_PASS"')
    tela:call("project_env_row_use_secret:A", "true")
    assert_eq(linha(tela, 1, "use_secret"), "true")
    assert_eq(linha(tela, 1, "dirty"), "true")
    tela:call("project_env_row_use_secret:A", "false")
    assert_eq(linha(tela, 1, "dirty"), "false")
end

--- um secret que a variável usa mas sumiu continua na lista, marcado
function test_env_rows__secret_sumido_fica_na_lista()
    local tela = nova()
    publica(tela, '"OUTRO"')
    tela:eval([[
        local opcoes = json.decode(ctx.project_env_secret_options)
        ctx.n_opcoes = tostring(#opcoes)
        ctx.ultima = opcoes[#opcoes].name
    ]])
    assert_eq(tela:get("n_opcoes"), "2")
    assert_eq(tela:get("ultima"), "DB_PASS")
end

--- "usar secret" sem escolher um secret não grava nem pede confirmação
function test_env_rows__secret_sem_escolha_nao_grava()
    local tela = nova()
    com_api(tela)
    publica(tela, '"DB_PASS"')
    tela:call("project_env_row_use_secret:A", "true")
    tela:call("project_env_row_save:A")
    assert_eq(enviados(tela), "")
    assert_eq(linha(tela, 1, "dirty"), "true")
end

--- recusar a confirmação não manda nada e mantém o rascunho
function test_env_rows__recusar_a_confirmacao_mantem_o_rascunho()
    local tela = nova()
    com_api(tela)
    publica(tela)
    tela:call("project_env_row_key:A", "B")
    tela:call("project_env_row_save:A")
    tela:answer(false)
    assert_eq(enviados(tela), "")
    assert_eq(linha(tela, 1, "dirty"), "true")
end

--- confirmar grava o valor (pelo nome antigo) e depois a chave, e limpa o
--- rascunho
function test_env_rows__confirmar_grava_valor_e_depois_a_chave()
    local tela = nova()
    com_api(tela)
    publica(tela, '"DB_PASS"')
    tela:call("project_env_row_key:A", "B")
    tela:call("project_env_row_use_secret:A", "true")
    tela:call("project_env_row_secret:A", "DB_PASS")
    tela:call("project_env_row_save:A")
    tela:answer(true)
    assert_eq(enviados(tela), "EnvValueSet,EnvKeyRename")
    tela:eval([[
        local State = require("state")
        ctx.chave_do_valor = State.ultimo_EnvValueSet.key
        ctx.secret = State.ultimo_EnvValueSet.value.Secret
        ctx.de = State.ultimo_EnvKeyRename.from
        ctx.para = State.ultimo_EnvKeyRename.to
    ]])
    assert_eq(tela:get("chave_do_valor"), "A")
    assert_eq(tela:get("secret"), "DB_PASS")
    assert_eq(tela:get("de"), "A")
    assert_eq(tela:get("para"), "B")
    assert_eq(linha(tela, 1, "dirty"), "false")
end

--- desmarcar "usar secret" numa variável secret grava um valor em claro
function test_env_rows__deixar_de_usar_secret_grava_valor_em_claro()
    local tela = nova()
    com_api(tela)
    publica(tela, '"DB_PASS"')
    tela:call("project_env_row_use_secret:SENHA", "false")
    tela:call("project_env_row_value:SENHA", "abc")
    tela:call("project_env_row_save:SENHA")
    tela:answer(true)
    assert_eq(enviados(tela), "EnvValueSet")
    tela:eval(
        [[ ctx.plain = require("state").ultimo_EnvValueSet.value.Plain ]]
    )
    assert_eq(tela:get("plain"), "abc")
end

-- ── envs de um job (job_env_core.luau, o painel da tela do job e da janela
-- Novo/Editar job) ──

-- Abre o job "job_1" (gatilho svc_1) com um daemon falso: os secrets do job
-- são J, os do serviço S e J, os do projeto P e S.
local function job(tela)
    tela:set("job_env_job_id", "job_1")
    tela:set("job_env_project_id", "prj_1")
    tela:eval([[
        local State = require("state")
        State.enviados = {}
        local api = {
            rpc = function(_self, comando)
                if comando.JobList then
                    return true, { Jobs = { {
                        id = "job_1",
                        project_id = "prj_1",
                        name = "backup",
                        trigger_service_id = "svc_1",
                        env_vars = { { key = "A", value = { Plain = "1" } } },
                        env_comments = {},
                    } } }
                end
                local pedido = comando.SecretList
                if pedido.job_id then
                    return true, { SecretNames = { "J" } }
                end
                if pedido.service_id then
                    return true, { SecretNames = { "S", "J" } }
                end
                return true, { SecretNames = { "P", "S" } }
            end,
            rpc_checked = function(_self, comando)
                local nome = next(comando)
                table.insert(State.enviados, nome)
                State["ultimo_" .. nome] = comando[nome]
                return true, {}
            end,
        }
        local Core = require("job_env_core")
        Core.setup { api = api, project_id = "prj_1", job_id = "job_1" }
        Core.load()
    ]])
end

--- a lista do job traz os secrets dele, os do serviço gatilho e os do projeto,
--- sem repetir nome
function test_env_rows__job_lista_secrets_do_job_servico_e_projeto()
    local tela = nova()
    job(tela)
    tela:eval([[
        local nomes = {}
        for _, opcao in ipairs(json.decode(ctx.job_env_secret_options)) do
            table.insert(nomes, opcao.name)
        end
        ctx.nomes = table.concat(nomes, ",")
    ]])
    assert_eq(tela:get("nomes"), "J,S,P")
end

--- no job, o OK pede confirmação e grava com o job_id
function test_env_rows__job_ok_grava_com_job_id()
    local tela = nova()
    job(tela)
    tela:call("job_env_row_use_secret:A", "true")
    tela:call("job_env_row_secret:A", "S")
    tela:call("job_env_row_save:A")
    assert_eq(enviados(tela), "")
    tela:answer(true)
    assert_eq(enviados(tela), "EnvValueSet")
    tela:eval([[
        local State = require("state")
        ctx.job = State.ultimo_EnvValueSet.job_id
        ctx.secret = State.ultimo_EnvValueSet.value.Secret
    ]])
    assert_eq(tela:get("job"), "job_1")
    assert_eq(tela:get("secret"), "S")
end

--- form de adicionar do job: "usar secret" grava a referência ao secret
--- escolhido
function test_env_rows__job_adicionar_com_secret()
    local tela = nova()
    job(tela)
    tela:call("job_env_new_use_secret", "true")
    tela:set("job_env_new_key", "B")
    tela:set("job_env_new_value", "P")
    tela:call("job_env_add")
    tela:eval([[
        local vars = require("state").ultimo_JobUpdate.env_vars
        local last = vars[#vars]
        ctx.ultima = last.key .. "=" .. tostring(last.value.Secret)
    ]])
    assert_eq(tela:get("ultima"), "B=P")
    assert_eq(tela:get("job_env_new_is_secret"), "false")
end
