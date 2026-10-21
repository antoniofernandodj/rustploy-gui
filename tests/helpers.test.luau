--!nonstrict
local H = require("helpers")

describe("helpers · trim", function()
    test("apara as pontas e aceita nil e não-texto", function()
        expect(H.trim("  oi  ")):toBe("oi")
        expect(H.trim(nil)):toBe("")
        expect(H.trim(42)):toBe("42")
        expect(H.trim("a b")):toBe("a b")
    end)
end)

describe("helpers · referência a segredo", function()
    test("aceita <secret:x> e secret:x", function()
        expect(H.parse_secret_ref("<secret:DB_PASS>")):toBe("DB_PASS")
        expect(H.parse_secret_ref("  secret:TOKEN  ")):toBe("TOKEN")
        expect(H.parse_secret_ref("<secret: espaço >")):toBe("espaço")
    end)

    test("o que não é referência devolve nil", function()
        expect(H.parse_secret_ref("valor comum")):toBeNil()
        expect(H.parse_secret_ref("<secret:>")):toBeNil()
        expect(H.parse_secret_ref("secret:   ")):toBeNil()
        expect(H.parse_secret_ref(nil)):toBeNil()
    end)
end)

describe("helpers · .env", function()
    test("separa chaves, valores e segredos", function()
        local vars = H.parse_dotenv("A=1\nB = dois \nC=<secret:SEG>\n")
        expect(#vars):toBe(3)
        expect(vars[1].key):toBe("A")
        expect(vars[1].value.Plain):toBe("1")
        expect(vars[2].key):toBe("B")
        expect(vars[2].value.Plain):toBe("dois")
        expect(vars[3].value.Secret):toBe("SEG")
    end)

    test("o valor pode conter =", function()
        local vars = H.parse_dotenv("URL=postgres://u:p@h/db?x=1")
        expect(vars[1].value.Plain):toBe("postgres://u:p@h/db?x=1")
    end)

    test("comentários ficam ligados à chave que vem depois", function()
        local vars, comments = H.parse_dotenv("# banco\n# principal\nDB=1\nOUTRA=2")
        expect(#vars):toBe(2)
        expect(#comments):toBe(2)
        expect(comments[1].text):toBe("# banco")
        expect(comments[1].before_key):toBe("DB")
        expect(comments[2].before_key):toBe("DB")
    end)

    test("comentário no fim não tem chave seguinte", function()
        local _, comments = H.parse_dotenv("A=1\n# sobra")
        expect(#comments):toBe(1)
        expect(comments[1].before_key):toBeNil()
    end)

    test("linhas vazias e sem = são ignoradas", function()
        local vars = H.parse_dotenv("\n\nsem igual\n=semchave\nOK=1")
        expect(#vars):toBe(1)
        expect(vars[1].key):toBe("OK")
    end)

    test("entrada vazia ou nil dá listas vazias que codificam como array", function()
        for _, entrada in { "", nil } do
            local vars, comments = H.parse_dotenv(entrada)
            expect(#vars):toBe(0)
            expect(json.encode(vars)):toBe("[]")
            expect(json.encode(comments)):toBe("[]")
        end
    end)

    test("aceita final de linha sem \\n", function()
        expect(#H.parse_dotenv("A=1")):toBe(1)
    end)
end)

describe("helpers · URLs", function()
    test("oauth_redirect_uri monta o callback do provedor", function()
        expect(H.oauth_redirect_uri("https://d.com", "github")):toBe("https://d.com/oauth/github/callback")
        expect(H.oauth_redirect_uri("https://d.com///", "gitea")):toBe("https://d.com/oauth/gitea/callback")
    end)

    test("provedor desconhecido cai em gitea, e base vazia avisa", function()
        expect(H.oauth_redirect_uri("https://d.com", "gitlab")):toBe("https://d.com/oauth/gitea/callback")
        expect(H.oauth_redirect_uri("", "github")):toContain("indisponível")
        expect(H.oauth_redirect_uri(nil, "github")):toContain("/oauth/github/callback")
    end)

    test("looks_like_git_url reconhece os esquemas e o sufixo .git", function()
        for _, boa in { "https://x/r", "http://x/r", "git@github.com:a/b", "ssh://h/r", "file:///tmp/r", "foo/bar.git", "  https://x  " } do
            expect(H.looks_like_git_url(boa)):toBe(true)
        end
        for _, ruim in { "", "ftp://x/r", "só texto", "github.com/a/b" } do
            expect(H.looks_like_git_url(ruim)):toBe(false)
        end
        expect(H.looks_like_git_url(nil)):toBe(false)
    end)

    test("normalize_url fixa o esquema e descarta caminho, query e fragmento", function()
        expect(H.normalize_url("https://a.com/x/y?z=1#f")):toBe("https://a.com")
        expect(H.normalize_url("a.com:8080/p")):toBe("https://a.com:8080")
        expect(H.normalize_url("  HTTP://B.com  ")):toBe("http://B.com")
    end)

    test("normalize_url recusa vazio e esquema que não é http(s)", function()
        expect(H.normalize_url("")):toBeNil()
        expect(H.normalize_url("   ")):toBeNil()
        expect(H.normalize_url("ftp://a.com")):toBeNil()
        expect(H.normalize_url("https://")):toBeNil()
    end)
end)
