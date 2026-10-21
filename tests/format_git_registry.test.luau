--!nonstrict
local Git = require("format/git")
local Registry = require("format/registry")
local DockerCleanup = require("format/docker_cleanup")

--- provedor conectado mostra o @login
function test_format_git__provedor_conectado_mostra_o_login()
    local rows = json.decode(Git.git_providers({
        { id = "p1", name = "gh", kind = "Github", base_url = "https://github.com", auth_mode = "OAuth", account = { login = "ana" } },
    }))
    assert_eq(#rows, 1)
    assert_eq(rows[1].display, "gh (@ana)")
    assert_eq(rows[1].account, "@ana")
    assert_eq(rows[1].connected, "true")
    assert_eq(rows[1].kind, "GitHub")
    assert_eq(rows[1].auth_mode, "OAuth2")
end

--- provedor sem conta diz que não está conectado
function test_format_git__provedor_sem_conta_diz_que_nao_esta_conectado()
    local rows = json.decode(Git.git_providers({
        { id = "p2", name = "meu-gitea", kind = "Gitea", auth_mode = "Pat" },
    }))
    assert_eq(rows[1].connected, "false")
    assert_eq(rows[1].display, "meu-gitea — não conectado")
    assert_eq(rows[1].account_login, "não conectado")
    assert_eq(rows[1].auth_mode, "PAT")
    assert_eq(rows[1].kind, "Gitea")
end

--- tipo desconhecido aparece como veio, e ausente como Git
function test_format_git__tipo_desconhecido_aparece_como_veio_e_ausente_como_git()
    local rows = json.decode(Git.git_providers({ { name = "a", kind = "Gitlab" }, { name = "b" } }))
    assert_eq(rows[1].kind, "Gitlab")
    assert_eq(rows[2].kind, "Git")
end

--- listas vazias viram [] e não {}
function test_format_git__listas_vazias_viram_e_nao()
    assert_eq(Git.git_providers(nil), "[]")
    assert_eq(Git.git_repos({}), "[]")
    assert_eq(Git.git_branches(nil), "[]")
end

--- repositórios marcam private/public e branches só carregam o nome
function test_format_git__repositorios_marcam_private_public_e_branches_so_carregam_o_nome()
    local repos = json.decode(Git.git_repos({
        { full_name = "a/b", clone_url = "u", default_branch = "main", private = true },
        { full_name = "a/c", clone_url = "v", default_branch = "dev" },
    }))
    assert_eq(repos[1].private, "private")
    assert_eq(repos[2].private, "public")
    local branches = json.decode(Git.git_branches({ { name = "main", extra = 1 } }))
    assert_eq(branches[1].name, "main")
    assert_nil(branches[1].extra)
end

--- repos filtra pelo termo e formata contagem e tamanho
function test_format_registry__repos_filtra_pelo_termo_e_formata_contagem_e_tamanho()
    local rows = json.decode(Registry.repos({
        { name = "api", tag_count = 3, size_bytes = 5 * 1024 * 1024, created_at = "2026-03-01T10:00:00Z" },
        { name = "web" },
    }, "ap"))
    assert_eq(#rows, 1)
    assert_eq(rows[1].name, "api")
    assert_eq(rows[1].tag_count, "3")
    assert_eq(rows[1].size, "5 MB")
end

--- repos sem termo traz todos, com defaults seguros
function test_format_registry__repos_sem_termo_traz_todos_com_defaults_seguros()
    local rows = json.decode(Registry.repos({ { name = "web" } }, ""))
    assert_eq(rows[1].tag_count, "0")
    assert_eq(rows[1].size, "—")
    assert_eq(rows[1].created, "")
    assert_eq(Registry.repos({ { name = "web" } }, "zzz"), "[]")
end

--- tags encurtam o digest para 12 e guardam o completo
function test_format_registry__tags_encurtam_o_digest_para_12_e_guardam_o_completo()
    local rows = json.decode(Registry.tags({
        { tag = "v1", digest = "sha256:0123456789abcdef", media_type = "m", size_bytes = 2048, updated_at = "2026-03-01T10:00:00Z" },
    }))
    assert_eq(rows[1].digest, "sha256:01234")
    assert_eq(rows[1].digest_full, "sha256:0123456789abcdef")
    assert_eq(rows[1].size, "2 KB")
end

--- tokens que nunca foram usados dizem nunca
function test_format_registry__tokens_que_nunca_foram_usados_dizem_nunca()
    local rows = json.decode(Registry.tokens({
        { name = "ci", scope = "push", created_at = "2026-03-01T10:00:00Z" },
        { name = "dev", scope = "pull", created_at = "2026-03-01T10:00:00Z", last_used_at = "2026-03-02T10:00:00Z" },
    }))
    assert_eq(rows[1].last_used, "nunca")
    assert_match(rows[2].last_used, "^%d%d/%d%d %d%d:%d%d$")
end

--- resource_label traduz os conhecidos e devolve o resto
function test_format_docker_cleanup__resource_label_traduz_os_conhecidos_e_devolve_o_resto()
    assert_eq(DockerCleanup.resource_label("images"), "imagens")
    assert_eq(DockerCleanup.resource_label("build_cache"), "cache de build")
    assert_eq(DockerCleanup.resource_label("outro"), "outro")
end

--- sem execução anterior
function test_format_docker_cleanup__sem_execucao_anterior()
    assert_eq(DockerCleanup.last_run_summary(nil), "ainda não rodou")
end

--- resumo soma os bytes e lista cada recurso
function test_format_docker_cleanup__resumo_soma_os_bytes_e_lista_cada_recurso()
    local texto = DockerCleanup.last_run_summary({
        at = "2026-03-01T10:00:00Z",
        results = {
            { resource = "images", count = 3, reclaimed_bytes = 2 * 1024 * 1024 },
            { resource = "volumes", count = 1, reclaimed_bytes = 1024 * 1024 },
        },
    })
    assert_has(texto, "3 MB liberados")
    assert_has(texto, "(imagens 3, volumes 1)")
    assert_eq(string.find(texto, "falharam", 1, true), nil)
end

--- um recurso com erro avisa e não soma contagem
function test_format_docker_cleanup__um_recurso_com_erro_avisa_e_nao_soma_contagem()
    local texto = DockerCleanup.last_run_summary({
        at = "2026-03-01T10:00:00Z",
        results = { { resource = "networks", error = "boom" } },
    })
    assert_has(texto, "redes: erro")
    assert_has(texto, "alguns recursos falharam, ver logs do daemon")
end

--- execução sem resultados mostra só o cabeçalho
function test_format_docker_cleanup__execucao_sem_resultados_mostra_so_o_cabecalho()
    local texto = DockerCleanup.last_run_summary({ at = "2026-03-01T10:00:00Z", results = {} })
    assert_has(texto, "liberados")
    assert_eq(string.find(texto, "(", 1, true), nil)
end
