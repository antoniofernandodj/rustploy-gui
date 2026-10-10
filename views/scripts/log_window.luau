--!strict
--!nolint FunctionUnused
-- log_window.luau — script da JANELA de logs (runtime OU build) de um serviço/
-- deployment, um motor Glacier próprio e ISOLADO do app principal (aberto via
-- open_window por handlers/services.luau: open_logs_window / deployment_logs).
-- Genérico: a mesma janela serve os dois tipos, parametrizada por `data`:
--   api_url / api_token   — conexão com o daemon
--   log_window_title              — título (ex.: "Logs · api" / "Build logs · dep_01KX…")
--   log_window_stream_url         — path do SSE dedicado a seguir:
--                             "/api/services/<id>/logs"          (runtime)
--                             "/api/deployments/<id>/build-logs" (build)
--   log_window_seed               — JSON do tail/histórico inicial (o pai já buscou)
--
-- O corpo é um <textarea> (text_editor): texto SELECIONÁVEL/copiável. Cada linha
-- nova é APPENDADA no fim via append_textarea (o motor insere no Content sem
-- recriá-lo — preserva scroll e custa O(linha)), em vez de reescrever o buffer
-- inteiro a cada linha (que apagaria a seleção e pularia pro topo). O SSE já só
-- emite quando HÁ linha nova, então não há atualização "de graça".
--
-- sse() no init() FUNCIONA (o motor liga as streams abertas no init); já
-- `append_textarea` NÃO (efeitos de init são descartados, como `fetch`), por isso
-- o histórico inicial vai por um SET completo (ctx.log_window_logs_text) no init, e só as
-- linhas VIVAS (no on_message da sse, ação despachada) usam append_textarea.
--
-- require resolve relativo a ESTE arquivo (scripts/): "fmt" (fachada de fmt/*)
-- e "net/api" (daqui só sai `auth_headers`, o mesmo Authorization do app).

local fmt = require("fmt")
local Api = require("net/api")

-- Buffer de eventos {stream?,line,timestamp} p/ reconstrução em corte (trim). O
-- <textarea> cresce por append; para não crescer sem limite numa sessão longa,
-- ao passar de RING_HIGH cortamos a cauda para RING_LOW e reconstruímos o
-- buffer UMA vez (raro — o intervalo largo evita reconstruir a cada linha).
local RING_HIGH = 6000
local RING_LOW = 4000
local log_rows: { any } = {}

-- Set COMPLETO do textarea a partir do buf (usado no seed e no corte). Mantém o
-- fim com "\n" para os appends seguintes começarem em linha nova.
local function set_full(): ()
    local text = fmt.join_log_lines(log_rows)
    ctx.log_window_logs_text = (#log_rows > 0) and (text .. "\n") or ""
    ctx.log_window_count = tostring(#log_rows)
end

-- Aplica um lote de eventos novos: appenda no fim (barato) ou, se estourou o
-- teto, corta a cauda e reconstrói (raro).
local function push_batch(events: { any }): ()
    if #events == 0 then
        return
    end
    for _, event in ipairs(events) do
        table.insert(log_rows, event)
    end
    if #log_rows > RING_HIGH then
        while #log_rows > RING_LOW do
            table.remove(log_rows, 1)
        end
        set_full()
    else
        append_textarea("log_window_logs_text", fmt.join_log_lines(events) .. "\n")
        ctx.log_window_count = tostring(#log_rows)
    end
end

-- Um evento do bus: os endpoints já filtram por id; pegamos o LogLine (runtime),
-- BuildLog (build) ou JobLogLine (job one-shot), o que vier. BuildLog não traz
-- `stream` (cor padrão).
local function to_row(event: any): any?
    if type(event) ~= "table" then
        return nil
    end
    return event.LogLine or event.BuildLog or event.JobLogLine
end

function init(): ()
    ctx.log_window_title = ctx.log_window_title or "Logs"

    -- Histórico inicial semeado pelo pai (SET completo — append_textarea de init
    -- seria descartado). Daí em diante, só appends vivos no on_message abaixo.
    local json_decode_ok, seed = pcall(json.decode, ctx.log_window_seed or "[]")
    log_rows = (json_decode_ok and type(seed) == "table") and seed or {}
    set_full()

    -- SSE própria desta janela no endpoint dedicado (o motor liga streams
    -- abertas no init; o handle não precisa ser guardado — vive com a janela).
    -- Cada `data:` é um JSON auto-descritivo (kind). O endpoint dedicado manda
    -- lotes `bus_batch`; tratamos `bus` avulso por robustez.

    local sse_url = (ctx.api_url or "") .. (ctx.log_window_stream_url or "")
    sse(sse_url, {
        headers = Api.auth_headers(ctx.api_token),
        on_message = function(data: string): ()
            local json_decode_ok, decoded = pcall(json.decode, data)
            if not json_decode_ok or type(decoded) ~= "table" then
                return
            end
            if decoded.kind == "bus" then
                local row = to_row(decoded.event)
                if row then
                    push_batch{ row }
                end
            elseif decoded.kind == "bus_batch" then
                local rows = {}
                for _, event in ipairs(decoded.events or {}) do
                    local row = to_row(event)
                    if row then
                        table.insert(rows, row)
                    end
                end
                push_batch(rows)
            end
        end,
    })

end
