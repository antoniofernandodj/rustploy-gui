--!strict
--!nolint FunctionUnused
-- handlers/registry.luau — sub-aba Docker > Registry: navega repo→tags (fetch
-- sob demanda, tags não vêm no snapshot periódico), remove tag/repositório e
-- executa o GC. Registry só existe pela Fase 1 do backend (push/pull via
-- docker CLI); esta tela não cria/edita nada.

local State = require("../state")
local format = require("../format")
local Stream = require("stream")

local M = {}

-- Abre a visão de tags de um repositório: fetch on-demand (tags não vêm no
-- snapshot periódico, só a lista de repos).
function registry_open_repo(name: string): ()
    local api = State.api
    if not api then
        return
    end
    ctx.registry_selected_repo = name
    ctx.registry_tags_loading = "true"
    local registry_tag_list_ok, registry_tag_list_response = api:rpc_checked{ RegistryTagList = { repo = name } }
    if registry_tag_list_ok and registry_tag_list_response.RegistryTags then
        ctx.registry_tags = format.registry_tags(registry_tag_list_response.RegistryTags)
        ctx.registry_tags_count = tostring(#registry_tag_list_response.RegistryTags)
        ctx.registry_message = ""
    else
        ctx.registry_tags = "[]"
        ctx.registry_tags_count = "0"
        ctx.registry_message = "erro: " .. tostring(registry_tag_list_response)
    end
    ctx.registry_tags_loading = "false"
end

function registry_close_repo(): ()
    ctx.registry_selected_repo = ""
    ctx.registry_tags = "[]"
    ctx.registry_tags_count = "0"
end

-- ── Remoção ──────────────────────────────────────────────────────────────
-- Mesmo padrão confirm→do_* de handlers/docker.luau: o `confirm` suspende e, se
-- confirmado, chama o `do_*` na hora com o argumento capturado no escopo. O
-- repositório é lido de ctx.registry_selected_repo (a tag só é visível dentro de
-- um repo já aberto).

function registry_remove_tag(tag_name: string): ()
    local confirmed = confirm{
        title = "Remover tag?",
        message = "A tag será removida. Se outra tag apontar pro mesmo manifest (mesma imagem), ela também é removida — o delete é por digest, não por tag. O disco é liberado pelo botão \"Executar GC\". Ação irreversível.",
        confirm_label = "Remover",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    local repo = ctx.registry_selected_repo
    if not api or not repo or repo == "" then
        return
    end
    ctx.registry_message = "removendo tag…"
    local registry_tag_delete_ok, registry_tag_delete_response = api:rpc_checked{
        RegistryTagDelete = { repo = repo, tag = tag_name }
    }
    if registry_tag_delete_ok then
        ctx.registry_message = "removida"
        registry_open_repo(repo)
        Stream.refresh_now()
    else
        ctx.registry_message = "erro: " .. tostring(registry_tag_delete_response)
    end
end



function registry_remove_repo(name: string): ()
    local confirmed = confirm{
        title = "Remover repositório?",
        message = "Todas as tags e manifests do repositório serão removidos. O disco é liberado pelo botão \"Executar GC\". Ação irreversível.",
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
    ctx.registry_message = "removendo repositório…"
    local registry_repo_delete_ok, registry_repo_delete_response = api:rpc_checked{ RegistryRepoDelete = { repo = name } }
    if registry_repo_delete_ok then
        ctx.registry_message = "removido"
        if ctx.registry_selected_repo == name then
            registry_close_repo()
        end
        Stream.refresh_now()
    else
        ctx.registry_message = "erro: " .. tostring(registry_repo_delete_response)
    end
end

-- ── GC ───────────────────────────────────────────────────────────────────
-- Libera do disco o que nenhuma tag alcança: manifests pendurados (tag
-- republicada), blobs órfãos de remoções anteriores e uploads abandonados.
-- Imagens taggeadas nunca são afetadas. Também roda sozinho 1x/dia no daemon.

function registry_gc(): ()
    local confirmed = confirm{
        title = "Executar GC?",
        message = "Remove do disco blobs e manifests que nenhuma tag referencia (sobras de remoções e de tags republicadas) e uploads abandonados há mais de 24h. Imagens com tag não são afetadas.",
        confirm_label = "Executar",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.registry_message = "executando GC…"
    local registry_gc_ok, registry_gc_response = api:rpc_checked("RegistryGc")
    if registry_gc_ok and registry_gc_response.RegistryGcResult then
        ctx.registry_message = string.format("GC: %d arquivo(s) removido(s) · %s liberados",
            registry_gc_response.RegistryGcResult.blobs_removed or 0,
            format.format_bytes(registry_gc_response.RegistryGcResult.bytes_freed or 0))
        Stream.refresh_now()
    else
        ctx.registry_message = "erro: " .. tostring(registry_gc_response)
    end
end


-- ── Tokens de acesso (Basic auth) ────────────────────────────────────────
-- Lista não vem no snapshot (tela de baixo tráfego) — buscada ao entrar na
-- sub-aba (ver handlers/nav.luau::docker_tab) e reatualizada após criar/
-- revogar um token.
function registry_refresh_tokens(): ()
    local api = State.api
    if not api then
        return
    end
    local registry_token_list_ok, registry_token_list_response = api:rpc("RegistryTokenList")
    if registry_token_list_ok and registry_token_list_response.RegistryTokens then
        ctx.registry_tokens = format.registry_tokens(registry_token_list_response.RegistryTokens)
        ctx.registry_tokens_count = tostring(#registry_token_list_response.RegistryTokens)
    end
end
M.refresh_tokens = registry_refresh_tokens

-- Abre a janela separada de criação (segredo só aparece lá, uma vez — ver
-- new_registry_token_window.gvb/.luau).
function registry_open_token_window(): ()
    open_window{
        component = "new_registry_token", size = "480 420", decorations = false,
        resizable = false,
        data = {
            api_url = ctx.api_url or "",
            api_token = ctx.api_token or "",
            registry_host = ctx.registry_host or "127.0.0.1:5100",
        },
    }
end

function registry_remove_token(name: string): ()
    local confirmed = confirm{
        title = "Revogar token?",
        message = "Qualquer `docker login`/push/pull usando esse token deixa de funcionar imediatamente. Ação irreversível.",
        confirm_label = "Revogar",
        destructive = true,
    }

    if not confirmed then
        return
    end

    local api = State.api
    if not api then
        return
    end
    ctx.registry_message = "revogando token…"
    local registry_token_revoke_ok, registry_token_revoke_response = api:rpc_checked{
        RegistryTokenRevoke = {
            name = name
        }
    }
    if registry_token_revoke_ok then
        ctx.registry_message = "token revogado"
        registry_refresh_tokens()
    else
        ctx.registry_message = "erro: " .. tostring(registry_token_revoke_response)
    end
end

return M
