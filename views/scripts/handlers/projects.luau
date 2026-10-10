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
function open_project(id: string): ()
    ctx.selected_project_id = id
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
    local desc = Helpers.trim(ctx.new_project_inline_description)
    local cmd = {
        ProjectCreate = {
            name = name,
            description = (desc ~= "" and desc or nil)
        }
    }
    ctx.new_project_inline_message = "criando…"
    local ok, res = api:rpc_checked(cmd)
    if ok then
        ctx.new_project_inline_name = ""
        ctx.new_project_inline_description = ""
        ctx.new_project_inline_message = "projeto criado"
        toast{
            message = tostring("Projeto \"" .. name .. "\" criado"),
            kind = "success"
        }
        Stream.refresh_now()
    else
        ctx.new_project_inline_message = "erro: " .. res
        toast{
            message = tostring(res),
            kind = "error"
        }
    end
end

function delete_project(id: string): ()
    if id == "" then
        return
    end
    local ok_confirm = confirm{
        title = "Remover projeto?",
        message = "O projeto será removido. Só é possível remover projetos sem serviços.",
        confirm_label = "Remover projeto",
        destructive = true,
    }

    if not ok_confirm then
        return
    end

    local api = State.api
    if not api or id == "" then
        return
    end
    ctx.project_action_message = "removendo…"
    local ok, res = api:rpc_checked{ ProjectDelete = { id = id } }
    if ok then
        ctx.selected_project_id = ""
        ctx.view = "projects"
        toast{ message = tostring("Projeto removido"), kind = "success" }
        Stream.refresh_now()
    else
        ctx.project_action_message = "erro: " .. res
        toast{ message = tostring(res), kind = "error" }
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
    local pid = ctx.selected_project_id or ""
    local api = State.api
    if pid == "" or not api then
        return
    end
    local name = Helpers.trim(ctx.edit_project_name)
    local desc = Helpers.trim(ctx.edit_project_description)
    local ok, res = api:rpc_checked{
        ProjectUpdate = {
            id = pid,
            name = name,
            description = (desc ~= "" and desc or nil)
        }
    }
    if ok then
        ctx.editing_project = "false"
        ctx.project_action_message = "projeto atualizado"
        ctx.project_name = name
        ctx.project_description = desc
    else
        ctx.project_action_message = "erro: " .. res
    end
end

-- ── Variáveis de ambiente do projeto (aba "Variáveis") ──────────────────
-- Fluxo idêntico ao do serviço: env_vars + env_comments (`# ...` ancorados por
-- key). O `mutate` recebe uma tabela `pe = { env_vars, env_comments }` e a
-- altera in place; enviamos as duas listas no ProjectEnvSet.

local function with_project_env(mutate: (pe: any) -> ()): ()
    local pid = ctx.selected_project_id or ""
    local api = State.api
    if pid == "" or not api then
        return
    end
    local ok, res = api:rpc("ProjectList")
    if not ok or not res.Projects then
        return
    end
    local proj
    for _, p in ipairs(res.Projects) do
        if p.id == pid then
            proj = p;
            break
        end
    end
    if proj == nil then
        return
    end
    local pe = {
        env_vars = proj.env_vars or json.array{},
        env_comments = proj.env_comments or json.array{},
    }
    mutate(pe)
    local ok2, res2 = api:rpc_checked{
        ProjectEnvSet = {
            project_id = pid,
            env_vars = pe.env_vars,
            env_comments = pe.env_comments,
        }
    }
    if ok2 then
        ctx.project_env = fmt.env_json_with_comments(pe.env_vars, pe.env_comments)
        ctx.project_env_count = tostring(#pe.env_vars)
        -- Não sobrescrever o textarea enquanto o usuário edita (ver stream.luau).
        if ctx.project_env_text_open ~= "true" then
            local dotenv = fmt.env_dotenv_with_comments(pe.env_vars, pe.env_comments)
            ctx.project_env_text = dotenv
            ctx.project_env_text_original = dotenv
        end
        toast{ message = tostring("Salvo"), kind = "success" }
    else
        toast{ message = tostring(res2), kind = "error" }
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
        local l = Helpers.trim(line)
        if l == "" then
            -- ignora
        elseif l:sub(1, 1) == "#" then
            table.insert(pending, l)
        else
            local k, v = l:match("^([^=]+)=(.*)$")
            if k and v then
                local key = Helpers.trim(k)
                if key ~= "" then
                    for _, c in ipairs(pending) do
                        table.insert(comments, { text = c, before_key = key })
                    end
                    pending = {}
                    v = Helpers.trim(v)
                    local secret = Helpers.parse_secret_ref(v)
                    local value = secret and { Secret = secret } or { Plain = v }
                    table.insert(vars, { key = key, value = value })
                end
            end
        end
    end
    for _, c in ipairs(pending) do
        table.insert(comments, { text = c, before_key = nil })
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
    for _, v in ipairs(vars) do var_keys[v.key] = true; by_key[v.key] = v end
    local seen = {}
    local new_vars = json.array{}
    local new_comments = json.array{}
    for pos, k in ipairs(keys) do
        local ci = k:match("^__c(%d+)$")
        if ci then
            local idx = (tonumber(ci) or 0) + 1 -- __c é 0-based
            local c = comments[idx]
            if c then
                seen[idx] = true
                local anchor = nil
                for j = pos + 1, #keys do
                    if var_keys[keys[j]] then anchor = keys[j]; break end
                end
                table.insert(new_comments, { text = c.text, before_key = anchor })
            end
        elseif by_key[k] then
            table.insert(new_vars, by_key[k])
            by_key[k] = nil
        end
    end
    for _, v in ipairs(vars) do
        if by_key[v.key] then
            table.insert(new_vars, v)
        end
    end
    for idx, c in ipairs(comments) do
        if not seen[idx] then
            table.insert(new_comments, c)
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
    local val = ctx.project_env_new_value or ""
    -- Duas formas de virar referência de secret (a que o daemon decifra no
    -- deploy, deploy/env_resolve.rs):
    --   • toggle "usar secret" ligado (ver handlers/secrets.luau) — o campo
    --     valor carrega o NOME puro do secret, não o conteúdo;
    --   • `<secret:NOME>`/`secret:NOME` digitado no valor, como no editor .env.
    local secret_name: string? = Helpers.parse_secret_ref(val)
    if ctx.project_env_new_is_secret == "true" and secret_name == nil then
        -- Modo secret: o valor JÁ é o nome (o chip preenche assim).
        local name = Helpers.trim(val)
        if name == "" then
            ctx.error_project_env_new_key = "escolha um secret"
            return
        end
        secret_name = name
    end
    with_project_env(function(pe: any): ()
        local kept = json.array{}
        for _, v in ipairs(pe.env_vars) do
            if v.key ~= key then
                table.insert(kept, v)
            end
        end
        local value = secret_name and { Secret = secret_name } or { Plain = val }
        table.insert(kept, { key = key, value = value })
        pe.env_vars = kept
    end)
    ctx.project_env_new_key = ""
    ctx.project_env_new_value = ""
    ctx.project_env_new_is_secret = "false"
end

function project_env_delete(key: string): ()
    with_project_env(function(pe: any): ()
        local kept = json.array{}
        for _, v in ipairs(pe.env_vars) do
            if v.key ~= key then
                table.insert(kept, v)
            end
        end
        pe.env_vars = kept
        local kc = json.array{}
        for _, c in ipairs(pe.env_comments) do
            if c.before_key ~= key then
                table.insert(kc, c)
            end
        end
        pe.env_comments = kc
    end)
end

function project_env_reorder(v: string?): ()
    if not v then
        return
    end
    local ok, keys = pcall(json.decode, v)
    if not ok or type(keys) ~= "table" then
        return
    end
    with_project_env(function(pe: any): ()
        local nv, nc = reorder_project_env(pe.env_vars, pe.env_comments, keys)
        pe.env_vars = nv
        pe.env_comments = nc
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
    with_project_env(function(pe: any): ()
        pe.env_vars = vars
        pe.env_comments = comments
    end)
    ctx.project_env_text_open = "false"
end

-- ── Ações de serviço a partir de um card do grid do projeto ─────────────
-- O grid se atualiza no próximo snapshot; refresh_now traz isso pra hora.

function service_stop_id(id: string): ()
    local ok_confirm = confirm{
        title = "Parar serviço?",
        message = "O tráfego para este serviço será interrompido até um novo deploy.",
        confirm_label = "Parar",
        destructive = true,
    }

    if not ok_confirm then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.project_action_message = "enviando…"
    local ok, res = api:rpc_checked{ ServiceStop = { service_id = id } }
    ctx.project_action_message = ok and "serviço parado" or ("erro: " .. res)
    if not ok then
        toast{ message = tostring(res), kind = "error" }
    end
    Stream.refresh_now()
end


function stop_delete_service(id: string): ()
    -- Jobs de Schedules gatilhados por este serviço são removidos em cascata
    -- pelo daemon — avisa quais no confirm (jobs_by_id vem do snapshot).
    local deployment_names = {}
    for _, job in State.jobs_by_id do
        if job.trigger_service_id == id then
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
    local ok_confirm = confirm{
        title = "Parar e remover serviço?",
        message = message,
        confirm_label = "Remover",
        destructive = true,
    }

    if not ok_confirm then
        return
    end


    local api = State.api
    if not api then
        return
    end
    ctx.project_action_message = "removendo…"
    local ok, res = api:rpc_checked{ ServiceStop = { service_id = id } }
    if not ok then
        ctx.project_action_message = "erro ao parar: " .. res;
        toast{ message = tostring(res), kind = "error" }; return
    end
    local ok2, res2 = api:rpc_checked{ ServiceDelete = { id = id } }
    ctx.project_action_message = ok2 and "serviço parado e removido" or ("erro ao remover: " .. res2)
    if ok2 then
        toast{ message = tostring("Serviço removido"), kind = "success" }
    else
        toast{ message = tostring(res2), kind = "error" }
    end
    Stream.refresh_now()
end

-- ── Stop All (topbar) ────────────────────────────────────────────────────

function stop_all(): ()
    local ok_confirm = confirm{
        title = "Parar todos os serviços?",
        message = "Todos os serviços em execução serão parados agora. Você pode reiniciá-los depois com um novo deploy.",
        confirm_label = "Parar todos",
        destructive = true,
    }

    if not ok_confirm then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.status_line = "parando todos…"
    local ok, res = api:rpc_checked("StopAllManaged")
    if ok then
        local n = res.StopAllResult and res.StopAllResult.count or 0
        ctx.status_line = "parados: " .. tostring(n)
    else
        ctx.status_line = "erro: " .. res
    end
end
