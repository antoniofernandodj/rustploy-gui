--!strict
-- format/registry.luau — formata repositórios/tags do registry OCI embutido pra
-- exibição na sub-aba Docker > Registry.

local Time = require("time")
local Util = require("util")

local M = {}

-- Lista de repositórios (filtrada pela busca global, como docker_images etc.).
function M.repos(repositories: {any}?, term: string?): string
    local rows = {}
    for _, repository in ipairs(repositories or {}) do
        if Util.matches(term, { repository.name }) then
            table.insert(rows, {
                name = repository.name,
                tag_count = tostring(repository.tag_count or 0),
                size = Time.format_bytes(repository.size_bytes or 0),
                created = Time.date_day_month_hour_minute(repository.created_at),
            })
        end
    end
    return Util.encode_array(rows)
end

-- Tags de UM repositório (sem filtro de busca — lista pequena, buscada sob
-- demanda ao abrir o repositório, não vem no snapshot periódico).
function M.tags(tags: {any}?): string
    local rows = {}
    for _, tag in ipairs(tags or {}) do
        table.insert(rows, {
            tag = tag.tag,
            digest = string.sub(tag.digest, 1, 12),
            digest_full = tag.digest,
            media_type = tag.media_type,
            size = Time.format_bytes(tag.size_bytes or 0),
            updated = Time.date_day_month_hour_minute(tag.updated_at),
        })
    end
    return Util.encode_array(rows)
end

-- Tokens de acesso (Basic auth) — sem filtro de busca (lista tipicamente
-- pequena, buscada uma vez ao abrir a sub-aba, não vem no snapshot).
function M.tokens(tokens: {any}?): string
    local rows = {}
    for _, token in ipairs(tokens or {}) do
        table.insert(rows, {
            name = token.name,
            scope = token.scope,
            created = Time.date_day_month_hour_minute(token.created_at),
            last_used = token.last_used_at and Time.date_day_month_hour_minute(token.last_used_at) or "nunca",
        })
    end
    return Util.encode_array(rows)
end

return M
