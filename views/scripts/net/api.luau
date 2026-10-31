--!strict

-- net/api.luau — cliente HTTP/JSON da API do daemon.
--
-- Encapsula base_url + header Authorization e expõe `rpc(cmd)`: faz
-- POST /api/rpc com o Command em JSON e devolve a Response decodificada. Fala
-- pelo cliente `http()` do glacier (glacier-ui 0.145+), que SUSPENDE a corrotina
-- da ação (async/await) — a UI não trava enquanto espera a resposta. O cliente
-- guarda base_url, Authorization e o teto de tempo num lugar só; a tradução de
-- "falhou" para texto (`failure_text`) também.
--
-- `rpc` é POST: o cliente NUNCA repete um POST sozinho (o primeiro pode ter
-- chegado ao daemon — repetir um `ServiceDelete` ou um deploy seria perigoso).
-- Só as leituras puras (GET, como o `/api/version`) usam `retries`.
--
-- Convenção de Command (serde externally-tagged):
--   • variante unitária  → string:  "DaemonStatus", "StopAllManaged"
--   • variante com campos → tabela:  { ProjectDelete = { id = "..." } }
-- Convenção de Response (idem): { Projects = {...} }, { DaemonStatus = {...}
-- }.

local M = {}
M.__index = M

-- Teto de cada requisição (ms). Sem ele um daemon que não responde deixaria a
-- ação suspensa para sempre — e o botão (busy.luau) bloqueado junto. Estourar
-- vira `(false, erro)` como qualquer outra falha de transporte.
M.RPC_TIMEOUT_MS = 60000
M.UPLOAD_TIMEOUT_MS = 600000

--- Só o header `Authorization` (tabela vazia quando não há token). Função de
--- MÓDULO (ponto, não dois-pontos) de propósito: também serve quem NÃO tem um
--- Client nas mãos — as chamadas cruas de `sse` em `handlers/stream.luau` e
--- `log_window.luau`, que falam com o daemon sem passar por `rpc`. Assim o
--- formato "Bearer <token>" tem uma definição só, aqui.
function M.auth_headers(token: string?): { [string]: string }
    if token == nil or token == "" then
        return {}
    end

    return { Authorization = "Bearer " .. token }
end

--- O texto de uma falha de transporte/HTTP: a mensagem do motor quando a
--- requisição nem chegou a responder, senão `HTTP <status>`. Uma definição só
--- para todas as chamadas deste módulo (e para quem usa `fetch` cru).
function M.failure_text(http_response: any): string
    if http_response.error ~= nil and http_response.error ~= "" then
        return tostring(http_response.error)
    end

    return "HTTP " .. tostring(http_response.status)
end

--- `{ ["Content-Type"] = "application/json" }` — o corpo de toda chamada de
--- comando é JSON.
local JSON_HEADERS = { ["Content-Type"] = "application/json" }

--- Decodifica o corpo; `ok=false` quando não é JSON. Aceita QUALQUER valor
--- decodificado: uma Response de variante UNITÁRIA (ex.: `Response::Ok`) é
--- serializada pelo serde como a string bare "Ok" (não um objeto).
local function decode_body(body: string?): (boolean, any)
    return pcall(json.decode, body or "")
end

--- `POST /api/login`: troca o token de conexão pelo token da API. O login da
--- GUI não usa mais (decodifica o token de conexão e usa o token da API
--- direto); fica para depuração. Função de
--- MÓDULO: roda antes de existir um Client. Retorna `(true, token)`, ou
--- `(false, mensagem, status)` — a mensagem é a explicação do daemon (formato
--- errado, chave de outra instalação), e o `status` deixa quem chama tratar o
--- 404 de um daemon anterior ao login por chave.
function M.login(
    base_url: string,
    access_key: string
): (boolean, string, number?)
    local anonymous = http(base_url, { timeout = M.RPC_TIMEOUT_MS })
    local http_response = anonymous:post("/api/login", { key = access_key })

    local decode_ok, decoded = decode_body(http_response.body)
    if
        http_response.ok
        and decode_ok
        and type(decoded) == "table"
        and type(decoded.access_token) == "string"
    then
        return true, decoded.access_token, http_response.status
    end

    if
        decode_ok
        and type(decoded) == "table"
        and type(decoded.error) == "table"
        and decoded.error.message
    then
        return false, tostring(decoded.error.message), http_response.status
    end

    return false, M.failure_text(http_response), http_response.status
end

--- Executa um Command. Retorna (true, response_table) em sucesso HTTP, ou
--- (false, mensagem) em falha de transporte / corpo inválido.
function M:rpc(command: any): (boolean, any)
    -- `json.encode` aqui (e não o corpo-tabela do `http()`): um Command
    -- unitário é a STRING "DaemonStatus", que o cliente mandaria sem aspas.
    local http_response = self.client:post(
        "/api/rpc",
        json.encode(command),
        { headers = JSON_HEADERS }
    )

    if not http_response.ok then
        return false, M.failure_text(http_response)
    end

    local json_decode_ok, decoded = decode_body(http_response.body)
    if not json_decode_ok then
        return false, "resposta inválida do daemon"
    end

    return true, decoded
end

--- Como `rpc`, mas trata `Response::Err { code, message }` como falha.
function M:rpc_checked(command: any): (boolean, any)
    local rpc_ok, rpc_response = self:rpc(command)

    if not rpc_ok then
        return false, rpc_response
    end

    if type(rpc_response) == "table" and rpc_response.Err ~= nil then
        return false,
            tostring(rpc_response.Err.code) .. ": " .. tostring(
                rpc_response.Err.message
            )
    end

    return true, rpc_response
end

--- Envia um zip como corpo CRU (`body_file`: o motor lê o arquivo ao enviar —
--- sem base64 e sem carregar o zip no Lua). `opts.on_progress` recebe
--- `{ phase, done, total, fraction }` (~20×/s) e `opts.signal` (um
--- `abort_controller()`) cancela o envio; um envio cancelado volta
--- `(false, "cancelado")`.
function M:upload_archive(
    service_id: string,
    filename: string,
    path: string,
    opts: {
        on_progress: ((progress: any) -> ())?,
        signal: any?,
    }?
): (boolean, any)
    local http_response =
        self.client:post("/api/services/" .. service_id .. "/archive", nil, {
            headers = {
                ["Content-Type"] = "application/zip",
                ["X-Rustploy-Filename"] = filename,
            },
            body_file = path,
            timeout = M.UPLOAD_TIMEOUT_MS,
            on_progress = if opts then opts.on_progress else nil,
            signal = if opts then opts.signal else nil,
        })
    if not http_response.ok then
        return false, M.failure_text(http_response)
    end
    local json_decode_ok, decoded = decode_body(http_response.body)
    if not json_decode_ok then
        return false, "resposta inválida do daemon"
    end
    if type(decoded) == "table" and decoded.Err ~= nil then
        return false,
            tostring(decoded.Err.code) .. ": " .. tostring(decoded.Err.message)
    end
    return true, decoded
end

--- Sonda `GET /api/version` (leitura pura: o cliente repete 1× sozinho numa
--- falha de rede). Retorna a resposta crua do `http()` — quem chama olha
--- `status`/`error`.
function M.probe(base_url: string): any
    return http(base_url, { timeout = 8000, retries = 1 }):get("/api/version")
end

export type Client = typeof(setmetatable(
    {} :: {
        base_url: string,
        token: string?,
        client: any, -- o `http()` do glacier, com base_url + Authorization
    },
    M
))

function M.new(base_url: string, token: string?): Client
    local clean_token = if token ~= nil and token ~= "" then token else nil
    return setmetatable({
        base_url = base_url,
        token = clean_token,
        client = http(base_url, {
            headers = M.auth_headers(clean_token),
            timeout = M.RPC_TIMEOUT_MS,
        }),
    }, M)
end

return M
