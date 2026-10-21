--!nonstrict
local AccessKey = require("access_key")

describe("access_key · address_of", function()
    test("a porta sempre vai, mesmo a padrão", function()
        expect(AccessKey.address_of("https://h:9797")):toBe("h:9797")
        expect(AccessKey.address_of("https://h")):toBe("h:443")
        expect(AccessKey.address_of("http://h")):toBe("h:80")
        expect(AccessKey.address_of("HTTP://h")):toBe("h:80")
    end)

    test("caminho, query e fragmento não entram", function()
        expect(AccessKey.address_of("https://h:9797/api/x?y=1#z")):toBe("h:9797")
    end)

    test("sem esquema vale como https", function()
        expect(AccessKey.address_of("h:9797")):toBe("h:9797")
        expect(AccessKey.address_of("h")):toBe("h:443")
    end)

    test("IPv6 entre colchetes: os : do endereço não são porta", function()
        expect(AccessKey.address_of("https://[::1]")):toBe("[::1]:443")
        expect(AccessKey.address_of("https://[::1]:9797")):toBe("[::1]:9797")
    end)
end)

describe("access_key · encode", function()
    -- Os valores esperados saem do `base64.b64encode` do Python, que é o formato
    -- que o daemon escreve no config.toml.
    test("é o base64 padrão de host:porta::token", function()
        expect(AccessKey.encode("https://h:9797", "tok")):toBe("aDo5Nzk3Ojp0b2s=")
        expect(AccessKey.encode("https://h", "abc")):toBe("aDo0NDM6OmFiYw==")
        expect(AccessKey.encode("https://srv.example.com:9797", "0123456789abcdef"))
            :toBe("c3J2LmV4YW1wbGUuY29tOjk3OTc6OjAxMjM0NTY3ODlhYmNkZWY=")
    end)

    test("token vazio (API aberta) ainda gera uma chave", function()
        expect(AccessKey.encode("http://h", "")):toBe("aDo4MDo6")
    end)

    test("o separador é ::", function()
        expect(AccessKey.SEPARATOR):toBe("::")
    end)
end)

describe("access_key · decode", function()
    test("lê o que o Python gera", function()
        local chave = AccessKey.decode("aDo5Nzk3Ojp0b2s=")
        expect(chave).never:toBeNil()
        expect(chave.address):toBe("h:9797")
        expect(chave.token):toBe("tok")
    end)

    test("encode e decode são inversos", function()
        for _, par in {
            { "https://h:9797", "tok" },
            { "https://servidor.exemplo.com:1234", "0123456789abcdef0123456789abcdef" },
            { "http://10.0.0.5", "t" },
            { "https://[::1]:9797", "tk" },
            { "https://h", "" },
        } do
            local chave = AccessKey.decode(AccessKey.encode(par[1], par[2]))
            expect(chave).never:toBeNil()
            expect(chave.address):toBe(AccessKey.address_of(par[1]))
            expect(chave.token):toBe(par[2])
        end
    end)

    test("aceita o alfabeto url-safe e a falta de padding", function()
        expect(AccessKey.decode("Wzo6MV06OTc5Nzo6dA").address):toBe("[::1]:9797")
        expect(AccessKey.decode("Wzo6MV06OTc5Nzo6dA==").token):toBe("t")
    end)

    test("apara espaços em volta da chave colada", function()
        local chave = AccessKey.decode("  aDo5Nzk3Ojp0b2s=\n")
        expect(chave.token):toBe("tok")
    end)

    test("um esquema posto à mão é pulado", function()
        local chave = AccessKey.decode("aHR0cHM6Ly9oOjk3OTc6OnRvaw==")
        expect(chave.address):toBe("h:9797")
        expect(chave.token):toBe("tok")
    end)

    test("endereço e token com espaços são aparados", function()
        local chave = AccessKey.decode("ICBoOjEgIDo6ICB0b2sgIA==")
        expect(chave.address):toBe("h:1")
        expect(chave.token):toBe("tok")
    end)

    test("token vazio vale (daemon sem [api].token)", function()
        local chave, motivo = AccessKey.decode("aDoxOjo=")
        expect(motivo):toBeNil()
        expect(chave.address):toBe("h:1")
        expect(chave.token):toBe("")
    end)

    test("vazio pede para colar", function()
        local chave, motivo = AccessKey.decode("   ")
        expect(chave):toBeNil()
        expect(motivo):toContain("cole o token")
        expect(select(2, AccessKey.decode(nil))):toContain("cole o token")
    end)

    test("caractere fora do alfabeto ou comprimento impossível = corrompido", function()
        for _, ruim in { "!!!!", "aDo5Nzk3Ojp0b2s$", "a" } do
            local chave, motivo = AccessKey.decode(ruim)
            expect(chave):toBeNil()
            expect(motivo):toContain("corrompido")
        end
    end)

    test("o token da API colado no lugar do de conexão é reconhecido", function()
        -- Um token hex também "decodifica" como base64, mas não traz o `::`.
        local chave, motivo = AccessKey.decode("0123456789abcdef0123456789abcdef")
        expect(chave):toBeNil()
        expect(motivo):toContain("não é um token de conexão")
    end)

    test("bytes que não são texto também caem nesse aviso", function()
        local chave, motivo = AccessKey.decode("//79/A==")
        expect(chave):toBeNil()
        expect(motivo):toContain("não é um token de conexão")
    end)

    test("endereço vazio é corrompido", function()
        local chave, motivo = AccessKey.decode("Ojp0b2s=")
        expect(chave):toBeNil()
        expect(motivo):toContain("endereço vazio")
    end)
end)

describe("access_key · hint", function()
    test("mostra o servidor e as pontas da chave", function()
        expect(AccessKey.hint("https://h:9797", "aDo5Nzk3Ojp0b2s=")):toBe("h:9797 · aDo5Nz…p0b2s=")
    end)
end)
