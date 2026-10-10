--!strict
--!nolint FunctionUnused
-- handlers/bundle.luau — copiar um serviço para outro servidor (lado do app
-- principal): o botão "Exportar serviço" da tela do serviço. Ver
-- docs/plano-copiar-servico-entre-servidores.md.
--
-- O plano (variáveis do serviço/projeto, com a sugestão de pré-marcação) é
-- buscado AQUI e semeado na janela via `data`: o `init` de uma janela não pode
-- fazer `fetch` (o motor descarta), só ações despachadas — como esta.

local State = require("../state")

-- `id` vem do card de serviço (`open_export_window:@id`); sem ele, é o serviço
-- aberto na tela do serviço (botão do cabeçalho).
function open_export_window(id: string?): ()
    local api = State.api
    local sid = (id ~= nil and id ~= "") and id or (ctx.selected_service or "")
    if not api or sid == "" then
        return
    end

    local ok, res = api:rpc_checked{ ServiceExportPlan = { service_id = sid } }
    if not ok or type(res) ~= "table" or not res.ServiceExportPlan then
        toast{ message = "Falha ao preparar a exportação: " .. tostring(res), kind = "error" }
        return
    end

    open_window{
        component = "service_export", size = "620 720", decorations = false,
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            export_service_id = sid,
            export_plan = json.encode(res.ServiceExportPlan),
        },
    }
end
