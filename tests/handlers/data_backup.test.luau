--!nonstrict
-- Settings → Backups: o destino S3 dos backups. Sem `State.api` os handlers têm de ser inertes
-- (a conexão pode cair no instante do clique) e a chave secreta nunca pode ir parar no ctx.

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem conexão, salvar não faz nada (nem mensagem, nem toast)
function test_data_backup__salvar_sem_conexao_e_inerte()
    local tela = nova({ backup_destination_message = "" })
    tela:call("backup_destination_save")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("backup_destination_message"), "")
end

--- sem conexão, testar e limpar também são inertes
function test_data_backup__testar_e_limpar_sem_conexao_sao_inertes()
    local tela = nova({ backup_destination_message = "" })
    tela:call("backup_destination_test")
    tela:call("backup_destination_clear")
    assert_eq(#tela:toasts(), 0)
    assert_eq(tela:get("backup_destination_message"), "")
end

--- o formulário nasce com defaults seguros: região padrão, path-style ligado, nada configurado
function test_data_backup__formulario_nasce_com_defaults()
    local tela = nova({})
    assert_eq(tela:get("backup_destination_region"), "us-east-1")
    assert_eq(tela:get("backup_destination_path_style"), "true")
    assert_eq(tela:get("backup_destination_configured"), "false")
    assert_eq(tela:get("backup_destination_secret_key"), "")
end
