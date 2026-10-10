--!strict
--!nolint FunctionUnused
-- handlers/jobs.luau — ações da tela global "Schedules" (sidebar) e da aba
-- "Jobs" do projeto: rodar agora, pausar/ativar, remover, abrir a janela
-- "Novo job".

local State = require("../state")
local Stream = require("stream")
local fmt = require("../fmt")

-- Bloqueia o botão IMEDIATAMENTE ao clicar (antes de qualquer resposta do
-- backend chegar) e trava double-click: `State.jobs_inflight[id] = true` +
-- os dois recomputos locais (sem RPC) fazem `j.running` virar `true` na
-- HORA em ambas as telas (sidebar Schedules e aba Jobs do projeto) — sem
-- isso o botão só desabilitava quando `refresh_now()` (rede) terminava,
-- alguns segundos depois do click. Só desbloqueia em erro (na hora, sem
-- esperar `refresh_now()`) ou depois que `refresh_now()` confirma o
-- `job_run` criado (dali em diante `j.running` já vem do snapshot real).
function job_run_now(job_id: string): ()
    local api = State.api
    if not api then
        return
    end
    if State.jobs_inflight[job_id] then
        return
    end
    State.jobs_inflight[job_id] = true
    Stream.update_open_project()
    Stream.refresh_jobs_summary_local()

    local job_run_now_ok, job_run_now_response = api:rpc_checked{ JobRunNow = { id = job_id } }
    if not job_run_now_ok then
        toast{ message = tostring(job_run_now_response), kind = "error" }
        State.jobs_inflight[job_id] = nil
        Stream.update_open_project()
        Stream.refresh_jobs_summary_local()
        return
    end
    toast{ message = tostring("Job disparado"), kind = "success" }
    Stream.refresh_now()
    State.jobs_inflight[job_id] = nil
end

-- Cancela um job_run em execução (ver docs/plano-cancelamento-de-jobs.md):
-- mata o processo `docker compose up` de verdade no daemon, não só a UI.
-- `job_run_id` vem de `j.last_run_id` — enquanto `j.running` só reflete o
-- estado otimista (ver `job_run_now`, antes do primeiro refresh confirmar o
-- job_run novo), pode ainda apontar pro run ANTERIOR; o daemon devolve
-- NotFound nesse caso (inofensivo, só o toast de erro).
function job_run_cancel(job_run_id: string): ()
    local api = State.api
    if not api or not job_run_id or job_run_id == "" then
        return
    end
    local job_run_cancel_ok, job_run_cancel_response = api:rpc_checked{ JobRunCancel = { job_run_id = job_run_id } }
    if job_run_cancel_ok then
        toast{ message = tostring("Cancelamento solicitado"), kind = "success" }
    else
        toast{ message = tostring(job_run_cancel_response), kind = "error" }
    end
    Stream.refresh_now()
end

-- Pausa/ativa um job: `JobUpdate` substitui o registro inteiro, então
-- reenviamos os campos como estão (só invertendo `enabled`) — o Job cru vem
-- de `State.jobs_by_id`, preenchido pelo `stream.luau` a cada snapshot.
function job_toggle(job_id: string): ()
    local api = State.api
    if not api then
        return
    end
    local job = State.jobs_by_id[job_id]
    if not job then
        toast{ message = tostring("job não encontrado (tela desatualizada — tenta de novo)"), kind = "error" }
        return
    end
    local job_update_ok, job_update_response = api:rpc_checked{
        JobUpdate = {
            id = job_id,
            name = job.name,
            compose = job.compose,
            git_source = job.git_source,
            main_service = job.main_service,
            env_vars = job.env_vars,
            env_comments = job.env_comments,
            enabled = not job.enabled,
            recurrence = job.recurrence,
        },
    }
    if job_update_ok then
        toast{
            message = tostring(job.enabled and "Job pausado" or "Job ativado"),
            kind = "success"
        }
    else
        toast{
            message = tostring(job_update_response),
            kind = "error"
        }
    end
    Stream.refresh_now()
end

-- Abre a janela de cadastro de job (motor Glacier próprio, isolado). Passa a
-- conexão atual + os catálogos de projetos/serviços JÁ BUSCADOS pelo snapshot
-- (a janela filha não pode buscar no init — só ações despachadas rodam o
-- fetch). Ao concluir, ela emite broadcast("job_created"), recebido por
-- on_broadcast em handlers/projects.luau. Ver views/new_job_window.gvb.
function open_new_job_window(): ()
    local snap = State.snap
    local projects = {}
    for _, project in ipairs((snap and snap.projects) or {}) do
        table.insert(projects, { id = project.id, name = project.name })
    end
    local services = {}
    for _, service in ipairs((snap and snap.services) or {}) do
        local service_record = service.service
        if service_record then
            table.insert(services, {
                id = service_record.id,
                name = service_record.spec.name,
                project_id = service_record.spec.project_id
            })
        end
    end
    open_window{
        component = "new_job", size = "560 700", decorations = false,
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            new_job_projects = json.encode(projects),
            new_job_services = json.encode(services),
        },
    }
end

-- Abre a MESMA janela em modo edição: pula os passos 1/2 (projeto/serviço
-- gatilho não são editáveis via JobUpdate) e semeia o passo 3 já preenchido.
-- Se o job for git-sourced, resolve conta/repo/branch ANTES de abrir (a
-- janela filha não pode buscar no init — mesma restrição de
-- open_new_job_window) pra o picker já vir com a seleção certa, sem forçar
-- o usuário a escolher de novo só pra editar outra coisa (ex.: env vars).
function open_edit_job_window(job_id: string): ()
    local job = State.jobs_by_id[job_id]
    if not job then
        toast{
            message = tostring("job não encontrado (tela desatualizada — tenta de novo)"),
            kind = "error"
        }
        return
    end
    local api = State.api

    local new_job_git_providers = "[]"
    local new_job_git_repos = "[]"
    local new_job_git_repo = ""
    local new_job_git_branches = "[]"
    if job.git_source and api then
        local provider_id = job.git_source.provider_id
        if provider_id and provider_id ~= "" then
            -- Essa cascata de RPCs (conta → repos → branches) roda ANTES de
            -- `open_window` — a janela filha não pode buscar no próprio
            -- init (mesma restrição de `open_new_job_window`), então até ela
            -- abrir o clique em "Editar" fica sem NENHUM feedback visual.
            -- Só o toast avisa que algo está acontecendo nesse intervalo.
            toast{
                message = tostring("Carregando dados do repositório…"),
                kind = "info"
            }
            local git_provider_list_ok, git_provider_list_response = api:rpc("GitProviderList")
            if git_provider_list_ok and git_provider_list_response.GitProviders then
                new_job_git_providers = fmt.git_providers(git_provider_list_response.GitProviders)
            end
            local git_repo_list_ok, git_repo_list_response = api:rpc{ GitRepoList = { provider_id = provider_id } }
            if git_repo_list_ok and git_repo_list_response.GitRepos then
                new_job_git_repos = fmt.git_repos(git_repo_list_response.GitRepos)
                for _, git_repo in ipairs(git_repo_list_response.GitRepos) do
                    if git_repo.clone_url == job.git_source.url then
                        new_job_git_repo = git_repo.full_name
                        break
                    end
                end
                if new_job_git_repo ~= "" then
                    local git_branch_list_ok, git_branch_list_response = api:rpc{
                        GitBranchList = {
                            provider_id = provider_id,
                            repo_full_name = new_job_git_repo
                        },
                    }
                    if git_branch_list_ok and git_branch_list_response.GitBranches then
                        new_job_git_branches = fmt.git_branches(git_branch_list_response.GitBranches)
                    end
                end
            end
        end
    end

    open_window{
        component = "new_job", size = "560 700", decorations = false,
        -- Sobrepõe o `title` do <screen> ("Novo job"): só quem abre sabe que
        -- desta vez é edição.
        title = "Editar job — Rustploy",
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            new_job_edit_job = json.encode(job),
            new_job_git_providers = new_job_git_providers,
            new_job_git_repos = new_job_git_repos,
            new_job_git_repo = new_job_git_repo,
            new_job_git_branches = new_job_git_branches,
        },
    }
end

-- Logs da última execução de um job — mesma janela genérica de logs
-- (log_window.gvb/.luau) usada por runtime/build, agora apontando pro SSE
-- dedicado `/api/jobs/runs/<id>/logs` (ver Event::JobLogLine).
function open_job_logs_window(job_run_id: string): ()
    if not job_run_id or job_run_id == "" then
        return
    end
    local seed = "[]"
    local api = State.api
    if api then
        local get_job_logs_ok, get_job_logs_response = api:rpc{
            GetJobLogs = {
                job_run_id = job_run_id
            }
        }
        if get_job_logs_ok and get_job_logs_response.JobLogs then
            seed = json.encode(get_job_logs_response.JobLogs)
        end
    end
    open_window{
        component = "log", size = "900 560", decorations = false,
        title = "Job — " .. string.sub(job_run_id, 1, 12),
        resizable = true,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            log_window_title = "Job · " .. string.sub(job_run_id, 1, 12),
            log_window_stream_url = "/api/jobs/runs/" .. job_run_id .. "/logs",
            log_window_seed = seed,
        },
    }
end

function job_delete(job_id: string): ()
    local api = State.api
    if not api then
        return
    end
    local job_delete_ok, job_delete_response = api:rpc_checked{ JobDelete = { id = job_id } }
    if job_delete_ok then
        toast{ message = tostring("Job removido"), kind = "success" }
    else
        toast{ message = tostring(job_delete_response), kind = "error" }
    end
    Stream.refresh_now()
end
