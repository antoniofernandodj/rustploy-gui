--!strict

-- access_key.luau — o token de conexão: endereço do daemon + token da API numa
-- string só, para o login ter um campo.
--
-- Formato (o mesmo de `api/agent/access_key.rs` no daemon e de
-- `decodeAccessKey` na webui): base64 padrão, com padding, de
-- `host:porta::token` — igual ao `base64.b64encode(b"host:porta::token")` do
-- Python. Sem esquema: o `connect()` descobre se o servidor fala https ou
-- http. O daemon deixa o token pronto no config.toml, em
-- `[api].connection_token`. Esconde o endereço, não o criptografa — quem tem o
-- token de conexão tem o token da API. Ver
-- docs/plano-chave-de-acesso-e-mcp.md.
--
-- Luau não traz base64, daí o codificador aqui embaixo.

local M = {}

M.SEPARATOR = "::"

-- Alfabeto url-safe: é nele que o decodificador trabalha (normalizando
-- `+`/`/`).
local ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local STANDARD_ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local index_of_character: { [string]: number } = {}
for position = 1, #ALPHABET do
    index_of_character[string.sub(ALPHABET, position, position)] = position - 1
end

-- base64 padrão com padding (`=`).
local function base64_encode(input: string): string
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
            local sextet =
                bit32.band(bit32.rshift(group, 18 - (slot - 1) * 6), 63)
            table.insert(
                output,
                string.sub(STANDARD_ALPHABET, sextet + 1, sextet + 1)
            )
        end
        table.insert(output, string.rep("=", 4 - characters))
    end
    return table.concat(output)
end

-- Aceita os dois alfabetos (`+`/`/` e `-`/`_`), com ou sem `=` no fim.
local function base64_decode(input: string): string?
    local cleaned = string.gsub(
        string.gsub(string.gsub(input, "=+$", ""), "%+", "-"),
        "/",
        "_"
    )
    if #cleaned % 4 == 1 then
        return nil
    end
    local output: { string } = {}
    for start = 1, #cleaned, 4 do
        local group = 0
        local characters = 0
        for offset = 0, 3 do
            local character =
                string.sub(cleaned, start + offset, start + offset)
            if character ~= "" then
                local value = index_of_character[character]
                if value == nil then
                    return nil
                end
                group = bit32.bor(group, bit32.lshift(value, 18 - offset * 6))
                characters += 1
            end
        end
        table.insert(
            output,
            string.char(bit32.band(bit32.rshift(group, 16), 255))
        )
        if characters >= 3 then
            table.insert(
                output,
                string.char(bit32.band(bit32.rshift(group, 8), 255))
            )
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

--- `host:porta` de uma URL salva (`https://h:9797` → `h:9797`). A porta sempre
--- vai, mesmo a padrão: `https://h` → `h:443`.
function M.address_of(url: string): string
    local scheme, rest = string.match(url, "^(%a[%w+.-]*)://(.*)$")
    local authority = string.match(rest or url, "^([^/?#]*)") or url
    local after_host = string.match(authority, "%]([^%]]*)$") or authority
    if string.find(after_host, ":", 1, true) then
        return authority
    end
    return authority
        .. ":"
        .. (if scheme and string.lower(scheme) == "http" then "80" else "443")
end

--- Monta o token de conexão de um par salvo `{url, token}`.
function M.encode(url: string, token: string): string
    return base64_encode(M.address_of(url) .. M.SEPARATOR .. token)
end

--- `{ address, token }` do token de conexão (`address` = `host:porta`), ou
--- `nil` + o motivo (para o erro do campo).
function M.decode(
    raw_key: string?
): ({ address: string, token: string }?, string?)
    local key = trim(raw_key or "")
    if key == "" then
        return nil, "cole o token de conexão"
    end
    local text = base64_decode(key)
    if text == nil then
        return nil, "token de conexão corrompido (cortado ao copiar?)"
    end
    -- Bytes que não são texto, ou sem o `::`: quase sempre o token da API
    -- colado no lugar do de conexão (todo token hex/base64url também
    -- "decodifica").
    local separator_at: number? = nil
    local authority_start = 1
    if utf8.len(text) ~= nil then
        -- Um esquema posto à mão não faz parte do formato: é pulado.
        local scheme_end = string.find(text, "://", 1, true)
        authority_start = if scheme_end then scheme_end + 3 else 1
        -- O primeiro `::` fora do endereço: um IPv6 (`[::1]:9797`) tem os
        -- seus.
        local search_from = authority_start
        if string.sub(text, search_from, search_from) == "[" then
            search_from = string.find(text, "]", search_from, true)
                or (#text + 1)
        end
        separator_at = string.find(text, M.SEPARATOR, search_from, true)
    end
    if separator_at == nil then
        return nil,
            "isso não é um token de conexão — cole o token de conexão inteiro "
                .. "(base64 de host:porta::token), não só o token da API"
    end
    local address = (
        string.gsub(
            trim(string.sub(text, authority_start, separator_at - 1)),
            "/+$",
            ""
        )
    )
    local token = trim(string.sub(text, separator_at + #M.SEPARATOR))
    -- Token vazio vale: é o de um daemon sem `[api].token` (API aberta).
    if address == "" then
        return nil, "token de conexão corrompido (endereço vazio)"
    end
    return { address = address, token = token }, nil
end

--- Dica `host:porta · cnVzdH…TjQ=` de a qual servidor um token se refere. Sem
--- uso por ora: era o rótulo dos itens do `<ComboEdit>`, mas o combo mostra o
--- rótulo no próprio campo (ver `publish_saved_servers` em
--- handlers/connection.luau). Volta quando o glacier separar o texto do campo
--- do texto da lista.
function M.hint(url: string, key: string): string
    return M.address_of(url)
        .. " · "
        .. string.sub(key, 1, 6)
        .. "…"
        .. string.sub(key, -6)
end

return M
