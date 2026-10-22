--!strict
-- Fixture do teste `access_key.rs` (nome diferente do módulo, senão o
-- `require` resolve para ela mesma): exercita o codec do token de conexão
-- através do motor (o `bit32` e o `utf8` de verdade) e deixa cada resultado
-- numa chave de contexto. Mora fora da árvore de scripts do app pelo mesmo
-- motivo da `time.luau`: o `require` resolve por `GLACIER_LUAU_PATH`.
local AccessKey = require("access_key")

function init(): ()
    ctx.key_encoded = AccessKey.encode("http://127.0.0.1:9", "x")
    -- Sem porta na URL salva: a padrão do esquema vai no token.
    ctx.key_encoded_default_port = AccessKey.encode("https://a.b", "x")

    local round_trips: { string } = {}
    for _, url in
        {
            "https://a.b:9797",
            "http://rustploy-ms.itemize.com.br:9797",
            "http://[::1]:9797",
        }
    do
        local decoded = AccessKey.decode(AccessKey.encode(url, "tok-123_ABC"))
        table.insert(
            round_trips,
            if decoded then decoded.address .. "|" .. decoded.token else "nil"
        )
    end
    ctx.key_round_trip = table.concat(round_trips, " ")

    -- O que o Python gera (`base64.b64encode`) e o url-safe sem padding.
    local from_python = AccessKey.decode("YS5iOjk3OTc6On4/")
    ctx.key_from_python = if from_python
        then from_python.address .. "|" .. from_python.token
        else "nil"
    local url_safe = AccessKey.decode("YS5iOjk3OTc6On4_")
    ctx.key_url_safe = if url_safe
        then url_safe.address .. "|" .. url_safe.token
        else "nil"

    -- Daemon sem `[api].token`: o token de conexão termina em `::`.
    local without_token =
        AccessKey.decode(AccessKey.encode("http://localhost:9797", ""))
    ctx.key_without_token = if without_token
        then without_token.address .. "|" .. without_token.token
        else "nil"

    local _, missing_prefix = AccessKey.decode("tok-123")
    ctx.key_missing_prefix = missing_prefix or ""

    local _, corrupted = AccessKey.decode("!!!")
    ctx.key_corrupted = corrupted or ""

    ctx.key_hint = AccessKey.hint(
        "https://a.b:9797",
        AccessKey.encode("https://a.b:9797", "x")
    )
end
