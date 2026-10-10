--!strict
--!nolint FunctionUnused
-- handlers/secrets.luau — aba "Secrets" do projeto: criar/sobrescrever e apagar
-- valores cifrados, e o atalho "usar secret" da aba Variáveis.
--
-- A UI é write-only DE PROPÓSITO: o daemon só devolve os NOMES (SecretList →
-- Response::SecretNames), nunca o blob cifrado, então não há o que exibir nem
-- como "editar" um valor — sobrescrever é salvar outro com o mesmo nome
-- (o SecretSet do daemon faz ON CONFLICT DO UPDATE). Ver docs/secrets.md.
--
-- A lista em si não é buscada aqui: vem no snapshot (`projects[].secrets`),
-- montada por handlers/stream.luau em ctx.project_secrets/project_secrets_count.

local State = require("../state")
local Helpers = require("../helpers")
local Stream = require("stream")

-- Nomes atualmente conhecidos (do snapshot já renderizado), para saber se um
-- SecretSet cria ou substitui — o daemon não distingue os dois casos.
local function known_names(): { [string]: boolean }
    local set = {}
    local ok, rows = pcall(json.decode, ctx.project_secrets or "[]")
    if ok and type(rows) == "table" then
        for _, r in ipairs(rows) do
            set[tostring(r.name)] = true
        end
    end
    return set
end

-- on_validation_error do form(name = secret_add) — NOME e valor são
-- `rules="required"` no form(...); o motor publica {error_project_secret_new_name} /
-- {error_project_secret_new_value} e acende o :invalid. Aqui é só o aviso.
function secret_add_show_validation_errors(_erros_json: string?): ()
    toast{ message = "Preencha nome e valor do secret", kind = "warning" }
end

function secret_add(): ()
    local pid = ctx.selected_project_id or ""
    local api = State.api
    if pid == "" or not api then
        return
    end
    -- rules="required" no form(...) garante nome e valor preenchidos aqui.
    local name = Helpers.trim(ctx.project_secret_new_name)
    local value = ctx.project_secret_new_value or ""
    local replacing = known_names()[name] == true
    local ok, res = api:rpc_checked{
        SecretSet = { project_id = pid, name = name, value = value }
    }
    if ok then
        ctx.project_secret_new_name = ""
        ctx.project_secret_new_value = ""
        toast{
            message = tostring(
                replacing
                    and ("Secret \"" .. name .. "\" substituído — o novo valor vale no próximo deploy")
                    or ("Secret \"" .. name .. "\" criado")
            ),
            kind = "success"
        }
        Stream.refresh_now()
    else
        toast{ message = tostring(res), kind = "error" }
    end
end

function secret_delete(name: string): ()
    local pid = ctx.selected_project_id or ""
    if pid == "" or name == "" then
        return
    end
    local ok_confirm = confirm{
        title = "Remover secret?",
        message = "O valor cifrado será apagado e não há como recuperá-lo. "
            .. "Variáveis que referenciam \"" .. name .. "\" passarão a receber "
            .. "valor vazio no próximo deploy.",
        confirm_label = "Remover secret",
        destructive = true,
    }
    if not ok_confirm then
        return
    end
    local api = State.api
    if not api then
        return
    end
    local ok, res = api:rpc_checked{ SecretDelete = { project_id = pid, name = name } }
    if ok then
        toast{ message = tostring("Secret removido"), kind = "success" }
        Stream.refresh_now()
    else
        toast{ message = tostring(res), kind = "error" }
    end
end

-- Chip "usar secret" (aba Variáveis): arma o form de adicionar var em modo
-- secret com o nome escolhido. Quem grava é project_env_add (handlers/projects.luau),
-- que nesse modo monta { Secret = nome } em vez de { Plain = valor }.
function secret_use(name: string): ()
    ctx.project_env_new_is_secret = "true"
    ctx.project_env_new_value = name
    if Helpers.trim(ctx.project_env_new_key) == "" then
        ctx.project_env_new_key = name
    end
end

function project_env_secret_toggle(): ()
    local on = ctx.project_env_new_is_secret == "true"
    ctx.project_env_new_is_secret = on and "false" or "true"
    ctx.project_env_new_value = ""
end
