--!strict
-- Fixture do teste `access_key.rs` (nome diferente do módulo, senão o
-- `require` resolve para ela mesma): exercita o codec da chave `rpk1_…` através
-- do motor (o `json` e o `bit32` de verdade) e deixa cada resultado numa chave
-- de contexto. Mora fora da árvore de scripts do app pelo mesmo motivo da
-- `time.luau`: o `require` resolve por `GLACIER_LUAU_PATH`.
local AccessKey = require("access_key")

function init(): ()
    ctx.key_encoded = AccessKey.encode("http://127.0.0.1:9", "x")

    local round_trip = AccessKey.decode(AccessKey.encode("https://a.b:9797", "tok-123_ABC"))
    ctx.key_round_trip = if round_trip then round_trip.url .. "|" .. round_trip.token else "nil"

    local _, missing_prefix = AccessKey.decode("tok-123")
    ctx.key_missing_prefix = missing_prefix or ""

    local _, corrupted = AccessKey.decode("rpk1_!!!")
    ctx.key_corrupted = corrupted or ""

    ctx.key_hint = AccessKey.hint("https://a.b:9797", AccessKey.encode("https://a.b:9797", "x"))
end
