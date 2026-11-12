--!strict
--!nolint FunctionUnused
-- handlers/job_env.luau — tela "Variáveis e secrets do job" (shell/job_env.component.gv). A lógica
-- mora em scripts/job_env_core.luau (a mesma que a janela "Novo/Editar job" usa); aqui ficam só a
-- navegação (abrir/voltar) e as funções globais finas que os botões chamam.

local State = require("../state")
local Stream = require("stream")
local History = require("history")
local Core = require("../job_env_core")
require("../job_env_actions")

local M = {}

local function close_job_actions(): ()
    for job_id in State.jobs_by_id do
        ctx["job_actions_open_" .. job_id] = ""
    end
end

local function show(job_id: string): ()
    local job = State.jobs_by_id[job_id]
    if not job then
        toast {
            message = i18n.tr("job não encontrado (tela desatualizada — tenta de novo)"),
            kind = "error",
        }
        return
    end
    History.push()
    Core.setup {
        api = State.api,
        project_id = job.project_id,
        job_id = job_id,
        after_change = function(): ()
            Stream.refresh_now()
        end,
    }
    Core.reset_forms()
    ctx.job_env_job_id = job_id
    ctx.job_env_project_id = job.project_id
    ctx.view = "job_env"
    ctx.selected_service = ""
    Core.load()
end

-- "🔑 Variáveis e secrets" no painel "Ações do job".
function job_env_open(job_id: string): ()
    close_job_actions()
    show(job_id)
end

-- Voltar para esta tela (depois de ter ido a outra): reabre o job pelo mesmo caminho do clique.
History.register("job_env", function(_snapshot: any): ()
    local job_id = ctx.job_env_job_id or ""
    if job_id ~= "" and State.jobs_by_id[job_id] then
        show(job_id)
    end
end)

-- "‹ Voltar": a mesma ação do Backspace.
function job_env_back(): ()
    Core.reset_forms()
    if not History.back() then
        ctx.view = "schedules"
    end
end

return M
