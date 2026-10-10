--!strict
-- fmt/time.luau — timestamps e durações.
--
-- Os timestamps chegam do daemon em RFC 3339 UTC ("2026-07-06T12:34:56Z") e a
-- tela mostra hora local. Desde a glacier-ui 0.73 essa tradução é do motor: o
-- global `date` aceita o formato com fuso, `to_local` desloca o instante e
-- `format` desenha — então o que sobra aqui é só a escolha do formato de
-- exibição, uma linha por função.
--
-- Antes disto o arquivo tinha um `iso_to_epoch` próprio e um `TZ_OFFSET`
-- calculado com `os.difftime(now, os.time(os.date("!*t", now)))`. Esse offset
-- era SEMPRE ZERO, e vale registrar por quê: o `os.time` do Luau usa `timegm`,
-- e não o `mktime` do Lua, então uma tabela de componentes é lida como UTC e
-- `os.time(os.date("!*t", t))` devolve o próprio `t`. A soma era inofensiva
-- (quem convertia para local era o `os.date` seguinte), mas o comentário
-- descrevia uma conta que não acontecia. O equivalente correto no dialeto é
-- `os.time(os.date("*t", t)) - t`, e é o que o `date` do motor usa por dentro.

local M = {}

-- As três funções abaixo aceitam `nil` e devolvem "": um `finished_at` ainda
-- não preenchido, ou um campo que o daemon omitiu, é o caso normal e não
-- deveria obrigar cada chamador a testar. `date.to_local` e `date.format`
-- propagam o nil sozinhos, então basta o `or ""` no fim.

-- HH:MM:SS local de um timestamp do daemon.
function M.time_hms(iso_timestamp: string?): string
    return date.format(date.to_local(iso_timestamp), "HH:mm:SS") or ""
end

-- "dd/mm HH:MM" local.
function M.date_dm_hm(iso_timestamp: string?): string
    return date.format(date.to_local(iso_timestamp), "DD/MM HH:mm") or ""
end

-- "dd/mm HH:MM:SS" local.
function M.date_dm_hms(iso_timestamp: string?): string
    return date.format(date.to_local(iso_timestamp), "DD/MM HH:mm:SS") or ""
end

-- Ns ou Mm Ns.
function M.fmt_secs(seconds: any): string
    local num_secs = math.floor(tonumber(seconds) or 0)
    local minutes = math.floor(num_secs / 60)
    local remaining_seconds = num_secs % 60
    if minutes > 0 then return string.format("%dm %ds", minutes, remaining_seconds) end
    return string.format("%ds", remaining_seconds)
end

function M.fmt_uptime(seconds: any): string
    local num_secs = math.floor(tonumber(seconds) or 0)
    local days = math.floor(num_secs / 86400)
    local hours = math.floor((num_secs % 86400) / 3600)
    local minutes = math.floor((num_secs % 3600) / 60)
    local remaining_seconds = num_secs % 60
    if days > 0 then return string.format("%dd %dh %dm", days, hours, minutes) end
    if hours > 0 then return string.format("%dh %dm", hours, minutes) end
    return string.format("%dm %ds", minutes, remaining_seconds)
end

-- Tamanho de bytes legível ("—" para 0), igual a view::fmt_bytes.
function M.fmt_bytes(bytes_value: any): string
    local total_bytes = tonumber(bytes_value) or 0
    local KB = 1024.0
    local MB = KB * 1024.0
    local GB = MB * 1024.0
    if total_bytes == 0 then return "—" end
    local bytes_float = total_bytes + 0.0
    if bytes_float >= GB then return string.format("%.1f GB", bytes_float / GB) end
    if bytes_float >= MB then return string.format("%.0f MB", bytes_float / MB) end
    return string.format("%.0f KB", bytes_float / KB)
end

-- Duração de um deployment (finished_at ou agora) − started_at, em fmt_secs.
--
-- `date.diff_seconds` compara INSTANTES, não texto: ele traz cada lado para a
-- hora local antes de subtrair, e é por isso que dá para misturar o
-- `finished_at` do daemon (RFC 3339 com "Z") com o `date.now()` da máquina
-- (sem fuso, hora local) sem converter nenhum dos dois na mão.
function M.fmt_duration(deployment: any): string
    local finished_at: string = deployment.finished_at or date.now(true)
    local elapsed_seconds: number? = date.diff_seconds(finished_at, deployment.started_at)
    if elapsed_seconds == nil or elapsed_seconds < 0 then return "0s" end
    return M.fmt_secs(elapsed_seconds)
end

-- Dias da semana no formato que o <radiogroup> do glacier-ui pede: uma coleção
-- de `{id, label}` no contexto, e não uma lista literal no atributo (o for-each
-- do motor lê chave, não texto). O `id` é o índice que `Recurrence::Weekly`
-- usa no daemon — 0 = segunda —, então ele viaja para o payload sem conversão.
-- Mora aqui, e não em cada tela, porque as duas janelas que agendam por semana
-- (limpeza automática e jobs) precisam da mesma lista.
-- Delimitador `[=[ ]=]` (e não `[[ ]]`) porque o conteúdo é um array JSON:
-- ele começa com `[` e termina com `]`, e as duas pontas encostariam nos
-- colchetes do próprio literal.
M.WEEKDAYS_JSON = [=[[{"id":"0","label":"Seg"},{"id":"1","label":"Ter"},{"id":"2","label":"Qua"},{"id":"3","label":"Qui"},{"id":"4","label":"Sex"},{"id":"5","label":"Sáb"},{"id":"6","label":"Dom"}]]=]

-- ── Ponte entre o <timeedit> e o protocolo ──────────────────────────────────
-- O <timeedit> do glacier-ui (0.68) guarda o horário numa chave ÚNICA, em ISO
-- ("HH:MM"). O daemon, do outro lado, sempre falou em dois campos separados
-- (`{hour, minute}`, em Recurrence::Daily/Weekly e em DockerCleanupConfig).
-- Estas duas funções são a tradução, e existem para que o contrato HTTP não
-- precise mudar por causa de uma troca de widget.

-- (hour, minute) -> "HH:MM". Aceita número ou string (o unpack das recurrences
-- devolve string) e satura na faixa válida, para que um valor corrompido vindo
-- do servidor não produza uma chave que o widget não consegue parsear.
function M.hm_join(hour: any, minute: any): string
    local hour_value = math.floor(tonumber(hour) or 0)
    local minute_value = math.floor(tonumber(minute) or 0)
    if hour_value < 0 then hour_value = 0 elseif hour_value > 23 then hour_value = 23 end
    if minute_value < 0 then minute_value = 0 elseif minute_value > 59 then minute_value = 59 end
    return string.format("%02d:%02d", hour_value, minute_value)
end

-- "HH:MM" -> hour, minute (números). Uma chave vazia ou malformada vira 0h00,
-- que é o mesmo default que o `tonumber(...) or 0` dos handlers já usava.
function M.hm_split(hour_minute_text: any): (number, number)
    local time_text = tostring(hour_minute_text or "")
    local hour_text, minute_text = string.match(time_text, "^(%d+):(%d+)$")
    if not hour_text then return 0, 0 end
    local hour = math.floor(tonumber(hour_text) or 0)
    local minute = math.floor(tonumber(minute_text) or 0)
    if hour < 0 or hour > 23 then hour = 0 end
    if minute < 0 or minute > 59 then minute = 0 end
    return hour, minute
end

return M
