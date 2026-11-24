--!strict
--!nolint FunctionUnused
-- handlers/environments.luau — aba Ambientes do projeto
-- (shell/project_environments.component.gv). Num projeto de origem: a lista de
-- ambientes e "Criar ambiente". Num ambiente: a comparação com a origem e,
-- por serviço, Promover para a origem / Trazer da origem. Ver
-- docs/plano-releases-ambientes-rotas-volumes.md §2.

local State = require("../state")
local Stream = require("stream")
local Projects = require("projects")

local M = {}

-- Os pares da última comparação, por posição: os botões mandam o índice
-- (o dispatch nome:sufixo leva um argumento só).
local environment_pairs: { any } = {}
local environment_comparison: any = nil

local function open_project_record(): any
    local snap = State.snap
    if not snap then
        return nil
    end
    for _, project in ipairs(snap.projects or {}) do
        if project.id == ctx.selected_project_id then
            return project
        end
    end
    return nil
end

local function release_label(number: number?): string
    if number == nil then
        return "—"
    end
    return "v" .. tostring(number)
end

-- O que a tela diz quando um par não tem botão (ou o que o botão vai fazer).
local function note_label(note: string?): string
    if note == "compose" then
        return i18n.tr(
            "Stack Compose: não há uma imagem só para levar. Faça o deploy em cada ambiente."
        )
    elseif note == "no_release_anywhere" then
        return i18n.tr("Nenhum dos dois lados tem uma release no ar. Faça um deploy em um deles.")
    elseif note == "no_release_in_origin" then
        return i18n.tr("A origem não tem uma release no ar: só dá para promover daqui para lá.")
    elseif note == "no_release_here" then
        return i18n.tr(
            "Este ambiente ainda não tem deploy: traga a versão da origem ou faça um deploy."
        )
    elseif note == "running_without_release" then
        return i18n.tr(
            "No ar desde antes das releases: ao levar, a imagem que está rodando vira a release."
        )
    end
    return ""
end

local function change_rows(changes: { any }?): { any }
    local rows = {}
    for _, change: any in ipairs(changes or {}) do
        table.insert(rows, {
            text = change.field
                .. ": "
                .. (change.before or "—")
                .. " → "
                .. (change.after or "—"),
        })
    end
    return rows
end

function M.load(): ()
    local api = State.api
    local project = open_project_record()
    if not api or not project then
        return
    end
    ctx.environment_new_name = ctx.environment_new_name or ""
    if project.environment ~= nil then
        ctx.environment_is_environment = "1"
        local compare_ok, compare_response = api:rpc {
            EnvironmentCompare = { project_id = project.id },
        }
        if not compare_ok or not compare_response.EnvironmentComparison then
            ctx.environment_compare_title = tostring(compare_response)
            ctx.environment_pairs = json.encode(json.array({}))
            return
        end
        environment_comparison = compare_response.EnvironmentComparison
        environment_pairs = environment_comparison.services or {}
        ctx.environment_origin_project_id =
            environment_comparison.origin_project_id
        ctx.environment_here_project_id = project.id
        ctx.environment_here_name = project.environment.name
        ctx.environment_compare_title = string.format(
            i18n.tr("Ambiente %s, comparado com %s"),
            project.environment.name,
            environment_comparison.origin_project_name
        )
        local rows = {}
        for index, pair in ipairs(environment_pairs) do
            local both_released = pair.origin_release_number ~= nil
                and pair.environment_release_number ~= nil
            table.insert(rows, {
                index = tostring(index),
                service_name = pair.service_name,
                releases_label = string.format(
                    i18n.tr("origem %s · aqui %s"),
                    release_label(pair.origin_release_number),
                    release_label(pair.environment_release_number)
                ),
                -- "imagens diferentes" só quando os dois lados têm imagem.
                image_label = if pair.same_image
                    then i18n.tr("mesma imagem")
                    elseif both_released then i18n.tr("imagens diferentes")
                    else "",
                image_class = if pair.same_image
                    then "u-ok"
                    elseif both_released then "u-warn"
                    else "none",
                note_label = note_label(pair.note),
                changes = json.array(change_rows(pair.changes)),
                can_promote = pair.can_promote_to_origin and "1" or "0",
                can_bring = pair.can_bring_from_origin and "1" or "0",
            })
        end
        ctx.environment_pairs = json.encode(json.array(rows))
        ctx.environment_project_env_count =
            tostring(#(environment_comparison.project_env_changes or {}))
        ctx.environment_project_env_rows =
            json.encode(json.array(change_rows(environment_comparison.project_env_changes)))
        local only = {}
        if #(environment_comparison.only_in_origin or {}) > 0 then
            table.insert(
                only,
                string.format(
                    i18n.tr("só na origem: %s"),
                    table.concat(environment_comparison.only_in_origin, ", ")
                )
            )
        end
        if #(environment_comparison.only_in_environment or {}) > 0 then
            table.insert(
                only,
                string.format(
                    i18n.tr("só aqui: %s"),
                    table.concat(environment_comparison.only_in_environment, ", ")
                )
            )
        end
        ctx.environment_only_label = table.concat(only, " · ")
    else
        ctx.environment_is_environment = "0"
        local list_ok, list_response = api:rpc {
            EnvironmentList = { project_id = project.id },
        }
        local rows = {}
        if list_ok and list_response.Environments then
            for _, environment in ipairs(list_response.Environments) do
                table.insert(rows, {
                    project_id = environment.project_id,
                    project_name = environment.project_name,
                    name = environment.name,
                })
            end
        end
        ctx.environment_list = json.encode(json.array(rows))
        ctx.environment_list_count = tostring(#rows)
    end
end

function environment_name_change(value: string): ()
    ctx.environment_new_name = value
end

function environment_create(): ()
    local api = State.api
    local project = open_project_record()
    local name = (ctx.environment_new_name or ""):match("^%s*(.-)%s*$") or ""
    if not api or not project or name == "" then
        return
    end
    local create_ok, create_response = api:rpc_checked {
        EnvironmentCreate = { project_id = project.id, name = name },
    }
    if create_ok then
        toast {
            message = string.format(i18n.tr("ambiente %s criado"), name),
            kind = "success",
        }
        ctx.environment_new_name = ""
        Stream.refresh_now()
        M.load()
    else
        toast { message = tostring(create_response), kind = "error" }
    end
end

function environment_open(project_id: string): ()
    Projects.open_project(project_id)
end

function environment_open_origin(): ()
    local origin_id = ctx.environment_origin_project_id or ""
    if origin_id ~= "" then
        Projects.open_project(origin_id)
    end
end

function environment_refresh(): ()
    M.load()
end

local function promote(index_text: string, direction: string): ()
    local api = State.api
    local pair = environment_pairs[tonumber(index_text) or 0]
    local comparison = environment_comparison
    local project = open_project_record()
    if not api or not pair or not comparison or not project then
        return
    end
    local from_id, to_id, number, target
    if direction == "origin" then
        from_id, to_id = pair.environment_service_id, pair.origin_service_id
        number, target =
            pair.environment_release_number, comparison.origin_project_name
    else
        from_id, to_id = pair.origin_service_id, pair.environment_service_id
        number, target = pair.origin_release_number, project.name
    end
    -- Sem número: o lado de origem está no ar desde antes das releases.
    local version = if number == nil then i18n.tr("versão no ar") else release_label(number)
    local confirmed = confirm {
        title = string.format(
            i18n.tr("Levar a %s de %s para %s?"),
            version,
            pair.service_name,
            target
        ),
        message = i18n.tr(
            "O destino faz o deploy da mesma imagem, sem build. A configuração "
                .. "dele (variáveis, réplicas, domínios) não muda."
        ),
        confirm_label = i18n.tr("Fazer o deploy"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local promote_ok, promote_response = api:rpc_checked {
        EnvironmentPromote = { from_service_id = from_id, to_service_id = to_id },
    }
    if promote_ok then
        toast {
            message = string.format(
                i18n.tr("deploy de %s iniciado"),
                pair.service_name
            ),
            kind = "success",
        }
    else
        toast { message = tostring(promote_response), kind = "error" }
    end
end

function environment_promote_to_origin(index_text: string): ()
    promote(index_text, "origin")
end

function environment_bring_from_origin(index_text: string): ()
    promote(index_text, "environment")
end

-- ── Destruir ambiente ──────────────────────────────────────────────────────
-- Painel com o nome digitado como confirmação (e a escolha dos dados). Abre de
-- dentro do ambiente ou de uma linha da lista da origem.

local function open_destroy(project_id: string, name: string): ()
    ctx.environment_destroy_open = "1"
    ctx.environment_destroy_project_id = project_id
    ctx.environment_destroy_name = name
    ctx.environment_destroy_title = string.format(i18n.tr("Destruir o ambiente %s"), name)
    ctx.environment_destroy_hint = string.format(
        i18n.tr(
            "Para e apaga todos os serviços, jobs e rotas deste ambiente, e o projeto. "
                .. "A origem não é tocada. Para confirmar, digite o nome do ambiente: %s"
        ),
        name
    )
    ctx.environment_destroy_typed = ""
    ctx.environment_destroy_volumes = false
end

function environment_destroy_here(): ()
    local project_id = ctx.environment_here_project_id or ""
    if project_id ~= "" then
        open_destroy(project_id, ctx.environment_here_name or "")
    end
end

function environment_destroy_ask(project_id: string): ()
    local list = json.decode(ctx.environment_list or "[]") or {}
    for _, environment in ipairs(list) do
        if environment.project_id == project_id then
            open_destroy(project_id, environment.name)
            return
        end
    end
end

function environment_destroy_cancel(): ()
    ctx.environment_destroy_open = "0"
end

function environment_destroy_confirm(): ()
    local api = State.api
    local name = ctx.environment_destroy_name or ""
    local typed = (tostring(ctx.environment_destroy_typed or "")):match("^%s*(.-)%s*$") or ""
    if not api then
        return
    end
    if typed ~= name then
        toast {
            message = string.format(i18n.tr("Digite o nome do ambiente (%s) para confirmar."), name),
            kind = "error",
        }
        return
    end
    local delete_volumes = ctx.environment_destroy_volumes == true
        or ctx.environment_destroy_volumes == "true"
    local destroyed_here = ctx.environment_destroy_project_id == ctx.selected_project_id
    local destroy_ok, destroy_response = api:rpc_checked {
        EnvironmentDestroy = {
            project_id = ctx.environment_destroy_project_id,
            confirm_name = typed,
            delete_volumes = delete_volumes,
        },
    }
    if not destroy_ok then
        toast { message = tostring(destroy_response), kind = "error" }
        return
    end
    ctx.environment_destroy_open = "0"
    toast {
        message = string.format(i18n.tr("ambiente %s destruído"), name),
        kind = "success",
    }
    Stream.refresh_now()
    if destroyed_here then
        local origin_id = ctx.environment_origin_project_id or ""
        if origin_id ~= "" then
            Projects.open_project(origin_id)
            return
        end
    end
    M.load()
end

return M
