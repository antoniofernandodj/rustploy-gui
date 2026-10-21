--!nonstrict
local Git = require("format/git")
local Registry = require("format/registry")
local DockerCleanup = require("format/docker_cleanup")

describe("format/git", function()
    test("provedor conectado mostra o @login", function()
        local rows = json.decode(Git.git_providers({
            { id = "p1", name = "gh", kind = "Github", base_url = "https://github.com", auth_mode = "OAuth", account = { login = "ana" } },
        }))
        expect(#rows):toBe(1)
        expect(rows[1].display):toBe("gh (@ana)")
        expect(rows[1].account):toBe("@ana")
        expect(rows[1].connected):toBe("true")
        expect(rows[1].kind):toBe("GitHub")
        expect(rows[1].auth_mode):toBe("OAuth2")
    end)

    test("provedor sem conta diz que não está conectado", function()
        local rows = json.decode(Git.git_providers({
            { id = "p2", name = "meu-gitea", kind = "Gitea", auth_mode = "Pat" },
        }))
        expect(rows[1].connected):toBe("false")
        expect(rows[1].display):toBe("meu-gitea — não conectado")
        expect(rows[1].account_login):toBe("não conectado")
        expect(rows[1].auth_mode):toBe("PAT")
        expect(rows[1].kind):toBe("Gitea")
    end)

    test("tipo desconhecido aparece como veio, e ausente como Git", function()
        local rows = json.decode(Git.git_providers({ { name = "a", kind = "Gitlab" }, { name = "b" } }))
        expect(rows[1].kind):toBe("Gitlab")
        expect(rows[2].kind):toBe("Git")
    end)

    test("listas vazias viram [] e não {}", function()
        expect(Git.git_providers(nil)):toBe("[]")
        expect(Git.git_repos({})):toBe("[]")
        expect(Git.git_branches(nil)):toBe("[]")
    end)

    test("repositórios marcam private/public e branches só carregam o nome", function()
        local repos = json.decode(Git.git_repos({
            { full_name = "a/b", clone_url = "u", default_branch = "main", private = true },
            { full_name = "a/c", clone_url = "v", default_branch = "dev" },
        }))
        expect(repos[1].private):toBe("private")
        expect(repos[2].private):toBe("public")
        local branches = json.decode(Git.git_branches({ { name = "main", extra = 1 } }))
        expect(branches[1].name):toBe("main")
        expect(branches[1].extra):toBeNil()
    end)
end)

describe("format/registry", function()
    test("repos filtra pelo termo e formata contagem e tamanho", function()
        local rows = json.decode(Registry.repos({
            { name = "api", tag_count = 3, size_bytes = 5 * 1024 * 1024, created_at = "2026-03-01T10:00:00Z" },
            { name = "web" },
        }, "ap"))
        expect(#rows):toBe(1)
        expect(rows[1].name):toBe("api")
        expect(rows[1].tag_count):toBe("3")
        expect(rows[1].size):toBe("5 MB")
    end)

    test("repos sem termo traz todos, com defaults seguros", function()
        local rows = json.decode(Registry.repos({ { name = "web" } }, ""))
        expect(rows[1].tag_count):toBe("0")
        expect(rows[1].size):toBe("—")
        expect(rows[1].created):toBe("")
        expect(Registry.repos({ { name = "web" } }, "zzz")):toBe("[]")
    end)

    test("tags encurtam o digest para 12 e guardam o completo", function()
        local rows = json.decode(Registry.tags({
            { tag = "v1", digest = "sha256:0123456789abcdef", media_type = "m", size_bytes = 2048, updated_at = "2026-03-01T10:00:00Z" },
        }))
        expect(rows[1].digest):toBe("sha256:01234")
        expect(rows[1].digest_full):toBe("sha256:0123456789abcdef")
        expect(rows[1].size):toBe("2 KB")
    end)

    test("tokens que nunca foram usados dizem nunca", function()
        local rows = json.decode(Registry.tokens({
            { name = "ci", scope = "push", created_at = "2026-03-01T10:00:00Z" },
            { name = "dev", scope = "pull", created_at = "2026-03-01T10:00:00Z", last_used_at = "2026-03-02T10:00:00Z" },
        }))
        expect(rows[1].last_used):toBe("nunca")
        expect(rows[2].last_used):toMatch("^%d%d/%d%d %d%d:%d%d$")
    end)
end)

describe("format/docker_cleanup", function()
    test("resource_label traduz os conhecidos e devolve o resto", function()
        expect(DockerCleanup.resource_label("images")):toBe("imagens")
        expect(DockerCleanup.resource_label("build_cache")):toBe("cache de build")
        expect(DockerCleanup.resource_label("outro")):toBe("outro")
    end)

    test("sem execução anterior", function()
        expect(DockerCleanup.last_run_summary(nil)):toBe("ainda não rodou")
    end)

    test("resumo soma os bytes e lista cada recurso", function()
        local texto = DockerCleanup.last_run_summary({
            at = "2026-03-01T10:00:00Z",
            results = {
                { resource = "images", count = 3, reclaimed_bytes = 2 * 1024 * 1024 },
                { resource = "volumes", count = 1, reclaimed_bytes = 1024 * 1024 },
            },
        })
        expect(texto):toContain("3 MB liberados")
        expect(texto):toContain("(imagens 3, volumes 1)")
        expect(texto).never:toContain("falharam")
    end)

    test("um recurso com erro avisa e não soma contagem", function()
        local texto = DockerCleanup.last_run_summary({
            at = "2026-03-01T10:00:00Z",
            results = { { resource = "networks", error = "boom" } },
        })
        expect(texto):toContain("redes: erro")
        expect(texto):toContain("alguns recursos falharam, ver logs do daemon")
    end)

    test("execução sem resultados mostra só o cabeçalho", function()
        local texto = DockerCleanup.last_run_summary({ at = "2026-03-01T10:00:00Z", results = {} })
        expect(texto):toContain("liberados")
        expect(texto).never:toContain("(")
    end)
end)
