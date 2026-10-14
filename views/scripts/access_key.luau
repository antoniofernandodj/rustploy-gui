--!strict

-- access_key.luau — a chave de acesso `rpk1_…`: endereço do daemon + token
-- numa string só, para o login ter um campo.
--
-- Formato (o mesmo de `api/agent/access_key.rs` no daemon e de
-- `decodeAccessKey` na webui): `rpk1_` + base64url sem padding de
-- `{"u":"<url>","t":"<token>"}`. Esconde o endereço, não o criptografa — quem
-- tem a chave tem o token. Ver docs/plano-chave-de-acesso-e-mcp.md.
--
-- Luau não traz base64, daí o codificador aqui embaixo (o alfabeto url-safe).

local M = {}

M.PREFIX = "rpk1_"

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local index_of_character: { [string]: number } = {}
for position = 1, #ALPHABET do
    index_of_character[string.sub(ALPHABET, position, position)] = position - 1
end

local function base64url_encode(input: string): string
    local output: { string } = {}
    for start = 1, #input, 3 do
        local first, second, third = string.byte(input, start, start + 2)
        local group = bit32.bor(
            bit32.lshift(first, 16),
            bit32.lshift(second or 0, 8),
            third or 0
        )
        local characters = if third then 4 elseif second then 3 else 2
        for slot = 1, characters do
            local sextet = bit32.band(bit32.rshift(group, 18 - (slot - 1) * 6), 63)
            table.insert(output, string.sub(ALPHABET, sextet + 1, sextet + 1))
        end
    end
    return table.concat(output)
end

-- Aceita também o alfabeto padrão (`+`/`/`) e `=` no fim: a chave às vezes
-- passa por um encoder que não é o nosso no meio do caminho.
local function base64url_decode(input: string): string?
    local cleaned = string.gsub(string.gsub(string.gsub(input, "=+$", ""), "%+", "-"), "/", "_")
    if #cleaned % 4 == 1 then
        return nil
    end
    local output: { string } = {}
    for start = 1, #cleaned, 4 do
        local group = 0
        local characters = 0
        for offset = 0, 3 do
            local character = string.sub(cleaned, start + offset, start + offset)
            if character ~= "" then
                local value = index_of_character[character]
                if value == nil then
                    return nil
                end
                group = bit32.bor(group, bit32.lshift(value, 18 - offset * 6))
                characters += 1
            end
        end
        table.insert(output, string.char(bit32.band(bit32.rshift(group, 16), 255)))
        if characters >= 3 then
            table.insert(output, string.char(bit32.band(bit32.rshift(group, 8), 255)))
        end
        if characters == 4 then
            table.insert(output, string.char(bit32.band(group, 255)))
        end
    end
    return table.concat(output)
end

--- Monta a chave de um par salvo `{url, token}`.
function M.encode(url: string, token: string): string
    -- JSON montado à mão para fixar a ordem `u`, `t`: a tabela Luau não tem
    -- ordem, e assim a chave sai byte a byte igual à do daemon e da webui —
    -- a mesma credencial vira a mesma string em qualquer cliente.
    return M.PREFIX .. base64url_encode('{"u":' .. json.encode(url) .. ',"t":' .. json.encode(token) .. "}")
end

--- `{ url, token }` da chave, ou `nil` + o motivo (para o erro do campo).
function M.decode(raw_key: string?): ({ url: string, token: string }?, string?)
    local key = string.gsub(string.gsub(raw_key or "", "^%s+", ""), "%s+$", "")
    if key == "" then
        return nil, "cole a chave de acesso"
    end
    if string.sub(key, 1, #M.PREFIX) ~= M.PREFIX then
        return nil, "a chave começa com " .. M.PREFIX .. " — cole a chave inteira, não só o token"
    end
    local decoded_text = base64url_decode(string.sub(key, #M.PREFIX + 1))
    if decoded_text == nil then
        return nil, "chave corrompida (cortada ao copiar?)"
    end
    local decode_ok, decoded = pcall(json.decode, decoded_text)
    if not decode_ok or type(decoded) ~= "table" or type(decoded.u) ~= "string" or type(decoded.t) ~= "string" or decoded.u == "" or decoded.t == "" then
        return nil, "chave corrompida (conteúdo inesperado)"
    end
    return { url = decoded.u, token = decoded.t }, nil
end

--- Rótulo do item na lista de servidores lembrados: `host:porta  rpk1_eyJ1…Ijo9`.
--- O endereço fica visível só aqui, como dica de a qual servidor a chave se
--- refere; o campo em si carrega a chave.
function M.hint(url: string, key: string): string
    local authority = string.match(url, "^%a[%w+.-]*://([^/?#]+)") or url
    return authority .. "   " .. string.sub(key, 1, 10) .. "…" .. string.sub(key, -4)
end

return M
