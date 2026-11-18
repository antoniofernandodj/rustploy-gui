--!strict
-- recovery_kit.luau — lê o arquivo de recuperação (`.rpkit`) que o daemon gera
-- junto com a chave (Settings → Chave de recuperação) e que a tela Recuperar
-- carrega para preencher os quatro campos. O formato está descrito em
-- `rustploy-daemon/.../features/data_backup/recovery_kit.rs`; a webui tem o
-- mesmo leitor em `webui/recovery_kit.js`. Mude os três juntos.

local M = {}

local MAGIC = "\137RPKIT\r\n"
local VERSION = 1
local HEADER_LEN = 12
local MAX_FIELD = 64 * 1024

local TAG_FIELDS: { [number]: string } = {
    [1] = "infra_remote",
    [2] = "infra_branch",
    [3] = "infra_token",
    [4] = "private_key",
    [5] = "public_key",
    [6] = "server",
    [7] = "created_at",
}

export type Kit = {
    infra_remote: string,
    infra_branch: string,
    infra_token: string,
    private_key: string,
    public_key: string,
    server: string,
    created_at: string,
}

--- CRC-32 (IEEE), bit a bit — o mesmo do daemon.
function M.crc32(bytes: string): number
    local crc = 0xFFFFFFFF
    for index = 1, #bytes do
        crc = bit32.bxor(crc, string.byte(bytes, index))
        for _ = 1, 8 do
            if bit32.band(crc, 1) == 1 then
                crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
            else
                crc = bit32.rshift(crc, 1)
            end
        end
    end
    return bit32.bxor(crc, 0xFFFFFFFF)
end

--- `u16` little-endian que começa no byte `at` (1-based); `nil` se faltar.
local function u16_at(bytes: string, at: number): number?
    if at + 1 > #bytes then
        return nil
    end
    local low, high = string.byte(bytes, at, at + 1)
    return low + high * 256
end

--- `u32` little-endian que começa no byte `at` (1-based); `nil` se faltar.
local function u32_at(bytes: string, at: number): number?
    if at + 3 > #bytes then
        return nil
    end
    local b0, b1, b2, b3 = string.byte(bytes, at, at + 3)
    return b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000
end


--- Lê e confere o arquivo. Devolve o kit, ou `nil, mensagem` (a mesma
--- mensagem que o daemon daria).
function M.decode(bytes: string): (Kit?, string?)
    if #bytes < HEADER_LEN + 4 or string.sub(bytes, 2, 6) ~= "RPKIT" then
        return nil, i18n.tr("não é um arquivo de recuperação do Rustploy")
    end
    if string.sub(bytes, 1, 8) ~= MAGIC then
        return nil,
            i18n.tr(
                "o arquivo de recuperação foi alterado na cópia (modo texto "
                    .. "ou conversão de fim de linha): use o arquivo original"
            )
    end
    local body = string.sub(bytes, 1, #bytes - 4)
    local stored = u32_at(bytes, #bytes - 3)
    if stored == nil or stored ~= M.crc32(body) then
        return nil,
            i18n.tr(
                "o arquivo de recuperação está corrompido (a soma de "
                    .. "verificação não confere)"
            )
    end
    local version = u16_at(body, 9)
    if version ~= VERSION then
        return nil,
            string.format(
                i18n.tr(
                    "arquivo de recuperação da versão %s; esta versão do "
                        .. "Rustploy lê a %d"
                ),
                tostring(version),
                VERSION
            )
    end
    local count = u16_at(body, 11) or 0

    local kit: Kit = {
        infra_remote = "",
        infra_branch = "",
        infra_token = "",
        private_key = "",
        public_key = "",
        server = "",
        created_at = "",
    }
    local seen_remote = false
    local position = HEADER_LEN + 1
    for _ = 1, count do
        local tag = u16_at(body, position)
        local length = u32_at(body, position + 2)
        if tag == nil or length == nil then
            return nil, i18n.tr("o arquivo de recuperação está truncado")
        end
        if length > MAX_FIELD then
            return nil,
                i18n.tr(
                    "o arquivo de recuperação está corrompido (campo grande "
                        .. "demais)"
                )
        end
        local start = position + 6
        if start + length - 1 > #body then
            return nil, i18n.tr("o arquivo de recuperação está truncado")
        end
        local text = string.sub(body, start, start + length - 1)
        if utf8.len(text) == nil then
            return nil,
                i18n.tr(
                    "o arquivo de recuperação está corrompido (texto inválido)"
                )
        end
        local field = TAG_FIELDS[tag]
        if field ~= nil then -- etiqueta desconhecida: campo de versão futura
            (kit :: any)[field] = text
            if field == "infra_remote" then
                seen_remote = true
            end
        end
        position = start + length
    end
    if position ~= #body + 1 then
        return nil,
            i18n.tr("o arquivo de recuperação está corrompido (sobram bytes)")
    end
    if not seen_remote or kit.infra_remote == "" or kit.private_key == "" then
        return nil,
            i18n.tr(
                "o arquivo de recuperação está incompleto (falta o "
                    .. "repositório ou a chave)"
            )
    end
    return kit, nil
end

return M
