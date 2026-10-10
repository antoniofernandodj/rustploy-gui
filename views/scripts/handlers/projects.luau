--!strict
--!nolint FunctionUnused
-- handlers/projects.luau — grade de projetos: criar/editar/remover projeto,
-- variáveis de ambiente de projeto, ações de serviço a partir do card do grid
-- (parar/remover), e o "Stop All" de todo o cluster (topbar).

local State = require("../state")
local Helpers = require("../helpers")
local fmt = require("../fmt")
local Stream = require("stream")
local Registry = require("registry")

-- Abrir a lista de serviços de um projeto (grade read-only via snapshot).
function open_project(project_id: string): ()
    ctx.selected_project_id = project_id
    ctx.view = "project_services"
    ctx.project_tab = "services"
    ctx.editing_project = "false"
    ctx.project_action_message = ""
    ctx.project_env_text_open = "false"
    ctx.project_loading = "true"
    Stream.update_open_project()
end

-- ── Criar projeto (agora em uma JANELA à parte) ──────────────────────────

-- Abre a janela de cadastro de projeto (motor Glacier próprio, isolado). Passa a
-- conexão atual (api_url/api_token) via `data` para que a janela chame
-- ProjectCreate por conta própria; ao concluir, ela emite broadcast(
-- "project_created"), recebido por `on_broadcast` abaixo. Ver
-- views/new_project_form.gvb + scripts/new_project_window.luau.
function open_new_project_window(): ()
    open_window{
        component = "new_project", size = "460 340", decorations = false,
        resizable = false,  -- diálogo fixo (borderless, sem alças de resize)
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
        },
    }
end

-- Recebe mensagens de OUTRAS janelas (glacier broadcast). Em ambos os casos
-- força um refresh imediato do snapshot (o card novo aparece na hora, sem
-- esperar o próximo tick do SSE) e confirma num toast:
--   "project_created" — a janela de cadastro de projeto concluiu.
--   "service_created" — a janela do wizard de serviço concluiu (a grade do
--                       projeto aberto é reconstruída pelo update_open_project).
function on_broadcast(event: string, payload: any): ()
    local name = (type(payload) == "table" and payload.name) or ""
    if event == "project_created" then
        toast{
            message = tostring(
                "Projeto \"" .. (name ~= "" and name or "projeto") .. "\" criado"
            ),
            kind = "success"
        }
        Stream.refresh_now()
    elseif event == "service_created" then
        toast{
            message = tostring(
                "Serviço \"" .. (name ~= "" and name or "serviço") .. "\" criado"
            ),
            kind = "success"
        }
        Stream.refresh_now()
    elseif event == "job_created" then
        toast{
            message = tostring(
                "Job \"" .. (name ~= "" and name or "job") .. "\" criado"
            ),
            kind = "success"
        }
        Stream.refresh_now()
    elseif event == "job_updated" then
        toast{
            message = tostring(
                "Job \"" .. (name ~= "" and name or "job") .. "\" salvo"
            ),
            kind = "success"
        }
        Stream.refresh_now()
    elseif event == "registry_token_created" then
        toast{
            message = tostring(
                "Token \"" .. (name ~= "" and name or "token") .. "\" criado"
            ),
            kind = "success"
        }
        Registry.refresh_tokens()
    end
end

-- ── Criar / remover projeto ──────────────────────────────────────────────

-- NOTA: create_project (formulário inline, removido da UI em favor da janela
-- acima) é mantido por ser reutilizável — um fluxo de criação embutido poderia
-- voltar a chamá-lo. Hoje não há call-site na UI.
function create_project(): ()
    local api = State.api
    if not api then
        return
    end
    local name = Helpers.trim(ctx.new_project_inline_name)
    if name == "" then
        ctx.error_new_project_inline_name = "informe um nome"
        return
    end
    ctx.error_new_project_inline_name = ""
    local description = Helpers.trim(ctx.new_project_inline_description)
    local create_command = {
        ProjectCreate = {
            name = name,
            description = (description ~= "" and description or nil)
        }
    }
    ctx.new_project_inline_message = "criando…"
    local rpc_ok, rpc_response = api:rpc_checked(create_command)
    if rpc_ok then
        ctx.new_project_inline_name = ""
        ctx.new_project_inline_description = ""
        ctx.new_project_inline_message = "projeto criado"
        toast{
            message = tostring("Projeto \"" .. name .. "\" criado"),
            kind = "success"
        }
        Stream.refresh_now()
    else
        ctx.new_project_inline_message = "erro: " .. rpc_response
        toast{
            message = tostring(rpc_response),
            kind = "error"
        }
    end
end

function delete_project(project_id: string): ()
    if project_id == "" then
        return
    end
    local confirmed = confirm{
        title = "Remover projeto?",
        message = "O projeto será removido. Só é possível remover projetos sem serviços.",
        confirm_label = "Remover projeto",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api or project_id == "" then
        return
    end
    ctx.project_action_message = "removendo…"
    local project_delete_ok, project_delete_response = api:rpc_checked{ ProjectDelete = { id = project_id } }
    if project_delete_ok then
        ctx.selected_project_id = ""
        ctx.view = "projects"
        toast{ message = tostring("Projeto removido"), kind = "success" }
        Stream.refresh_now()
    else
        ctx.project_action_message = "erro: " .. project_delete_response
        toast{ message = tostring(project_delete_response), kind = "error" }
    end
end



-- ── Editar projeto (cabeçalho de project_services) ──────────────────────

function edit_project_toggle(): ()
    ctx.edit_project_name = ctx.project_name or ""
    ctx.edit_project_description = ctx.project_description or ""
    ctx.error_edit_project_name = ""
    ctx.editing_project = "true"
end

function cancel_project_edit(): ()
    ctx.editing_project = "false"
end

-- on_validation_error do form(name = edit_project) — o motor já publicou
-- {error_edit_project_name} e acendeu o :invalid; aqui é só o aviso.
function project_edit_show_validation_errors(_erros_json: string?): ()
    toast{ message = "Informe o nome do projeto", kind = "warning" }
end

-- on_submit: só roda com a validação (rules="required" no NOME) aprovada.
function save_project_edit(): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or not api then
        return
    end
    local name = Helpers.trim(ctx.edit_project_name)
    local description = Helpers.trim(ctx.edit_project_description)
    local project_update_ok, project_update_response = api:rpc_checked{
        ProjectUpdate = {
            id = project_id,
            name = name,
            description = (description ~= "" and description or nil)
        }
    }
    if project_update_ok then
        ctx.editing_project = "false"
        ctx.project_action_message = "projeto atualizado"
        ctx.project_name = name
        ctx.project_description = description
    else
        ctx.project_action_message = "erro: " .. project_update_response
    end
end

-- ── Variáveis de ambiente do projeto (aba "Variáveis") ──────────────────
-- Fluxo idêntico ao do serviço: env_vars + env_comments (`# ...` ancorados por
-- key). O `mutate` recebe uma tabela `pe = { env_vars, env_comments }` e a
-- altera in place; enviamos as duas listas no ProjectEnvSet.

local function with_project_env(mutate: (project_env_record: any) -> ()): ()
    local project_id = ctx.selected_project_id or ""
    local api = State.api
    if project_id == "" or not api then
        return
    end
    local project_list_ok, project_list_response = api:rpc("ProjectList")
    if not project_list_ok or not project_list_response.Projects then
        return
    end
    local found_project
    for _, project in ipairs(project_list_response.Projects) do
        if project.id == project_id then
            found_project = project;
            break
        end
    end
    if found_project == nil then
        return
    end
    local project_env_record = {
        env_vars = found_project.env_vars or json.array{},
        env_comments = found_project.env_comments or json.array{},
    }
    mutate(project_env_record)
    local project_env_set_ok, project_env_set_response = api:rpc_checked{
        ProjectEnvSet = {
            project_id = project_id,
            env_vars = project_env_record.env_vars,
            env_comments = project_env_record.env_comments,
        }
    }
    if project_env_set_ok then
        ctx.project_env = fmt.env_json_with_comments(project_env_record.env_vars, project_env_record.env_comments)
        ctx.project_env_count = tostring(#project_env_record.env_vars)
        -- Não sobrescrever o textarea enquanto o usuário edita (ver stream.luau).
        if ctx.project_env_text_open ~= "true" then
            local dotenv = fmt.env_dotenv_with_comments(project_env_record.env_vars, project_env_record.env_comments)
            ctx.project_env_text = dotenv
            ctx.project_env_text_original = dotenv
        end
        toast{ message = tostring("Salvo"), kind = "success" }
    else
        toast{ message = tostring(project_env_set_response), kind = "error" }
    end
end

-- Parser .env (KEY=VALUE, # comentário, <secret:nome>) → (env_vars, comments).
-- Comentários pendentes ancoram na próxima var real (before_key); os do fim
-- ficam sem âncora (before_key = nil).
local function parse_project_dotenv(text: string?): ({any}, {any})
    local vars = json.array{}
    local comments = json.array{}
    local pending = {}
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        local trimmed_line = Helpers.trim(line)
        if trimmed_line == "" then
            -- ignora
        elseif trimmed_line:sub(1, 1) == "#" then
            table.insert(pending, trimmed_line)
        else
            local raw_key, raw_value = trimmed_line:match("^([^=]+)=(.*)$")
            if raw_key and raw_value then
                local key = Helpers.trim(raw_key)
                if key ~= "" then
                    for _, comment_text in ipairs(pending) do
                        table.insert(comments, { text = comment_text, before_key = key })
                    end
                    pending = {}
                    raw_value = Helpers.trim(raw_value)
                    local secret = Helpers.parse_secret_ref(raw_value)
                    local value = secret and { Secret = secret } or { Plain = raw_value }
                    table.insert(vars, { key = key, value = value })
                end
            end
        end
    end
    for _, comment_text in ipairs(pending) do
        table.insert(comments, { text = comment_text, before_key = nil })
    end
    return vars, comments
end

-- Reordena vars/comments a partir de uma ordem de keys (vars + linhas
-- `__c<idx>`): cada comentário reancora na primeira var real que o segue.
local function reorder_project_env(
    vars: {any},
    comments: {any}, keys: {any}
): ({any}, {any})
    local var_keys = {}
    local by_key = {}
    for _, variable in ipairs(vars) do var_keys[variable.key] = true; by_key[variable.key] = variable end
    local seen = {}
    local new_vars = json.array{}
    local new_comments = json.array{}
    for key_position, key in ipairs(keys) do
        local comment_index_text = key:match("^__c(%d+)$")
        if comment_index_text then
            local comment_index = (tonumber(comment_index_text) or 0) + 1 -- __c é 0-based
            local comment = comments[comment_index]
            if comment then
                seen[comment_index] = true
                local anchor = nil
                for key_index = key_position + 1, #keys do
                    if var_keys[keys[key_index]] then anchor = keys[key_index]; break end
                end
                table.insert(new_comments, { text = comment.text, before_key = anchor })
            end
        elseif by_key[key] then
            table.insert(new_vars, by_key[key])
            by_key[key] = nil
        end
    end
    for _, variable in ipairs(vars) do
        if by_key[variable.key] then
            table.insert(new_vars, variable)
        end
    end
    for index, comment in ipairs(comments) do
        if not seen[index] then
            table.insert(new_comments, comment)
        end
    end
    return new_vars, new_comments
end

-- on_validation_error do form(name = project_env_add) — a chave é `rules="required"`;
-- o motor publica {error_project_env_new_key} e acende o :invalid. Aqui é só o aviso.
function project_env_show_validation_errors(_erros_json: string?): ()
    toast{ message = "Informe a chave (KEY)", kind = "warning" }
end

function project_env_add(): ()
    -- rules="required" no form(...) garante a chave preenchida aqui.
    local key = Helpers.trim(ctx.project_env_new_key)
    local raw_value = ctx.project_env_new_value or ""
    -- Duas formas de virar referência de secret (a que o daemon decifra no
    -- deploy, deploy/env_resolve.rs):
    --   • toggle "usar secret" ligado (ver handlers/secrets.luau) — o campo
    --     valor carrega o NOME puro do secret, não o conteúdo;
    --   • `<secret:NOME>`/`secret:NOME` digitado no valor, como no editor .env.
    local secret_name: string? = Helpers.parse_secret_ref(raw_value)
    if ctx.project_env_new_is_secret == "true" and secret_name == nil then
        -- Modo secret: o valor JÁ é o nome (o chip preenche assim).
        local name = Helpers.trim(raw_value)
        if name == "" then
            ctx.error_project_env_new_key = "escolha um secret"
            return
        end
        secret_name = name
    end
    with_project_env(function(project_env_record: any): ()
        local kept = json.array{}
        for _, env_var in ipairs(project_env_record.env_vars) do
            if env_var.key ~= key then
                table.insert(kept, env_var)
            end
        end
        local value = secret_name and { Secret = secret_name } or { Plain = raw_value }
        table.insert(kept, { key = key, value = value })
        project_env_record.env_vars = kept
    end)
    ctx.project_env_new_key = ""
    ctx.project_env_new_value = ""
    ctx.project_env_new_is_secret = "false"
end

function project_env_delete(key: string): ()
    with_project_env(function(project_env_record: any): ()
        local kept = json.array{}
        for _, env_var in ipairs(project_env_record.env_vars) do
            if env_var.key ~= key then
                table.insert(kept, env_var)
            end
        end
        project_env_record.env_vars = kept
        local new_env_comments = json.array{}
        for _, env_comment in ipairs(project_env_record.env_comments) do
            if env_comment.before_key ~= key then
                table.insert(new_env_comments, env_comment)
            end
        end
        project_env_record.env_comments = new_env_comments
    end)
end

function project_env_reorder(reorder_json: string?): ()
    if not reorder_json then
        return
    end
    local json_decode_ok, keys = pcall(json.decode, reorder_json)
    if not json_decode_ok or type(keys) ~= "table" then
        return
    end
    with_project_env(function(project_env_record: any): ()
        local reordered_vars, reordered_comments = reorder_project_env(project_env_record.env_vars, project_env_record.env_comments, keys)
        project_env_record.env_vars = reordered_vars
        project_env_record.env_comments = reordered_comments
    end)
end

-- ── Editor .env do projeto (mesmo fluxo do serviço) ─────────────────────

function project_env_text_toggle(): ()
    ctx.project_env_text_open = (ctx.project_env_text_open == "true") and "false" or "true"
end

function project_env_export(): ()
    -- Abre o editor .env já preenchido (o texto vem do snapshot em project_env_text).
    ctx.project_env_text_open = "true"
end

function project_env_text_cancel(): ()
    ctx.project_env_text = ctx.project_env_text_original or ""
    ctx.project_env_text_open = "false"
end

function project_env_import(): ()
    local vars, comments = parse_project_dotenv(ctx.project_env_text)
    with_project_env(function(project_env_record: any): ()
        project_env_record.env_vars = vars
        project_env_record.env_comments = comments
    end)
    ctx.project_env_text_open = "false"
end

-- ── Ações de serviço a partir de um card do grid do projeto ─────────────
-- O grid se atualiza no próximo snapshot; refresh_now traz isso pra hora.

function service_stop_id(service_id: string): ()
    local confirmed = confirm{
        title = "Parar serviço?",
        message = "O tráfego para este serviço será interrompido até um novo deploy.",
        confirm_label = "Parar",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.project_action_message = "enviando…"
    local service_stop_ok, service_stop_response = api:rpc_checked{ ServiceStop = { service_id = service_id } }
    ctx.project_action_message = service_stop_ok and "serviço parado" or ("erro: " .. service_stop_response)
    if not service_stop_ok then
        toast{ message = tostring(service_stop_response), kind = "error" }
    end
    Stream.refresh_now()
end


function stop_delete_service(service_id: string): ()
    -- Jobs de Schedules gatilhados por este serviço são removidos em cascata
    -- pelo daemon — avisa quais no confirm (jobs_by_id vem do snapshot).
    local deployment_names = {}
    for _, job in State.jobs_by_id do
        if job.trigger_service_id == service_id then
            table.insert(deployment_names, tostring(job.name))
        end
    end
    local message = "O serviço será parado e removido."
    if #deployment_names > 0 then
        table.sort(deployment_names)
        message = message
            .. " Os jobs de Schedules que dependem dele também serão removidos, com histórico: "
            .. table.concat(deployment_names, ", ")
            .. "."
    end
    message = message .. " Essa ação não pode ser desfeita."
    local confirmed = confirm{
        title = "Parar e remover serviço?",
        message = message,
        confirm_label = "Remover",
        destructive = true,
    }

    if not confirmed then
        return
    end


    local api = State.api
    if not api then
        return
    end
    ctx.project_action_message = "removendo…"
    local service_stop_ok, service_stop_response = api:rpc_checked{ ServiceStop = { service_id = service_id } }
    if not service_stop_ok then
        ctx.project_action_message = "erro ao parar: " .. service_stop_response;
        toast{ message = tostring(service_stop_response), kind = "error" }; return
    end
    local service_delete_ok, service_delete_response = api:rpc_checked{ ServiceDelete = { id = service_id } }
    ctx.project_action_message = service_delete_ok and "serviço parado e removido" or ("erro ao remover: " .. service_delete_response)
    if service_delete_ok then
        toast{ message = tostring("Serviço removido"), kind = "success" }
    else
        toast{ message = tostring(service_delete_response), kind = "error" }
    end
    Stream.refresh_now()
end

-- ── Stop All (topbar) ────────────────────────────────────────────────────

function stop_all(): ()
    local confirmed = confirm{
        title = "Parar todos os serviços?",
        message = "Todos os serviços em execução serão parados agora. Você pode reiniciá-los depois com um novo deploy.",
        confirm_label = "Parar todos",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.status_line = "parando todos…"
    local stop_all_managed_ok, stop_all_managed_response = api:rpc_checked("StopAllManaged")
    if stop_all_managed_ok then
        local stopped_count = stop_all_managed_response.StopAllResult and stop_all_managed_response.StopAllResult.count or 0
        ctx.status_line = "parados: " .. tostring(stopped_count)
    else
        ctx.status_line = "erro: " .. stop_all_managed_response
    end
end
