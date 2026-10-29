--!strict
-- helpers.luau — utilitários puros compartilhados pelos handlers_*.luau (sem
-- estado, sem I/O). Cada handler faz `local Helpers = require("helpers")`.

local M = {}

function M.trim(value: any): string
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Referência a secret num valor de env var → nome do secret (ou nil se o valor
-- for texto comum). Aceita as DUAS formas em que a referência aparece no
-- projeto, porque cada uma é a sintaxe natural de um lugar:
--   <secret:NOME>  — editor .env/campo valor da GUI (o que o Exportar gera)
--   secret:NOME    — manifesto YAML do IaC (SECRET_PREFIX em
--                    shared/manifest.rs)
-- Aceitar só a primeira fazia `secret:NOME` (copiado de um manifesto ou da doc
-- antiga) virar valor LITERAL calado, e o container subia com a string
-- "secret:NOME" no lugar do segredo. Um único ponto de verdade para os quatro
-- call sites (env do serviço e do projeto, editor .env e campo valor) — foi a
-- duplicação entre eles que deixou as sintaxes divergirem.
function M.parse_secret_ref(text: string?): string?
    local trimmed = M.trim(text)
    local name = trimmed:match("^<secret:(.+)>$")
        or trimmed:match("^secret:(.+)$")
    if name == nil then
        return nil
    end
    name = M.trim(name)
    return name ~= "" and name or nil
end

-- Nome de env var aceito: começa com letra ou `_`; o resto são letras,
-- dígitos, `_`, `.` e `-`. Espelha platform/env_validation.rs no daemon, que é
-- quem garante de fato; aqui é só para avisar antes de enviar.
function M.valid_env_key(key: string?): boolean
    return (key or ""):match("^[%a_][%w_.%-]*$") ~= nil
end

-- Valida a chave nova antes de gravar: nome inválido avisa e aborta; chave que
-- já existe pede confirmação (gravar substitui o valor e manda a var pro fim).
-- `true` = pode seguir.
function M.confirm_env_key(key: string, existing_json: string?): boolean
    if not M.valid_env_key(key) then
        toast {
            message = 'Nome inválido: "'
                .. key
                .. '" — use letras, dígitos e _, sem começar por dígito',
            kind = "error",
        }
        return false
    end
    -- `existing_json` é a lista que a tela já exibe (ctx.service_env/project_env).
    local decode_ok, existing = pcall(json.decode, existing_json or "[]")
    for _, env_var in
        ipairs(decode_ok and type(existing) == "table" and existing or {})
    do
        if env_var.key == key then
            return confirm {
                title = "Sobrescrever variável?",
                message = key
                    .. " já existe; o valor atual será substituído.",
                confirm_label = "Sobrescrever",
                destructive = false,
            }
        end
    end
    return true
end

-- Parseia um blob .env em (vars, comments, errors). Comentários ancoram na var
-- seguinte (before_key), ou nil no fim. `<secret:NAME>` volta a ser referência
-- de secret. `errors` lista, com o número da linha, o que NÃO pôde ser lido:
-- linha sem `=`, nome inválido ou chave repetida. Quem chama decide se grava
-- mesmo assim — hoje nenhum grava com erro, senão a variável sumiria calada.
function M.parse_dotenv(text: string?): ({ any }, { any }, { string })
    local vars = json.array {}
    local comments = json.array {}
    local errors = {}
    local first_line_of = {}
    local pending = {}
    local line_number = 0
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        line_number += 1
        local trimmed_line = M.trim(line)
        if trimmed_line == "" then
            -- ignora
        elseif trimmed_line:sub(1, 1) == "#" then
            table.insert(pending, trimmed_line)
        else
            local raw_key, raw_value = trimmed_line:match("^([^=]+)=(.*)$")
            local key = raw_key and M.trim(raw_key) or ""
            if raw_key == nil or raw_value == nil then
                table.insert(
                    errors,
                    string.format(
                        "linha %d: falta o '=' (%s)",
                        line_number,
                        trimmed_line
                    )
                )
            elseif key == "" then
                table.insert(
                    errors,
                    string.format(
                        "linha %d: falta o nome antes do '='",
                        line_number
                    )
                )
            elseif not M.valid_env_key(key) then
                table.insert(
                    errors,
                    string.format(
                        'linha %d: nome inválido "%s"',
                        line_number,
                        key
                    )
                )
            elseif first_line_of[key] then
                table.insert(
                    errors,
                    string.format(
                        "linha %d: %s repetida (já definida na linha %d)",
                        line_number,
                        key,
                        first_line_of[key]
                    )
                )
            else
                first_line_of[key] = line_number
                for _, comment_text in ipairs(pending) do
                    table.insert(
                        comments,
                        { text = comment_text, before_key = key }
                    )
                end
                pending = {}
                raw_value = M.trim(raw_value)
                local secret = M.parse_secret_ref(raw_value)
                local value = secret and { Secret = secret }
                    or { Plain = raw_value }
                table.insert(vars, { key = key, value = value })
            end
        end
    end
    for _, comment_text in ipairs(pending) do
        table.insert(comments, { text = comment_text, before_key = nil })
    end
    return vars, comments, errors
end

-- Resumo de `errors` para um toast: as 3 primeiras e "+N".
function M.dotenv_errors_message(errors: { string }): string
    local shown = {}
    for index = 1, math.min(#errors, 3) do
        table.insert(shown, errors[index])
    end
    local message = table.concat(shown, "\n")
    if #errors > 3 then
        message ..= string.format("\n… e mais %d", #errors - 3)
    end
    return message
end

-- URI de callback OAuth que o usuário registra no app do provedor. `base` é a
-- URL pública do daemon (`DaemonSettings.public_base_url`), derivada de [api]
-- domain/port — o callback OAuth é servido pelo mesmo listener da API. `seg` é
-- o
-- segmento do path por provedor ("gitea" | "github"), default "gitea".
function M.oauth_redirect_uri(base: string?, provider_segment: string?): string
    local provider_slug = (provider_segment == "github") and "github"
        or "gitea"
    local trimmed_base = M.trim(base):gsub("/+$", "")
    if trimmed_base == "" then
        return "<URL pública do daemon indisponível>/oauth/"
            .. provider_slug
            .. "/callback"
    end
    return trimmed_base .. "/oauth/" .. provider_slug .. "/callback"
end

-- Heurística: a URL denota um repo Git (clonar+buildar) e não uma imagem.
function M.looks_like_git_url(url: string?): boolean
    local trimmed = M.trim(url)
    return trimmed:match("^https://") ~= nil
        or trimmed:match("^http://") ~= nil
        or trimmed:match("^git@") ~= nil
        or trimmed:match("^ssh://") ~= nil
        or trimmed:match("^file://") ~= nil
        or trimmed:match("%.git$") ~= nil
end

-- Normaliza a entrada de URL do login para uma base HTTP(S) sem barra final.
-- Aceita "https://host:porta", "http://host:porta", "host:porta", "host".
-- Sem esquema → https. Outros esquemas (ex.: ws, ftp) são rejeitados.
function M.normalize_url(raw: string): string?
    local trimmed_url = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed_url == "" then
        return nil
    end
    local scheme, rest = string.match(trimmed_url, "^([%a][%w+.-]*)://(.*)$")
    if scheme then
        scheme = string.lower(scheme)
        if scheme ~= "http" and scheme ~= "https" then
            return nil
        end
    else
        scheme, rest = "https", trimmed_url
    end
    -- corta path/query/fragment: só queremos o authority (host[:porta]).
    rest = string.match(rest or "", "^([^/?#]*)") or rest
    if rest == "" then
        return nil
    end
    return (scheme or "") .. "://" .. (rest or "")
end

-- Uma chave JSON do `ctx` pode ser a TABELA (gravada como tabela ou semeada com
-- `json.array({})`) ou o TEXTO JSON (de `json.encode`, de `open_window` `data` ou do
-- markup). `decode_list(valor)` é o substituto de `pcall(json.decode, valor or "[]")`
-- que aceita as duas formas: `(true, tabela)`, ou `(false, mensagem)` para um texto
-- que não é JSON. Ausente ou vazio é a lista vazia.
function M.decode_list(value: any): (boolean, any)
    if type(value) == "table" then
        return true, value
    end
    if value == nil or value == "" then
        return true, {}
    end
    return pcall(json.decode, value)
end

-- Um booleano do `ctx` chega como o `boolean` (um checkbox/toggle que o motor
-- grava direto, ou `ctx.x = true`) ou como o TEXTO `"true"` (o que o markup, um
-- `open_window` `data` ou `ctx.x = "true"` escreveram). Comparar só com o texto
-- erra o primeiro caso desde a glacier-ui 0.137; estas duas aceitam os dois.
function M.is_true(value: any): boolean
    return value == true or value == "true"
end

-- O par de `is_true`. Ausente não é falso: `not is_false(v)` é o "ligado por padrão".
function M.is_false(value: any): boolean
    return value == false or value == "false"
end

-- `true` se a chave JSON do `ctx` é uma lista vazia (ou não é uma lista legível).
function M.list_is_empty(value: any): boolean
    local ok, list = M.decode_list(value)
    return not ok or type(list) ~= "table" or next(list) == nil
end

return M
