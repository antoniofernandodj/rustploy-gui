--!nonstrict
local AccessKey = require("access_key")

--- a porta sempre vai, mesmo a padrão
function test_access_key_address_of__a_porta_sempre_vai_mesmo_a_padrao()
    assert_eq(AccessKey.address_of("https://h:9797"), "h:9797")
    assert_eq(AccessKey.address_of("https://h"), "h:443")
    assert_eq(AccessKey.address_of("http://h"), "h:80")
    assert_eq(AccessKey.address_of("HTTP://h"), "h:80")
end

--- caminho, query e fragmento não entram
function test_access_key_address_of__caminho_query_e_fragmento_nao_entram()
    assert_eq(AccessKey.address_of("https://h:9797/api/x?y=1#z"), "h:9797")
end

--- sem esquema vale como https
function test_access_key_address_of__sem_esquema_vale_como_https()
    assert_eq(AccessKey.address_of("h:9797"), "h:9797")
    assert_eq(AccessKey.address_of("h"), "h:443")
end

--- IPv6 entre colchetes: os : do endereço não são porta
function test_access_key_address_of__ipv6_entre_colchetes_os_do_endereco_nao_sao_porta()
    assert_eq(AccessKey.address_of("https://[::1]"), "[::1]:443")
    assert_eq(AccessKey.address_of("https://[::1]:9797"), "[::1]:9797")
end

-- Os valores esperados saem do `base64.b64encode` do Python, que é o formato
-- que o daemon escreve no config.toml.
--- é o base64 padrão de host:porta::token
function test_access_key_encode__e_o_base64_padrao_de_host_porta_token()
    assert_eq(AccessKey.encode("https://h:9797", "tok"), "aDo5Nzk3Ojp0b2s=")
    assert_eq(AccessKey.encode("https://h", "abc"), "aDo0NDM6OmFiYw==")
    assert_eq(AccessKey.encode("https://srv.example.com:9797", "0123456789abcdef"), "c3J2LmV4YW1wbGUuY29tOjk3OTc6OjAxMjM0NTY3ODlhYmNkZWY=")
end

--- token vazio (API aberta) ainda gera uma chave
function test_access_key_encode__token_vazio_api_aberta_ainda_gera_uma_chave()
    assert_eq(AccessKey.encode("http://h", ""), "aDo4MDo6")
end

--- o separador é ::
function test_access_key_encode__o_separador_e()
    assert_eq(AccessKey.SEPARATOR, "::")
end

--- lê o que o Python gera
function test_access_key_decode__le_o_que_o_python_gera()
    local chave = AccessKey.decode("aDo5Nzk3Ojp0b2s=")
    assert_not_nil(chave)
    assert_eq(chave.address, "h:9797")
    assert_eq(chave.token, "tok")
end

--- encode e decode são inversos
function test_access_key_decode__encode_e_decode_sao_inversos()
    for _, par in {
        { "https://h:9797", "tok" },
        { "https://servidor.exemplo.com:1234", "0123456789abcdef0123456789abcdef" },
        { "http://10.0.0.5", "t" },
        { "https://[::1]:9797", "tk" },
        { "https://h", "" },
    } do
        local chave = AccessKey.decode(AccessKey.encode(par[1], par[2]))
        assert_not_nil(chave)
        assert_eq(chave.address, AccessKey.address_of(par[1]))
        assert_eq(chave.token, par[2])
    end
end

--- aceita o alfabeto url-safe e a falta de padding
function test_access_key_decode__aceita_o_alfabeto_url_safe_e_a_falta_de_padding()
    assert_eq(AccessKey.decode("Wzo6MV06OTc5Nzo6dA").address, "[::1]:9797")
    assert_eq(AccessKey.decode("Wzo6MV06OTc5Nzo6dA==").token, "t")
end

--- apara espaços em volta da chave colada
function test_access_key_decode__apara_espacos_em_volta_da_chave_colada()
    local chave = AccessKey.decode("  aDo5Nzk3Ojp0b2s=\n")
    assert_eq(chave.token, "tok")
end

--- um esquema posto à mão é pulado
function test_access_key_decode__um_esquema_posto_a_mao_e_pulado()
    local chave = AccessKey.decode("aHR0cHM6Ly9oOjk3OTc6OnRvaw==")
    assert_eq(chave.address, "h:9797")
    assert_eq(chave.token, "tok")
end

--- endereço e token com espaços são aparados
function test_access_key_decode__endereco_e_token_com_espacos_sao_aparados()
    local chave = AccessKey.decode("ICBoOjEgIDo6ICB0b2sgIA==")
    assert_eq(chave.address, "h:1")
    assert_eq(chave.token, "tok")
end

--- token vazio vale (daemon sem [api].token)
function test_access_key_decode__token_vazio_vale_daemon_sem_api_token()
    local chave, motivo = AccessKey.decode("aDoxOjo=")
    assert_nil(motivo)
    assert_eq(chave.address, "h:1")
    assert_eq(chave.token, "")
end

--- vazio pede para colar
function test_access_key_decode__vazio_pede_para_colar()
    local chave, motivo = AccessKey.decode("   ")
    assert_nil(chave)
    assert_has(motivo, "cole o token")
    assert_has(select(2, AccessKey.decode(nil)), "cole o token")
end

--- caractere fora do alfabeto ou comprimento impossível = corrompido
function test_access_key_decode__caractere_fora_do_alfabeto_ou_comprimento_impossivel_corrompido()
    for _, ruim in { "!!!!", "aDo5Nzk3Ojp0b2s$", "a" } do
        local chave, motivo = AccessKey.decode(ruim)
        assert_nil(chave)
        assert_has(motivo, "corrompido")
    end
end

--- o token da API colado no lugar do de conexão é reconhecido
function test_access_key_decode__o_token_da_api_colado_no_lugar_do_de_conexao_e_reconhecido()
    -- Um token hex também "decodifica" como base64, mas não traz o `::`.
    local chave, motivo = AccessKey.decode("0123456789abcdef0123456789abcdef")
    assert_nil(chave)
    assert_has(motivo, "não é um token de conexão")
end

--- bytes que não são texto também caem nesse aviso
function test_access_key_decode__bytes_que_nao_sao_texto_tambem_caem_nesse_aviso()
    local chave, motivo = AccessKey.decode("//79/A==")
    assert_nil(chave)
    assert_has(motivo, "não é um token de conexão")
end

--- endereço vazio é corrompido
function test_access_key_decode__endereco_vazio_e_corrompido()
    local chave, motivo = AccessKey.decode("Ojp0b2s=")
    assert_nil(chave)
    assert_has(motivo, "endereço vazio")
end

--- mostra o servidor e as pontas da chave
function test_access_key_hint__mostra_o_servidor_e_as_pontas_da_chave()
    assert_eq(AccessKey.hint("https://h:9797", "aDo5Nzk3Ojp0b2s="), "h:9797 · aDo5Nz…p0b2s=")
end
