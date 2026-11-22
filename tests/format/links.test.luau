--!nonstrict
-- Vínculos (aba Advanced): docs/plano-recursos-e-vinculos.md.
local SD = require("format/service_detail")

local function par(id, nome, projeto, extras)
    local spec = { name = nome, port = 5432, project_id = projeto, links = {} }
    for k, v in extras or {} do
        spec[k] = v
    end
    return { svc = { id = id, spec = spec }, proj = "proj-" .. projeto }
end

--- prefixo padrão igual ao do daemon
function test_vinculos__prefixo_padrao_igual_ao_do_daemon()
    assert_eq(SD.link_env_prefix("s3"), "S3")
    assert_eq(SD.link_env_prefix("pg-central"), "PG_CENTRAL")
    assert_eq(SD.link_env_prefix("landing page"), "LANDING_PAGE")
    assert_eq(SD.link_env_prefix("2fa"), "_2FA")
end

--- opções: o mesmo projeto e só banco compartilhado destravado de fora
function test_vinculos__opcoes_do_mesmo_projeto_e_banco_compartilhado_aberto()
    local pares = {
        par("api", "api", "p1"),
        par("db", "db", "p1"),
        par("app_fora", "outro", "p2"),
        par("pg_aberto", "pg", "p2", { shared = { accept_links = true } }),
        par("pg_trancado", "pg2", "p2", { shared = { accept_links = false } }),
    }
    local spec = pares[1].svc.spec
    local opcoes = json.decode(SD.link_options(spec, "api", pares))
    local ids = {}
    for _, o in opcoes do
        ids[o.id] = o.name
    end
    assert_eq(ids["db"], "db")
    -- "pg (projeto proj-p2)" em pt, "pg (project proj-p2)" em inglês
    assert_true(string.find(ids["pg_aberto"], "proj-p2", 1, true) ~= nil)
    assert_eq(ids["api"], nil)
    assert_eq(ids["app_fora"], nil)
    assert_eq(ids["pg_trancado"], nil)

    -- já vinculado sai da lista; a linha mostra as variáveis entregues
    spec.links = { { service_id = "db" } }
    local depois = json.decode(SD.link_options(spec, "api", pares))
    for _, o in depois do
        assert_true(o.id ~= "db")
    end
    local linhas = json.decode(SD.link_rows(spec, pares))
    assert_eq(#linhas, 1)
    assert_eq(linhas[1].vars, "DB_HOST · DB_PORT · DB_URL")
end

--- quem usa: lista e opções, com outros projetos só para banco compartilhado
function test_vinculos__quem_usa_e_quem_pode_passar_a_usar()
    local pares = {
        par("api", "api", "p1", { links = { { service_id = "db" } } }),
        par("worker", "worker", "p1"),
        par("db", "db", "p1"),
        par("fora", "fora", "p2"),
    }
    local db_spec = pares[3].svc.spec
    local consumidores = json.decode(SD.consumer_rows("db", "p1", pares))
    assert_eq(#consumidores, 1)
    assert_eq(consumidores[1].id, "api")

    local opcoes = json.decode(SD.consumer_options(db_spec, "db", pares))
    assert_eq(#opcoes, 1)
    assert_eq(opcoes[1].id, "worker")

    -- banco compartilhado: serviços de outros projetos também podem passar a usá-lo
    db_spec.shared = { accept_links = true }
    local com_fora = json.decode(SD.consumer_options(db_spec, "db", pares))
    assert_eq(#com_fora, 2)
end

--- Fase 2: a linha mostra o recurso e a variável a mais; o tipo vem do product
function test_vinculos__linha_mostra_o_recurso()
    local pares = {
        par("api", "api", "p1"),
        par("s3", "s3", "p1", { product = "rustfs" }),
        par("db", "db", "p1", { product = "postgres" }),
    }
    local spec = pares[1].svc.spec
    spec.links = {
        { service_id = "s3", resource = { name = "uploads", public_read = true } },
        { service_id = "db", resource = { name = "pedidos" } },
    }
    local linhas = json.decode(SD.link_rows(spec, pares))
    assert_true(string.find(linhas[1].name, "bucket uploads", 1, true) ~= nil)
    assert_eq(linhas[1].vars, "S3_HOST · S3_PORT · S3_URL · S3_BUCKET")
    assert_true(string.find(linhas[2].name, "database pedidos", 1, true) ~= nil)
    assert_eq(linhas[2].vars, "DB_HOST · DB_PORT · DB_URL · DB_DATABASE")
    assert_eq(SD.resource_kind("redis"), nil)
end

--- o campo de recurso segue o tipo do serviço escolhido em "Vincular a"
function test_vinculos__campo_de_recurso_segue_o_servico_escolhido()
    local pares = {
        par("s3", "s3", "p1", { product = "minio" }),
        par("db", "db", "p1", { product = "mariadb" }),
        par("cache", "cache", "p1", { product = "redis" }),
    }
    assert_eq(SD.link_target_kind("s3", pares), "bucket")
    assert_eq(SD.link_target_kind("db", pares), "database")
    assert_eq(SD.link_target_kind("cache", pares), "")
    assert_eq(SD.link_target_kind("", pares), "")
end
