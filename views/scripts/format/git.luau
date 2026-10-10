--!strict
-- format/git.luau — builders dos provedores/repositórios/branches Git conectados
-- (Gitea/GitHub) — Settings → Git e o picker da aba General do serviço.

local Util = require("util")

-- Rótulo amigável do tipo de provedor a partir do enum do wire (GitProviderKind).
local function kind_label(kind: any): string
    if kind == "Github" then
        return "GitHub"
    elseif kind == "Gitea" then
        return "Gitea"
    end
    return tostring(kind or "Git")
end

local M = {}

function M.git_providers(providers: {any}?): string
    local rows = {}
    for _, provider in ipairs(providers or {}) do
        local login = provider.account and provider.account.login or nil
        local connected = login ~= nil
        local display: string
        local account_lbl: string
        local account_login: string
        if connected then
            display = tostring(provider.name or "") .. " (@" .. tostring(login or "") .. ")"
            account_lbl = "@" .. tostring(login or "")
            account_login = tostring(login or "")
        else
            display = tostring(provider.name or "") .. " — não conectado"
            account_lbl = "(pendente — autorize no navegador)"
            account_login = "não conectado"
        end
        local auth_mode = (provider.auth_mode == "OAuth") and "OAuth2" or "PAT"
        table.insert(rows, {
            id = provider.id,
            name = provider.name,
            kind = kind_label(provider.kind),
            display = display,
            base_url = provider.base_url,
            auth_mode = auth_mode,
            account = account_lbl,
            account_login = account_login,
            connected = connected and "true" or "false",
        })
    end
    return Util.encode_array(rows)
end

function M.git_repos(repositories: {any}?): string
    local rows = {}
    for _, repository in ipairs(repositories or {}) do
        table.insert(rows, {
            full_name = repository.full_name,
            clone_url = repository.clone_url,
            default_branch = repository.default_branch,
            private = repository.private and "private" or "public",
        })
    end
    return Util.encode_array(rows)
end

function M.git_branches(branches: {any}?): string
    local rows = {}
    for _, branch in ipairs(branches or {}) do
        table.insert(rows, { name = branch.name })
    end
    return Util.encode_array(rows)
end

return M
