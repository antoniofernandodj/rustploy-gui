--!strict
--!nolint FunctionUnused
-- new_project_window.luau — script da JANELA de "Novo projeto", um motor Glacier
-- próprio e ISOLADO do app principal (aberto via open_window). Recebe a conexão
-- (api_url/api_token) semeada no contexto por open_window({ data = ... }); ao
-- criar o projeto emite broadcast("project_created") para a janela principal
-- (recebido por on_broadcast em handlers/projects.luau) e fecha a si mesma.
--
-- require resolve relativo a ESTE arquivo (scripts/): "net/api" e "helpers".

local Api = require("net/api")
local Helpers = require("helpers")

-- Reconstrói o cliente da API a partir da conexão semeada no contexto.
local function client(): Api.Client?
    local url = ctx.api_url or ""
    if url == "" then
        return nil
    end
    return Api.new(url, ctx.api_token)
end

function init(): ()
    -- `new_project_name`/`new_project_description` são as chaves que os
    -- `form_control` do form(...) ligam
    -- (sem `value=`/`on_change=`: o motor grava sozinho). Só o valor inicial é
    -- semeado aqui; os `erro_np_*` são publicados pelo motor na validação.
    ctx.new_project_name = ctx.new_project_name or ""
    ctx.new_project_description = ctx.new_project_description or ""
    ctx.new_project_error = ""
    ctx.new_project_message = ""
    ctx.new_project_busy = ""
end

-- on_validation_error do form(...): as falhas já vêm prontas em JSON
-- (`[{campo,msg}]`) e os `{erro_<campo>}` + o `:invalid` já estão na tela —
-- aqui é só o aviso.
function new_project_show_validation_errors(_erros_json: string?): ()
    ctx.new_project_message = ""
    toast{ message = "Corrija os campos destacados", kind = "warning" }
end

-- on_submit do form(...): só roda quando a validação (rules="required" no campo
-- NOME) passou, então `new_project_name` está garantidamente preenchido. `fetch` (dentro
-- de rpc_checked) SUSPENDE a corrotina; ao voltar, em sucesso avisa a janela
-- principal e se fecha.
function submit_project(): ()
    local api = client()
    if not api then
        ctx.new_project_error = "sem conexão — reabra a janela pelo app"
        return
    end
    ctx.new_project_error = ""
    local name = Helpers.trim(ctx.new_project_name)
    local description = Helpers.trim(ctx.new_project_description)
    ctx.new_project_message = "criando…"
    ctx.new_project_busy = "true"

    local project_create_ok, project_create_response = api:rpc_checked{
        ProjectCreate = {
            name = name,
            description = (description ~= "" and description or nil),
        },
    }
    ctx.new_project_busy = ""
    if not project_create_ok then
        ctx.new_project_message = ""
        ctx.new_project_error = "erro: " .. tostring(project_create_response)
        return
    end

    -- Sucesso: envia os dados do projeto criado à janela inicial e fecha esta.
    local project = (type(project_create_response) == "table" and project_create_response.Project) or {}
    broadcast("project_created", {
        id = project.id,
        name = project.name or name,
        description = project.description or description,
    })
    close_window()
end

-- Botão "Cancelar": fecha ESTA janela (close_window fecha a janela dona deste
-- motor com precisão, sem depender de qual janela está em foco).
function cancel(): ()
    close_window()
end

-- Trava de ação em andamento (ver busy.luau): por último, com todas as funções já definidas.
require("busy").install(require("busy_actions"))
