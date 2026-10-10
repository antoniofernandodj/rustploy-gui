--!strict

-- net/api.luau — cliente HTTP/JSON da API do daemon.
--
-- Encapsula base_url + header Authorization e expõe `rpc(cmd)`: faz
-- POST /api/rpc com o Command em JSON e devolve a Response decodificada. O
-- `fetch` do prelúdio SUSPENDE a corrotina da ação (async/await) — a UI não
-- trava enquanto espera a resposta.
--
-- Convenção de Command (serde externally-tagged):
--   • variante unitária  → string:  "DaemonStatus", "StopAllManaged"
--   • variante com campos → tabela:  { ProjectDelete = { id = "..." } }
-- Convenção de Response (idem): { Projects = {...} }, { DaemonStatus = {...} }.

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

function M:headers(): { [string]: string }
    local headers = M.auth_headers(self.token)
    headers["Content-Type"] = "application/json"

    return headers
end

--- Executa um Command. Retorna (true, response_table) em sucesso HTTP, ou
--- (false, mensagem) em falha de transporte / corpo inválido.
function M:rpc(command: any): (boolean, any)
    local http_response = fetch(tostring(self.base_url) .. "/api/rpc", {
        method = "POST",
        body = json.encode(command),
        headers = self:headers(),
        timeout = M.RPC_TIMEOUT_MS,
    })

    if not http_response.ok then
        local error_message =
            (http_response.error ~= nil and http_response.error ~= "")
                and http_response.error
                or ("HTTP " .. tostring(http_response.status))

        return false, error_message
    end

    local json_decode_ok, decoded = pcall(json.decode, http_response.body)

    -- Aceita QUALQUER valor decodificado: uma Response de variante UNITÁRIA
    -- (ex.: `Response::Ok`) é serializada pelo serde como a string bare "Ok"
    -- (não um objeto). Só o parse falhando é resposta inválida.
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
        return false, tostring(rpc_response.Err.code) .. ": " .. tostring(rpc_response.Err.message)
    end

    return true, rpc_response
end

function M:upload_archive(
    service_id: string,
    filename: string,
    body_base64: string
): (boolean, any)
    local headers = self:headers()
    headers["Content-Type"] = "application/zip"
    headers["X-Rustploy-Filename"] = filename

    local http_response = fetch(tostring(self.base_url) .. "/api/services/" .. service_id .. "/archive", {
        method = "POST",
        body_base64 = body_base64,
        headers = headers,
        timeout = M.UPLOAD_TIMEOUT_MS,
    })
    if not http_response.ok then
        return false, (http_response.error ~= nil and http_response.error ~= "") and http_response.error or ("HTTP " .. tostring(http_response.status))
    end
    local json_decode_ok, decoded = pcall(json.decode, http_response.body)
    if not json_decode_ok then
        return false, "resposta inválida do daemon"
    end
    if type(decoded) == "table" and decoded.Err ~= nil then
        return false, tostring(decoded.Err.code) .. ": " .. tostring(decoded.Err.message)
    end
    return true, decoded
end

export type Client = typeof(setmetatable(
    {} :: {
        base_url: string,
        token: string?,
    },
    M
))

function M.new(base_url: string, token: string?): Client
    return setmetatable({
        base_url = base_url,
        token = token ~= nil and token ~= "" and token or nil,
    }, M)
end

return M
