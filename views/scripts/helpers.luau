--!strict
-- helpers.luau — utilitários puros compartilhados pelos handlers_*.luau (sem
-- estado, sem I/O). Cada handler faz `local Helpers = require("helpers")`.

local M = {}

function M.trim(value: any): string
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""));
end

-- Referência a secret num valor de env var → nome do secret (ou nil se o valor
-- for texto comum). Aceita as DUAS formas em que a referência aparece no
-- projeto, porque cada uma é a sintaxe natural de um lugar:
--   <secret:NOME>  — editor .env/campo valor da GUI (o que o Exportar gera)
--   secret:NOME    — manifesto YAML do IaC (SECRET_PREFIX em shared/manifest.rs)
-- Aceitar só a primeira fazia `secret:NOME` (copiado de um manifesto ou da doc
-- antiga) virar valor LITERAL calado, e o container subia com a string
-- "secret:NOME" no lugar do segredo. Um único ponto de verdade para os quatro
-- call sites (env do serviço e do projeto, editor .env e campo valor) — foi a
-- duplicação entre eles que deixou as sintaxes divergirem.
function M.parse_secret_ref(text: string?): string?
    local trimmed = M.trim(text)
    local name = trimmed:match("^<secret:(.+)>$") or trimmed:match("^secret:(.+)$")
    if name == nil then
        return nil
    end
    name = M.trim(name)
    return name ~= "" and name or nil
end

-- Parseia um blob .env em (vars, comments). Comentários ancoram na var
-- seguinte (before_key), ou nil no fim. `<secret:NAME>` volta a ser referência
-- de secret. Extraído de handlers/services.luau pra reuso em
-- new_job_window.luau (env vars próprias do job).
function M.parse_dotenv(text: string?): ({any}, {any})
    local vars = json.array{}
    local comments = json.array{}
    local pending = {}
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        local trimmed_line = M.trim(line)
        if trimmed_line == "" then
            -- ignora
        elseif trimmed_line:sub(1, 1) == "#" then
            table.insert(pending, trimmed_line)
        else
            local raw_key, raw_value = trimmed_line:match("^([^=]+)=(.*)$")
            if raw_key and raw_value then
                local key = M.trim(raw_key)
                if key ~= "" then
                    for _, comment_text in ipairs(pending) do
                        table.insert(comments, { text = comment_text, before_key = key })
                    end
                    pending = {}
                    raw_value = M.trim(raw_value)
                    local secret = M.parse_secret_ref(raw_value)
                    local value = secret and { Secret = secret } or { Plain = raw_value }
                    table.insert(vars, { key = key, value = value })
                end
            end
        end
    end
    for _, comment_text in ipairs(pending) do
        table.insert(comments, { text = comment_text, before_key = nil })
    end
    return vars, comments
end

-- URI de callback OAuth que o usuário registra no app do provedor. `base` é a
-- URL pública do daemon (`DaemonSettings.public_base_url`), derivada de [api]
-- domain/port — o callback OAuth é servido pelo mesmo listener da API. `seg` é o
-- segmento do path por provedor ("gitea" | "github"), default "gitea".
function M.oauth_redirect_uri(base: string?, provider_segment: string?): string
    local provider_slug = (provider_segment == "github") and "github" or "gitea"
    local trimmed_base = M.trim(base):gsub("/+$", "");
    if trimmed_base == "" then
        return "<URL pública do daemon indisponível>/oauth/" .. provider_slug .. "/callback";
    end
    return trimmed_base .. "/oauth/" .. provider_slug .. "/callback";
end

-- Heurística: a URL denota um repo Git (clonar+buildar) e não uma imagem.
function M.looks_like_git_url(url: string?): boolean
    local trimmed = M.trim(url);
    return trimmed:match("^https://") ~= nil or trimmed:match("^http://") ~= nil
        or trimmed:match("^git@") ~= nil or trimmed:match("^ssh://") ~= nil
        or trimmed:match("^file://") ~= nil or trimmed:match("%.git$") ~= nil
end

-- Normaliza a entrada de URL do login para uma base HTTP(S) sem barra final.
-- Aceita "https://host:porta", "http://host:porta", "host:porta", "host".
-- Sem esquema → https. Outros esquemas (ex.: ws, ftp) são rejeitados.
function M.normalize_url(raw: string): string?
    local trimmed_url = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "");
    if trimmed_url == "" then
        return nil;
    end
    local scheme, rest = string.match(trimmed_url, "^([%a][%w+.-]*)://(.*)$");
    if scheme then
        scheme = string.lower(scheme);
        if scheme ~= "http" and scheme ~= "https" then
            return nil;
        end
    else
        scheme, rest = "https", trimmed_url
    end
    -- corta path/query/fragment: só queremos o authority (host[:porta]).
    rest = string.match(rest or "", "^([^/?#]*)") or rest;
    if rest == "" then
        return nil;
    end
    return (scheme or "") .. "://" .. (rest or "");
end

return M
