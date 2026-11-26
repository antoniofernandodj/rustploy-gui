--!strict
--!nolint FunctionUnused
-- handlers/service_description.luau — campo "Descrição" do cabeçalho do serviço
-- (service.component.gv): grava só a descrição com ServiceDescriptionSet.
-- Ver docs/arquivo/plano-descricao-do-servico.md.

local State = require("../state")
local Helpers = require("../helpers")

local M = {}

-- Igual ao título editável (services.luau → service_title_change) e à descrição
-- do projeto (projects.luau): cada tecla reinicia `description_save_timer`
-- (grava 0,5 s depois da última) e `description_toast_timer` (o aviso
-- "Descrição salva" só sai depois de 2 s sem nova gravação, para digitar não
-- virar uma chuva de toasts). Enquanto `description_save_timer` existe há texto
-- digitado ainda não gravado: o fetch do serviço não pode sobrescrever o campo
-- com o valor antigo do servidor.
local DESCRIPTION_SAVE_DELAY_MS = 500
local DESCRIPTION_TOAST_IDLE_MS = 2000
local description_save_timer: any = nil
local description_toast_timer: any = nil

-- Chamado pelo fetch_service_detail. Não atropela um rascunho: só troca o
-- texto se for outro serviço ou se não há gravação pendente.
function M.load(service_id: string, description: string?): ()
    local text = description or ""
    local same_service = ctx.service_description_service_id == service_id
    ctx.service_description_original = text
    if not same_service or description_save_timer == nil then
        ctx.service_description = text
        ctx.service_description_message = ""
    end
    ctx.service_description_service_id = service_id
end

local function service_description_write(): ()
    description_save_timer = nil
    local api = State.api
    local service_id = ctx.selected_service
    if not api or not service_id or service_id == "" then
        return
    end
    local text = Helpers.trim(ctx.service_description or "")
    -- Trocou de serviço no meio do debounce, ou nada mudou: nada a gravar.
    -- Esvaziar grava direto (sem diálogo): o campo é editável como texto comum,
    -- e o aviso do que se perde está no tooltip e na documentação.
    if
        service_id ~= ctx.service_description_service_id
        or text == Helpers.trim(ctx.service_description_original or "")
    then
        return
    end
    local ok, response = api:rpc_checked {
        ServiceDescriptionSet = {
            service_id = service_id,
            description = text,
        },
    }
    if ok and type(response) == "table" and response.Service then
        local saved = response.Service.spec.description or ""
        ctx.service_description = saved
        ctx.service_description_original = saved
        ctx.service_description_message = i18n.tr("salvo")
        if description_toast_timer then
            description_toast_timer:cancel()
        end
        description_toast_timer = after(
            DESCRIPTION_TOAST_IDLE_MS,
            function(): ()
                description_toast_timer = nil
                toast {
                    message = tostring(i18n.tr("Descrição salva")),
                    kind = "success",
                }
            end
        )
    else
        ctx.service_description_message = i18n.tr("erro: ") .. tostring(response)
        toast { message = tostring(response), kind = "error" }
    end
end

-- on_change da descrição do cabeçalho.
function service_description_change(value: string): ()
    ctx.service_description = value
    if description_save_timer then
        description_save_timer:cancel()
    end
    description_save_timer = after(DESCRIPTION_SAVE_DELAY_MS, service_description_write)
end

-- A gravação em si, para os testes (`glacier test` não dispara os `after`).
function service_description_flush(): ()
    service_description_write()
end

return M
