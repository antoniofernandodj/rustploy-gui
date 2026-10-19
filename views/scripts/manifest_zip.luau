-- O `.zip` do Infra as Code: exatamente rustploy.yml + rustploy.vars.toml na
-- raiz. Sobre `zip_write`/`zip_read` do motor; o formato é do Rustploy.

-- Nomes das duas entradas que o export grava na raiz do zip.
local YML_ENTRY = "rustploy.yml"
local TOML_ENTRY = "rustploy.vars.toml"

local function write(path: string, yaml: string, toml: string): (boolean, string?)
    return zip_write(path, {
        { name = YML_ENTRY, text = yaml },
        { name = TOML_ENTRY, text = toml },
    })
end

-- Valida e lê o zip importado: exatamente um .yml/.yaml e um .toml, na raiz, e
-- nada mais. `{ ok = true, yaml, toml }` ou `{ ok = false, error }`.
local function read(path: string): any
    local zip = zip_read(path)
    if not zip.ok then
        return { ok = false, error = zip.error }
    end

    local yaml: string? = nil
    local toml: string? = nil
    local extras: { string } = {}
    for _, entry in ipairs(zip.entries or {}) do
        local lower = string.lower(entry.name)
        local is_yaml = string.sub(lower, -4) == ".yml" or string.sub(lower, -5) == ".yaml"
        local is_toml = string.sub(lower, -5) == ".toml"
        if entry.dir or string.find(entry.name, "/", 1, true) or (not is_yaml and not is_toml) then
            table.insert(extras, entry.name)
        elseif entry.text == nil then
            return { ok = false, error = entry.name .. " não é texto UTF-8 válido" }
        elseif is_yaml then
            if yaml ~= nil then
                return { ok = false, error = "o zip tem mais de um arquivo .yml" }
            end
            yaml = entry.text
        else
            if toml ~= nil then
                return { ok = false, error = "o zip tem mais de um arquivo .toml" }
            end
            toml = entry.text
        end
    end

    if #extras > 0 then
        return { ok = false, error = "o zip só pode ter um .yml e um .toml — sobrou: " .. table.concat(extras, ", ") }
    end
    if yaml == nil then
        return { ok = false, error = "o zip não tem um arquivo .yml" }
    end
    if toml == nil then
        return { ok = false, error = "o zip não tem um arquivo .toml" }
    end
    return { ok = true, yaml = yaml, toml = toml }
end

return { write = write, read = read }
