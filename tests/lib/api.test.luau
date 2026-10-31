--!nonstrict
local Api = require("net/api")

--- sem token não há cabeçalho; com token, é Bearer
function test_auth_headers__so_com_token_vira_bearer()
    assert_eq(next(Api.auth_headers(nil)), nil)
    assert_eq(next(Api.auth_headers("")), nil)
    assert_eq(Api.auth_headers("abc").Authorization, "Bearer abc")
end

--- a mensagem do motor vence; sem ela, o status HTTP
function test_failure_text__mensagem_do_motor_ou_status()
    assert_eq(
        Api.failure_text({ error = "timeout após 5ms", status = 0 }),
        "timeout após 5ms"
    )
    assert_eq(Api.failure_text({ error = "", status = 502 }), "HTTP 502")
    assert_eq(Api.failure_text({ status = 404 }), "HTTP 404")
end

--- o cliente guarda a base e o token; token vazio vira nil
function test_new__guarda_base_e_trata_token_vazio()
    local com = Api.new("http://x:1", "tok")
    assert_eq(com.base_url, "http://x:1")
    assert_eq(com.token, "tok")
    local sem = Api.new("http://x:1", "")
    assert_nil(sem.token)
end
