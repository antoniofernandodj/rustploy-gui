--!strict
--!nolint FunctionUnused
-- handlers/service_description.luau — painel "Descrição" da aba General
-- (service/general.component.gv): grava só a descrição com
-- ServiceDescriptionSet. Ver docs/arquivo/plano-descricao-do-servico.md.

local State = require("../state")
local Helpers = require("../helpers")

local M = {}

-- Chamado pelo fetch_service_detail. Não atropela um rascunho: só troca o
-- texto se for outro serviço ou se não há edição pendente.
function M.load(service_id: string, description: string?): ()
    local text = description or ""
    local same_service = ctx.service_description_service_id == service_id
    local has_draft = (ctx.service_description or "")
        ~= (ctx.service_description_original or "")
    ctx.service_description_original = text
    if not same_service or not has_draft then
        ctx.service_description = text
        ctx.service_description_message = ""
    end
    ctx.service_description_service_id = service_id
end

function service_description_save(): ()
    local api = State.api
    local service_id = ctx.selected_service
    if not api or not service_id or service_id == "" then
        return
    end
    local text = Helpers.trim(ctx.service_description or "")
    local original = Helpers.trim(ctx.service_description_original or "")
    if text == original then
        ctx.service_description_message = i18n.tr("nada mudou")
        return
    end
    if text == "" then
        local confirmed = confirm {
            title = tostring(i18n.tr("Apagar a descrição?")),
            message = tostring(
                i18n.tr(
                    "O texto some para todos (pessoas e agentes). Não dá para "
                        .. "desfazer, a não ser pelo histórico do git."
                )
            ),
            confirm_label = tostring(i18n.tr("Apagar")),
            destructive = true,
        }
        if not confirmed then
            return
        end
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
        toast { message = tostring(i18n.tr("Descrição salva")), kind = "success" }
    else
        ctx.service_description_message = i18n.tr("erro: ") .. tostring(response)
        toast { message = tostring(response), kind = "error" }
    end
end

function service_description_cancel(): ()
    ctx.service_description = ctx.service_description_original or ""
    ctx.service_description_message = ""
end

return M
