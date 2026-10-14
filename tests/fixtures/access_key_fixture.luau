--!strict
-- Fixture do teste `access_key.rs` (nome diferente do módulo, senão o
-- `require` resolve para ela mesma): exercita o codec da chave de acesso através
-- do motor (o `bit32` e o `utf8` de verdade) e deixa cada resultado numa chave
-- de contexto. Mora fora da árvore de scripts do app pelo mesmo motivo da
-- `time.luau`: o `require` resolve por `GLACIER_LUAU_PATH`.
local AccessKey = require("access_key")

function init(): ()
    ctx.key_encoded = AccessKey.encode("http://127.0.0.1:9", "x")

    ctx.key_encoded_https_port = AccessKey.encode("https://a.b:9797", "x")

    local round_trips: { string } = {}
    for _, url in { "https://a.b:9797", "http://rustploy-ms.itemize.com.br:9797", "https://a.b", "http://[::1]:9797" } do
        local decoded = AccessKey.decode(AccessKey.encode(url, "tok-123_ABC"))
        table.insert(round_trips, if decoded then decoded.url .. "|" .. decoded.token else "nil")
    end
    ctx.key_round_trip = table.concat(round_trips, " ")

    local _, missing_prefix = AccessKey.decode("tok-123")
    ctx.key_missing_prefix = missing_prefix or ""

    local _, corrupted = AccessKey.decode("!!!")
    ctx.key_corrupted = corrupted or ""

    ctx.key_hint = AccessKey.hint("https://a.b:9797", AccessKey.encode("https://a.b:9797", "x"))
end
