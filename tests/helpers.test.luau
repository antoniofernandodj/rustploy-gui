--!nonstrict
local H = require("helpers")

--- apara as pontas e aceita nil e não-texto
function test_helpers_trim__apara_as_pontas_e_aceita_nil_e_nao_texto()
    assert_eq(H.trim("  oi  "), "oi")
    assert_eq(H.trim(nil), "")
    assert_eq(H.trim(42), "42")
    assert_eq(H.trim("a b"), "a b")
end

--- aceita <secret:x> e secret:x
function test_helpers_referencia_a_segredo__aceita_secret_x_e_secret_x()
    assert_eq(H.parse_secret_ref("<secret:DB_PASS>"), "DB_PASS")
    assert_eq(H.parse_secret_ref("  secret:TOKEN  "), "TOKEN")
    assert_eq(H.parse_secret_ref("<secret: espaço >"), "espaço")
end

--- o que não é referência devolve nil
function test_helpers_referencia_a_segredo__o_que_nao_e_referencia_devolve_nil()
    assert_nil(H.parse_secret_ref("valor comum"))
    assert_nil(H.parse_secret_ref("<secret:>"))
    assert_nil(H.parse_secret_ref("secret:   "))
    assert_nil(H.parse_secret_ref(nil))
end

--- separa chaves, valores e segredos
function test_helpers_env__separa_chaves_valores_e_segredos()
    local vars = H.parse_dotenv("A=1\nB = dois \nC=<secret:SEG>\n")
    assert_eq(#vars, 3)
    assert_eq(vars[1].key, "A")
    assert_eq(vars[1].value.Plain, "1")
    assert_eq(vars[2].key, "B")
    assert_eq(vars[2].value.Plain, "dois")
    assert_eq(vars[3].value.Secret, "SEG")
end

--- o valor pode conter =
function test_helpers_env__o_valor_pode_conter()
    local vars = H.parse_dotenv("URL=postgres://u:p@h/db?x=1")
    assert_eq(vars[1].value.Plain, "postgres://u:p@h/db?x=1")
end

--- comentários ficam ligados à chave que vem depois
function test_helpers_env__comentarios_ficam_ligados_a_chave_que_vem_depois()
    local vars, comments = H.parse_dotenv("# banco\n# principal\nDB=1\nOUTRA=2")
    assert_eq(#vars, 2)
    assert_eq(#comments, 2)
    assert_eq(comments[1].text, "# banco")
    assert_eq(comments[1].before_key, "DB")
    assert_eq(comments[2].before_key, "DB")
end

--- comentário no fim não tem chave seguinte
function test_helpers_env__comentario_no_fim_nao_tem_chave_seguinte()
    local _, comments = H.parse_dotenv("A=1\n# sobra")
    assert_eq(#comments, 1)
    assert_nil(comments[1].before_key)
end

--- linhas vazias e sem = são ignoradas
function test_helpers_env__linhas_vazias_e_sem_sao_ignoradas()
    local vars = H.parse_dotenv("\n\nsem igual\n=semchave\nOK=1")
    assert_eq(#vars, 1)
    assert_eq(vars[1].key, "OK")
end

--- entrada vazia ou nil dá listas vazias que codificam como array
function test_helpers_env__entrada_vazia_ou_nil_da_listas_vazias_que_codificam_como_array()
    for _, entrada in { "", nil } do
        local vars, comments = H.parse_dotenv(entrada)
        assert_eq(#vars, 0)
        assert_eq(json.encode(vars), "[]")
        assert_eq(json.encode(comments), "[]")
    end
end

--- aceita final de linha sem \\n
function test_helpers_env__aceita_final_de_linha_sem_n()
    assert_eq(#H.parse_dotenv("A=1"), 1)
end

--- oauth_redirect_uri monta o callback do provedor
function test_helpers_urls__oauth_redirect_uri_monta_o_callback_do_provedor()
    assert_eq(H.oauth_redirect_uri("https://d.com", "github"), "https://d.com/oauth/github/callback")
    assert_eq(H.oauth_redirect_uri("https://d.com///", "gitea"), "https://d.com/oauth/gitea/callback")
end

--- provedor desconhecido cai em gitea, e base vazia avisa
function test_helpers_urls__provedor_desconhecido_cai_em_gitea_e_base_vazia_avisa()
    assert_eq(H.oauth_redirect_uri("https://d.com", "gitlab"), "https://d.com/oauth/gitea/callback")
    assert_has(H.oauth_redirect_uri("", "github"), "indisponível")
    assert_has(H.oauth_redirect_uri(nil, "github"), "/oauth/github/callback")
end

--- looks_like_git_url reconhece os esquemas e o sufixo .git
function test_helpers_urls__looks_like_git_url_reconhece_os_esquemas_e_o_sufixo_git()
    for _, boa in { "https://x/r", "http://x/r", "git@github.com:a/b", "ssh://h/r", "file:///tmp/r", "foo/bar.git", "  https://x  " } do
        assert_eq(H.looks_like_git_url(boa), true)
    end
    for _, ruim in { "", "ftp://x/r", "só texto", "github.com/a/b" } do
        assert_eq(H.looks_like_git_url(ruim), false)
    end
    assert_eq(H.looks_like_git_url(nil), false)
end

--- normalize_url fixa o esquema e descarta caminho, query e fragmento
function test_helpers_urls__normalize_url_fixa_o_esquema_e_descarta_caminho_query_e_fragmento()
    assert_eq(H.normalize_url("https://a.com/x/y?z=1#f"), "https://a.com")
    assert_eq(H.normalize_url("a.com:8080/p"), "https://a.com:8080")
    assert_eq(H.normalize_url("  HTTP://B.com  "), "http://B.com")
end

--- normalize_url recusa vazio e esquema que não é http(s)
function test_helpers_urls__normalize_url_recusa_vazio_e_esquema_que_nao_e_http_s()
    assert_nil(H.normalize_url(""))
    assert_nil(H.normalize_url("   "))
    assert_nil(H.normalize_url("ftp://a.com"))
    assert_nil(H.normalize_url("https://"))
end
