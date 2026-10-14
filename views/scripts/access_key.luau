--!strict

-- access_key.luau — a chave de acesso: endereço do daemon + token numa string
-- só, para o login ter um campo.
--
-- Formato (o mesmo de `api/agent/access_key.rs` no daemon e de
-- `decodeAccessKey` na webui): base64url sem padding de `host:porta::token`.
-- O esquema só vai na chave quando não dá para deduzi-lo — porta 443 (ou
-- nenhuma) é https, qualquer outra é http; fora disso a chave leva
-- `https://host:9797::token`. Esconde o endereço, não o criptografa — quem
-- tem a chave tem o token. Ver docs/plano-chave-de-acesso-e-mcp.md.
--
-- Luau não traz base64, daí o codificador aqui embaixo (o alfabeto url-safe).

local M = {}

M.SEPARATOR = "::"

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

local function trim(text: string): string
    return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

-- Esquema deduzido de um endereço sem esquema: só a porta 443 (ou nenhuma
-- porta) é https. Num IPv6 (`[::1]:9797`) a porta é o que vem depois do `]`.
local function implied_scheme(authority: string): string
    local after_host = string.match(authority, "%]([^%]]*)$") or authority
    local port = string.match(after_host, ":([^:]*)$")
    return if port ~= nil and port ~= "443" then "http" else "https"
end

--- Monta a chave de um par salvo `{url, token}`.
function M.encode(url: string, token: string): string
    local trimmed_url = (string.gsub(url, "/+$", ""))
    local scheme, authority = string.match(trimmed_url, "^(%a[%w+.-]*)://(.*)$")
    local address = if scheme ~= nil and authority ~= nil and implied_scheme(authority) == scheme
        then authority
        else trimmed_url
    return base64url_encode(address .. M.SEPARATOR .. token)
end

--- `{ url, token }` da chave, ou `nil` + o motivo (para o erro do campo).
function M.decode(raw_key: string?): ({ url: string, token: string }?, string?)
    local key = trim(raw_key or "")
    if key == "" then
        return nil, "cole a chave de acesso"
    end
    local text = base64url_decode(key)
    if text == nil then
        return nil, "chave corrompida (cortada ao copiar?)"
    end
    -- Bytes que não são texto, ou sem o `::`: quase sempre um token cru colado
    -- no lugar da chave (todo token hex/base64url também "decodifica").
    local separator_at: number? = nil
    if utf8.len(text) ~= nil then
        -- O primeiro `::` fora do endereço: um IPv6 (`[::1]:9797`) tem os seus.
        local scheme_end = string.find(text, "://", 1, true)
        local search_from = if scheme_end then scheme_end + 3 else 1
        if string.sub(text, search_from, search_from) == "[" then
            search_from = string.find(text, "]", search_from, true) or (#text + 1)
        end
        separator_at = string.find(text, M.SEPARATOR, search_from, true)
    end
    if separator_at == nil then
        return nil, "isso não é uma chave de acesso — cole a chave inteira, não só o token"
    end
    local address = (string.gsub(trim(string.sub(text, 1, separator_at - 1)), "/+$", ""))
    local token = trim(string.sub(text, separator_at + #M.SEPARATOR))
    if address == "" or token == "" then
        return nil, "chave corrompida (endereço ou token vazio)"
    end
    local url = if string.find(address, "://", 1, true) then address else implied_scheme(address) .. "://" .. address
    return { url = url, token = token }, nil
end

--- Rótulo do item na lista de servidores lembrados: `host:porta · cnVzdH…OnRvaw`.
--- O endereço fica visível só aqui, como dica de a qual servidor a chave se
--- refere; o campo em si carrega a chave.
function M.hint(url: string, key: string): string
    local authority = string.match(url, "^%a[%w+.-]*://([^/?#]+)") or url
    return authority .. " · " .. string.sub(key, 1, 6) .. "…" .. string.sub(key, -6)
end

return M
