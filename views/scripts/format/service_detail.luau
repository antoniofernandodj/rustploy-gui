--!strict
-- format/service_detail.luau — builders da tela de detalhe de serviço (source,
-- healthcheck, env vars, logs, deployments, domains, connection URLs).
-- Equivalente às partes de view.rs usadas por services.rs.

local Types = require("types")
type EnvVar = Types.EnvVar
type EnvComment = Types.EnvComment
type ServiceSpec = Types.ServiceSpec

local Time = require("time")
local Util = require("util")

local M = {}

-- Lista de containers do serviço (id + nome + estado) → linhas para a UI de
-- detalhe. `list` = Vec<ManagedContainer> anexado ao serviço no snapshot.
function M.containers(containers: { Types.ManagedContainer }?): string
    local rows = {}
    for _, container in ipairs(containers or {}) do
        local color = "#8B949E"
        if container.state == "running" then
            color = "#3FB950"
        elseif
            container.state == "restarting"
            or container.state == "created"
            or container.state == "paused"
        then
            color = "#D29922"
        end
        table.insert(rows, {
            id = container.id or "",
            id_short = string.sub(container.id or "", 1, 12),
            name = container.name or "—",
            state = container.state or "—",
            state_color = color,
        })
    end
    return Util.encode_array(rows)
end

local function is_terminal(state: string?): boolean
    return state == "Live"
        or state == "Stopped"
        or state == "Failed"
        or state == "Pruning"
end

-- ServiceSource → (kind, detail, build_engine) — source_summary().
function M.source_summary_parts(source: any): (string, string, string)
    if type(source) ~= "table" then
        return "—", "—", "—"
    end
    if source.Registry then
        return "Registry", source.Registry.image or "—", "—"
    elseif source.Git then
        local git_source = source.Git
        return "Git",
            (git_source.url or "") .. " @ " .. (git_source.branch or ""),
            git_source.dockerfile_path or "Dockerfile"
    elseif source.Archive then
        local archive_source = source.Archive
        return "Zip",
            archive_source.original_filename
                or archive_source.archive_id
                or i18n.tr("zip enviado"),
            archive_source.dockerfile_path or "Dockerfile"
    elseif source.Compose then
        return "Compose", "docker-compose", "Compose"
    end
    return "—", "—", "—"
end

-- Resumo de uma linha do healthcheck.
function M.healthcheck_summary(healthcheck: any): string
    local healthcheck_kind = healthcheck.kind
    local kind: string
    if type(healthcheck_kind) == "table" and healthcheck_kind.Http then
        kind = "HTTP "
            .. (healthcheck_kind.Http.path or "")
            .. " → "
            .. tostring(healthcheck_kind.Http.expected_status)
    elseif healthcheck_kind == "None" then
        return "disabled"
    elseif healthcheck_kind == "Tcp" then
        kind = "TCP"
    elseif healthcheck_kind == "DockerNative" then
        kind = "Docker"
    else
        kind = tostring(healthcheck_kind)
    end
    return string.format(
        "%s · every %ss · timeout %ss · %s retries",
        kind,
        tostring(healthcheck.interval_secs),
        tostring(healthcheck.timeout_secs),
        tostring(healthcheck.retries)
    )
end

-- Nome máximo (em caracteres) de uma chave de env var na lista da UI — nomes
-- maiores truncam com "…" (só na exibição; `key` continua completo e é o que
-- os botões ✕/drag e o .env usam de verdade).
local ENV_KEY_MAX = 30

-- Uma linha de var de ambiente (secret exibido por referência).
--
-- O cadeado não é enfeite: sem ele, uma referência `Secret("t")` e um valor
-- literal `Plain("secret:t")` renderizavam EXATAMENTE igual ("secret:t"), e
-- não havia como saber, olhando a lista, se o container ia receber o segredo
-- ou a string crua — que é o sintoma de quem errou a sintaxe da referência.
local function env_var_row(env_var: EnvVar)
    local value: string
    local kind: string
    local secret_name = ""
    if env_var.value and env_var.value.Secret ~= nil then
        secret_name = env_var.value.Secret :: string
        value, kind = "🔒 secret:" .. secret_name, "secret"
    else
        value, kind = (env_var.value and env_var.value.Plain) or "", "plain"
    end
    return {
        key = env_var.key,
        -- Ids da edição no lugar (`ctx.env_edit_id`): a linha compara o seu com o do contexto.
        edit_key_id = "key:" .. env_var.key,
        edit_value_id = "value:" .. env_var.key,
        key_display = Util.ellipsis(env_var.key, ENV_KEY_MAX),
        value = value,
        kind = kind,
        -- Nome do secret que a variável referencia ("" se for em claro): o botão 🔓 usa.
        secret_name = secret_name,
    }
end

-- Secrets do projeto como linhas JSON. Só nomes: o daemon nunca devolve o
-- valor (o snapshot traz `projects[].secrets` como lista de strings), então a
-- UI é write-only — cria/sobrescreve e apaga, sem nunca exibir o conteúdo.
function M.secret_rows(
    names: { string }?,
    scope: string?,
    revealed: { [string]: string }?
): string
    local rows = {}
    for _, name in ipairs(names or {}) do
        -- `ref` identifica o secret no mapa de revelados ("projeto" ou o id do serviço, e o nome).
        local ref = (scope or "project") .. ":" .. name
        local value = revealed and revealed[ref]
        table.insert(rows, {
            name = name,
            name_display = Util.ellipsis(name, ENV_KEY_MAX),
            ref = ref,
            revealed = value ~= nil and "true" or "false",
            value = value or "",
        })
    end
    return Util.encode_array(rows)
end

-- Dependências do serviço (`spec.depends_on`: ids de serviços do MESMO projeto) como linhas
-- {id, name, index}. Um id que não resolve mais aparece como "(serviço removido…)", para dar para
-- tirá-lo pela própria tela.
function M.dependency_rows(spec: any, services: { any }?): string
    local name_by_id = {}
    for _, service in ipairs(services or {}) do
        name_by_id[service.id] = service.spec and service.spec.name or service.id
    end
    local rows = {}
    for position, dependency_id in ipairs(spec.depends_on or {}) do
        table.insert(rows, {
            id = dependency_id,
            name = name_by_id[dependency_id]
                or (i18n.tr("(serviço removido: ") .. tostring(dependency_id) .. ")"),
            index = tostring(position),
        })
    end
    return Util.encode_array(rows)
end

-- Serviços do projeto que ainda podem virar dependência: não o próprio, e nenhum que já esteja na lista.
function M.dependency_options(spec: any, self_id: string, services: { any }?): string
    local already = {}
    for _, dependency_id in ipairs(spec.depends_on or {}) do
        already[dependency_id] = true
    end
    local rows = {}
    for _, service in ipairs(services or {}) do
        if service.id ~= self_id and not already[service.id] then
            table.insert(rows, {
                id = service.id,
                name = service.spec and service.spec.name or service.id,
            })
        end
    end
    return Util.encode_array(rows)
end

-- Env vars como linhas JSON, re-interleaving os comentários `# ...` ancorados
-- (linha `__c<idx>`, idx = índice 0-based em env_comments).
function M.env_json_with_comments(
    vars: { EnvVar }?,
    comments: { EnvComment }?
): string
    local active_vars = vars or {}
    local active_comments = comments or {}
    local rows = {}
    for _, active_var in ipairs(active_vars) do
        for index, active_comment in ipairs(active_comments) do
            if active_comment.before_key == active_var.key then
                table.insert(rows, {
                    key = "__c" .. (index - 1),
                    value = active_comment.text,
                    kind = "comment",
                })
            end
        end
        table.insert(rows, env_var_row(active_var))
    end
    for index, active_comment in ipairs(active_comments) do
        if active_comment.before_key == nil then
            table.insert(rows, {
                key = "__c" .. (index - 1),
                value = active_comment.text,
                kind = "comment",
            })
        end
    end
    return Util.encode_array(rows)
end

-- Env vars como blob `.env` (KEY=VALUE, secrets por referência), com
-- comentários.
function M.env_dotenv_with_comments(
    vars: { EnvVar }?,
    comments: { EnvComment }?
): string
    local active_vars = vars or {}
    local active_comments = comments or {}
    local lines: { string } = {}
    for _, active_var in ipairs(active_vars) do
        for _, active_comment in ipairs(active_comments) do
            if active_comment.before_key == active_var.key then
                table.insert(lines, active_comment.text)
            end
        end
        local display_value: string
        if active_var.value and active_var.value.Secret ~= nil then
            display_value = "<secret:"
                .. (active_var.value.Secret :: string)
                .. ">"
        else
            display_value = (active_var.value and active_var.value.Plain) or ""
        end
        table.insert(lines, tostring(active_var.key) .. "=" .. display_value)
    end
    for _, active_comment in ipairs(active_comments) do
        if active_comment.before_key == nil then
            table.insert(lines, active_comment.text)
        end
    end
    return table.concat(lines, "\n")
end

-- Nº máx. de linhas materializadas no `for-each` de log. O `<for-each>` do
-- glacier não é virtualizado: cada linha vira widgets reconstruídos a CADA
-- re-render (por evento de log). Um build log histórico com milhares de linhas
-- reconstruído por evento congela a UI, então o for-each mostra só a cauda; o
-- texto completo continua em join_log_lines (aba Logs "Copiar tudo" / textão).
local RENDER_ROWS = 500
-- Teto de comprimento por linha (defensivo contra linhas absurdas que sozinhas
-- estouram o text-shaping). O texto de "Copiar tudo" preserva a linha inteira.
local LINE_MAX = 2000

-- Linhas de log (LogEntry/BuildLogLine: {stream, line, timestamp}) coloridas,
-- limpas de ANSI e limitadas à cauda (RENDER_ROWS) p/ o custo de render ficar
-- limitado independentemente do tamanho do histórico.
local function log_rows(log_entries: { any }?): string
    local src = log_entries or {}
    local start = math.max(1, #src - RENDER_ROWS + 1)
    local rows = {}
    for index = start, #src do
        local log_entry = src[index]
        local color = (log_entry.stream == "Stderr") and "#F85149" or "#9DA7B3"
        local line = Util.ellipsis(Util.strip_ansi(log_entry.line), LINE_MAX)
        table.insert(rows, {
            time = Time.time_hms(log_entry.timestamp),
            line = line,
            color = color,
        })
    end
    return Util.encode_array(rows)
end
M.logs_json = log_rows
M.build_logs_json = log_rows

-- Junta linhas de log num blob de texto ("HH:MM:SS line") p/ o
-- TextArea/copiar. Sem ANSI (mas sem cap de linhas: é o conteúdo completo p/
-- copiar).
function M.join_log_lines(log_entries: { any }?, with_date: boolean?): string
    local out: { string } = {}
    for _, log_entry in ipairs(log_entries or {}) do
        local stamp = with_date and Time.date_time_full(log_entry.timestamp)
            or Time.time_hms(log_entry.timestamp)
        table.insert(out, stamp .. " " .. Util.strip_ansi(log_entry.line))
    end
    return table.concat(out, "\n")
end

-- Cor do desfecho do deploy de uma execução (lista "Execuções anteriores").
local function execution_outcome(outcome: string?): (string, string)
    local state = outcome or ""
    if state == "Failed" or state == "RollingBack" then
        return i18n.tr("Falhou"), "#F85149"
    elseif state == "Stopped" or state == "Pruning" then
        return i18n.tr("Substituída"), "#8B949E"
    elseif state == "Live" then
        return i18n.tr("Ativa"), "#3FB950"
    elseif state ~= "" then
        return state, "#8B949E"
    end
    return i18n.tr("sem deploy associado"), "#8B949E"
end

-- `LogsExecutions` → linhas da lista "Execuções anteriores" da aba Logs. `selected` = chaves
-- marcadas para "Limpar selecionados". O texto do resumo já vem montado (a lista só mostra).
function M.log_execution_rows(
    executions: { any }?,
    selected: { [string]: boolean }?
): { any }
    local rows: { any } = {}
    for _, execution in ipairs(executions or {}) do
        local key = tostring((execution.container_ids or {})[1] or "")
        local label, color = execution_outcome(execution.outcome)
        local parts: { string } = {}
        if execution.deployment_id and execution.deployment_id ~= "" then
            table.insert(parts, tostring(execution.deployment_id))
        end
        if execution.image and execution.image ~= "" then
            table.insert(parts, tostring(execution.image))
        end
        table.insert(
            parts,
            tostring(execution.lines or 0) .. i18n.tr(" linhas")
        )
        table.insert(parts, Time.format_bytes(execution.bytes or 0))
        local is_selected = selected ~= nil and selected[key] == true
        table.insert(rows, {
            key = key,
            range = Time.date_time_full(execution.started_at)
                .. " → "
                .. Time.date_time_full(execution.ended_at),
            summary = table.concat(parts, " · "),
            outcome_label = label,
            outcome_color = color,
            partial = execution.partial == true and i18n.tr("parcial") or "",
            bytes = execution.bytes or 0,
            mark = is_selected and "☑" or "☐",
            selected = is_selected,
        })
    end
    return rows
end

-- Linhas do log GUARDADO (`LogsHistory`: {timestamp, container_id, stream, line}, em ordem
-- cronológica) → linhas da janela de logs, com um separador onde o container muda (o histórico
-- atravessa deploys). `previous_container` = container da linha que vem logo antes (ao juntar com o
-- que já está na tela); devolve também o container da última linha.
function M.history_rows(
    entries: { any }?,
    previous_container: string?
): ({ any }, string)
    local rows: { any } = {}
    local current = previous_container or ""
    for _, entry in ipairs(entries or {}) do
        local container = string.sub(tostring(entry.container_id or ""), 1, 12)
        if container ~= "" and current ~= "" and container ~= current then
            table.insert(rows, {
                stream = "Stdout",
                line = i18n.tr("— outro container: ") .. container .. " —",
                timestamp = entry.timestamp,
            })
        end
        if container ~= "" then
            current = container
        end
        table.insert(rows, {
            stream = entry.stream,
            line = entry.line,
            timestamp = entry.timestamp,
            container = container,
        })
    end
    return rows, current
end

-- Histórico de deployments de um serviço (aba Deployments).
function M.deployments_detail(deployments: { any }?): string
    local rows = {}
    for _, deployment in ipairs(deployments or {}) do
        local label = Util.state_label_color(deployment.state)
        table.insert(rows, {
            id = string.sub(deployment.id, 1, 12),
            id_full = deployment.id,
            image = deployment.image,
            state_label = label,
            state_kind = Util.state_kind(deployment.state),
            duration = Time.format_duration(deployment),
            start = Time.date_day_month_hour_minute_second(
                deployment.started_at
            ),
            can_delete = is_terminal(deployment.state) and "1" or "0",
        })
    end
    return Util.encode_array(rows)
end

-- Rotas HTTP de um spec (aba Domains).
function M.domains_json(spec: ServiceSpec): string
    local rows = {}
    for _, route in ipairs(Util.domain_routes(spec)) do
        local route_port = route.port or spec.port
        table.insert(rows, {
            domain = route.domain,
            port = tostring(route_port),
            tls = route.tls and "true" or "false",
            tls_label = route.tls and "TLS" or "—",
        })
    end
    return Util.encode_array(rows)
end

-- normalize_name: minúsculas, não-alfanumérico → '_' (colapsado), trim '_'.
function M.safe_name(name: string): string
    local out: { string } = {}
    local last_dash = true
    for index = 1, #name do
        local character = string.sub(name, index, index)
        if string.match(character, "%w") then
            table.insert(out, string.lower(character))
            last_dash = false
        elseif not last_dash then
            table.insert(out, "_")
            last_dash = true
        end
    end
    local slug = table.concat(out)
    return (slug:gsub("^_+", ""):gsub("_+$", ""))
end

local function internal_scheme(product: string?): string?
    local normalized_kind = product and string.lower(product) or nil
    if normalized_kind == "postgres" or normalized_kind == "postgresql" then
        return "postgresql"
    elseif normalized_kind == "mysql" or normalized_kind == "mariadb" then
        return "mysql"
    elseif normalized_kind == "redis" then
        return "redis"
    elseif normalized_kind == "mongodb" or normalized_kind == "mongo" then
        return "mongodb"
    elseif normalized_kind == "rabbitmq" then
        return "amqp"
    elseif normalized_kind == "nats" then
        return "nats"
    elseif normalized_kind == "kafka" then
        return nil
    else
        return "http"
    end
end

-- Chave do serviço que recebe o tráfego dentro de um compose:
-- `ingress_service` se declarado, senão a primeira chave de `services:`. É o
-- nome que resolve na rede do projeto (alias do Compose) e **não muda** quando
-- o serviço do rustploy é renomeado — o YAML continua o mesmo.
function M.compose_host(content: string?, ingress_service: string?): string?
    if ingress_service and ingress_service ~= "" then
        return ingress_service
    end
    local in_services = false
    for line in string.gmatch((content or "") .. "\n", "([^\n]*)\n") do
        if not in_services then
            if string.match(line, "^services:%s*$") then
                in_services = true
            end
        else
            local key = string.match(line, "^%s+([%w_%.%-]+):")
            if key then
                return key
            end
            -- linha em branco ou comentário: segue; qualquer outra coisa sem
            -- recuo encerra o bloco `services:`.
            if
                not string.match(line, "^%s*$")
                and not string.match(line, "^%s*#")
            then
                return nil
            end
        end
    end
    return nil
end

-- `compose_host`: host do compose (ver `compose_host`) — para serviço Compose
-- o hostname interno é a chave do YAML, não `rp_<nome>`.
function M.internal_url(
    product: string?,
    safe: string,
    port: any,
    compose_host: string?
): string
    local host = (compose_host or ("rp_" .. safe)) .. ":" .. tostring(port)
    local scheme = internal_scheme(product)
    if scheme then
        return scheme .. "://" .. host
    end
    return host
end

-- Extrai só o host (sem esquema/porta) de uma api_url tipo
-- "https://1.2.3.4:8443".
local function url_host(api_url: string?): string?
    local normalized_url = api_url and api_url:gsub("%s", "") or ""
    if normalized_url == "" then
        return nil
    end
    local rest = string.match(normalized_url, "^[%a][%w+.-]*://(.*)$")
        or normalized_url
    local host = string.match(rest, "^([^:/]+)")
    return host and host ~= "" and host or nil
end

-- Valor Plain de uma env var pela chave (secrets/ausentes → nil).
local function env_plain(vars: { EnvVar }?, key: string): string?
    for _, variable in ipairs(vars or {}) do
        if
            variable.key == key
            and variable.value
            and variable.value.Plain ~= nil
            and variable.value.Plain ~= ""
        then
            return variable.value.Plain
        end
    end
    return nil
end

-- Credenciais (database/user/password) de um serviço de banco/broker, lidas
-- das env vars nas mesmas convenções que o wizard grava (ver shared::wizard).
-- Retorna nil em cada campo que não se aplica ao product.
local function database_credentials(
    product: string?,
    vars: { EnvVar }?
): (string?, string?, string?)
    local normalized_kind = product and string.lower(product) or nil
    if normalized_kind == "postgres" or normalized_kind == "postgresql" then
        return env_plain(vars, "POSTGRES_DB"),
            env_plain(vars, "POSTGRES_USER"),
            env_plain(vars, "POSTGRES_PASSWORD")
    elseif normalized_kind == "mysql" or normalized_kind == "mariadb" then
        return env_plain(vars, "MYSQL_DATABASE"),
            env_plain(vars, "MYSQL_USER"),
            env_plain(vars, "MYSQL_PASSWORD")
    elseif normalized_kind == "mongodb" or normalized_kind == "mongo" then
        return nil,
            env_plain(vars, "MONGO_INITDB_ROOT_USERNAME"),
            env_plain(vars, "MONGO_INITDB_ROOT_PASSWORD")
    elseif normalized_kind == "redis" then
        return nil, nil, env_plain(vars, "REDIS_PASSWORD")
    elseif normalized_kind == "rabbitmq" then
        return nil,
            env_plain(vars, "RABBITMQ_DEFAULT_USER"),
            env_plain(vars, "RABBITMQ_DEFAULT_PASS")
    end
    return nil, nil, nil
end

-- Anexa `/database?user=…&password=…` a uma URL de banco, no formato pedido
-- (query-params, ex.: postgresql://host:5432/app?user=app&password=…).
-- Só inclui os campos presentes; sem credenciais, retorna a base intacta.
local function with_database_credentials(
    base: string,
    database: string?,
    user: string?,
    password: string?
): string
    local url = base
    if database and database ~= "" then
        url = url .. "/" .. database
    end
    local params: { string } = {}
    if user and user ~= "" then
        table.insert(params, "user=" .. user)
    end
    if password and password ~= "" then
        table.insert(params, "password=" .. password)
    end
    if #params > 0 then
        url = url .. "?" .. table.concat(params, "&")
    end
    return url
end

-- Percent-encode de um componente de userinfo (user/password) — protege chars
-- estruturais do URI (`@`, `:`, `/`, `?`, `#`, …). Senhas do wizard usam
-- base64 url-safe (só passa reto), mas senhas custom podem ter reservados.
local function percent_encode(text: string): string
    return (
        text:gsub("[^%w%-._~]", function(character: string): string
            return string.format("%%%02X", string.byte(character))
        end)
    )
end

-- Monta a parte de userinfo `user:pass@` de uma URI RFC 3986. Casos:
--   user+pass → "user:pass@"  |  só pass (ex.: Redis) → ":pass@"
--   só user   → "user@"       |  nenhum → "" (sem `@`)
local function userinfo(user: string?, password: string?): string
    local encoded_user = (user and user ~= "") and percent_encode(user) or ""
    local encoded_password = (password and password ~= "")
            and percent_encode(password)
        or ""
    if encoded_user == "" and encoded_password == "" then
        return ""
    end
    if encoded_password == "" then
        return encoded_user .. "@"
    end
    return encoded_user .. ":" .. encoded_password .. "@"
end

-- Esquema de URI externo por banco (userinfo). Difere do `internal_scheme` em
-- dois pontos: MariaDB ganha `mariadb://` próprio (mais preciso que
-- `mysql://`), e Postgres NÃO entra aqui (é tratado à parte como string JDBC).
-- `nil` = sem esquema de banco (Kafka/serviço comum) → passthrough TCP puro
-- `host:porta`.
local function external_scheme(database_kind: string?): string?
    if database_kind == "mysql" then
        return "mysql"
    elseif database_kind == "mariadb" then
        return "mariadb"
    elseif database_kind == "redis" then
        return "redis"
    elseif database_kind == "mongodb" or database_kind == "mongo" then
        return "mongodb"
    elseif database_kind == "rabbitmq" then
        return "amqp"
    elseif database_kind == "nats" then
        return "nats"
    end
    return nil
end

-- URL de conexão externa por tipo de banco, sobre o host:porta do daemon.
--   • Postgres → string JDBC
--     (jdbc:postgresql://host:porta/db?user=&password=), reaproveitando
--     `with_database_credentials` (formato que os drivers JDBC/libpq aceitam
--     — confirmado em uso).
--   • Demais → URI padrão RFC com credenciais no userinfo
--     (scheme://user:pass@host:porta/db). Redis omite user (":pass@");
--     Mongo põe barra final + `?authSource=admin` (o root do MONGO_INITDB
--     mora no admin).
--   • Sem esquema de banco (Kafka/serviço comum) → só `host:porta`.
local function database_connection_url(
    product: string?,
    host: string,
    port: string,
    database: string?,
    user: string?,
    password: string?
): string
    local normalized_kind = product and string.lower(product) or nil
    local host_and_port = host .. ":" .. port

    if normalized_kind == "postgres" or normalized_kind == "postgresql" then
        return "jdbc:"
            .. with_database_credentials(
                "postgresql://" .. host_and_port,
                database,
                user,
                password
            )
    end

    local scheme = external_scheme(normalized_kind)
    if not scheme then
        return host_and_port
    end

    local url = scheme .. "://" .. userinfo(user, password) .. host_and_port
    if database and database ~= "" then
        url = url .. "/" .. database
    elseif normalized_kind == "mongodb" or normalized_kind == "mongo" then
        url = url .. "/"
    end
    if
        (normalized_kind == "mongodb" or normalized_kind == "mongo")
        and user
        and user ~= ""
    then
        url = url .. "?authSource=admin"
    end
    return url
end

-- Domínio HTTP tem prioridade (rota de ingress); na ausência dele, cai para o
-- passthrough TCP (`host_port`) usando o host do daemon (`api_url` da sessão)
-- e a URL de conexão idiomática do `product` (ver `database_connection_url`),
-- com database
-- + credenciais lidas das env vars.
function M.external_url(
    domain: string?,
    tls: boolean,
    host_port: any,
    product: string?,
    api_url: string?,
    env_vars: { EnvVar }?
): string
    local database, user, password = database_credentials(product, env_vars)
    if domain and domain:gsub("%s", "") ~= "" then
        local clean_domain = domain:gsub("/+$", "")
        return (tls and "https" or "http") .. "://" .. clean_domain
    end
    if host_port and tostring(host_port) ~= "" then
        local host = url_host(api_url) or "<host>"
        return database_connection_url(
            product,
            host,
            tostring(host_port),
            database,
            user,
            password
        )
    end
    return "—"
end

return M
