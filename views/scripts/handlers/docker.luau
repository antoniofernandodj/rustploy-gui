--!strict
--!nolint FunctionUnused
-- handlers/docker.luau — limpeza de recursos Docker sem uso (imagens, volumes,
-- redes). A aba se atualiza no próximo snapshot (2s).

local State = require("../state")
local Helpers = require("../helpers")
local format = require("../format")
local Stream = require("stream")

local function prune(command: any, label: string): ()
    local api = State.api
    if not api then
        return
    end
    ctx.docker_message = label
    local rpc_ok, rpc_response = api:rpc_checked(command)
    if rpc_ok and rpc_response.PruneResult then
        ctx.docker_message = string.format(
            i18n.tr("removidos: %d · %s liberados"),
            rpc_response.PruneResult.count or 0,
            format.format_bytes(rpc_response.PruneResult.reclaimed_bytes)
        )
    elseif rpc_ok then
        ctx.docker_message = i18n.tr("limpeza concluída")
    else
        ctx.docker_message = i18n.tr("erro: ") .. rpc_response
    end
end

function docker_prune_containers(): ()
    local confirmed = confirm {
        title = i18n.tr("Limpar containers parados?"),
        message = i18n.tr("Todos os containers parados serão removidos (docker container prune). Ação irreversível."),
        confirm_label = i18n.tr("Limpar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    prune("PruneContainers", i18n.tr("removendo containers parados…"))
end

function docker_prune_images(): ()
    local confirmed = confirm {
        title = i18n.tr("Limpar imagens sem uso?"),
        message = i18n.tr("As imagens sem uso serão removidas agora. Essa limpeza não pode ser desfeita."),
        confirm_label = i18n.tr("Limpar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    local all = Helpers.is_true(ctx.docker_prune_all_images)
    prune(
        { PruneImages = { all = all } },
        all and i18n.tr("removendo TODAS as imagens sem uso…")
            or i18n.tr("removendo imagens dangling…")
    )
end

function docker_prune_volumes(): ()
    local confirmed = confirm {
        title = i18n.tr("Limpar volumes sem uso?"),
        message = i18n.tr("Os volumes sem uso serão removidos agora. Essa limpeza não pode ser desfeita."),
        confirm_label = i18n.tr("Limpar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    local all = Helpers.is_true(ctx.docker_prune_all_volumes)
    prune({ PruneVolumes = { all = all } }, i18n.tr("removendo volumes sem uso…"))
end

function docker_prune_networks(): ()
    local confirmed = confirm {
        title = i18n.tr("Limpar redes sem uso?"),
        message = i18n.tr("As redes sem uso serão removidas agora. Essa limpeza não pode ser desfeita."),
        confirm_label = i18n.tr("Limpar"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    prune("PruneNetworks", i18n.tr("removendo redes sem uso…"))
end

-- ── Remoção INDIVIDUAL (por item) ───────────────────────────────────────────
-- Diferente do prune (em lote), remove UM recurso escolhido. Refresca na hora
-- (refresh_now) para a linha sumir sem esperar o snapshot de 2s. O Docker
-- recusa remover recursos em uso (sem force) — o erro volta e é exibido em
-- docker_message.

local function remove_one(command: any, doing: string): ()
    local api = State.api
    if not api then
        return
    end
    ctx.docker_message = doing
    local rpc_ok, rpc_response = api:rpc_checked(command)
    if rpc_ok then
        ctx.docker_message = i18n.tr("removido")
        Stream.refresh_now()
    else
        ctx.docker_message = i18n.tr("erro: ") .. tostring(rpc_response)
    end
end

-- Cada par confirm→do_* espelha o padrão de delete_deployment: o `confirm`
-- suspende e, se o usuário confirmar, chama o handler `do_*` na hora com o
-- id/name capturado no escopo.
function docker_remove_container(container_id: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover container?"),
        message = i18n.tr("O container parado será removido (docker rm). Ação irreversível."),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    remove_one(
        { RemoveContainer = { id = container_id } },
        i18n.tr("removendo container…")
    )
end

-- Para um container ÓRFÃO ("removido no git"): o daemon recusa o que ainda pertence a um
-- serviço do estado (um serviço se para pelo serviço; senão o watchdog o religa).
-- Depois de parar, o botão Remover (docker_remove_container) fica disponível.
function docker_stop_container(container_id: string): ()
    local api = State.api
    if not api then
        return
    end
    ctx.docker_message = i18n.tr("parando container…")
    local rpc_ok, rpc_response = api:rpc_checked { StopContainer = { id = container_id } }
    if rpc_ok then
        ctx.docker_message = i18n.tr("parado")
        Stream.refresh_now()
    else
        ctx.docker_message = i18n.tr("erro: ") .. tostring(rpc_response)
    end
end

function docker_remove_image(image_id: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover imagem?"),
        message = i18n.tr("A imagem será removida (docker rmi). Falha se algum container a referencia."),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    remove_one({ RemoveImage = { id = image_id } }, i18n.tr("removendo imagem…"))
end

function docker_remove_volume(name: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover volume?"),
        message = i18n.tr("O volume será removido (docker volume rm). Falha se estiver em uso. Ação irreversível."),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    remove_one({ RemoveVolume = { name = name } }, i18n.tr("removendo volume…"))
end

-- "Somente em uso" (on_toggle="docker_only_used:<chave>"): grava a chave e
-- remonta as listas — o filtro mora em format.docker_* (a tableview desenha
-- toda linha que recebe).
function docker_only_used(key: string?, value: string?): ()
    if key then
        ctx[key] = value or ""
    end
    Stream.rebuild_lists()
end

function docker_remove_network(network_id: string): ()
    local confirmed = confirm {
        title = i18n.tr("Remover rede?"),
        message = i18n.tr("A rede será removida (docker network rm). Falha se houver container anexado."),
        confirm_label = i18n.tr("Remover"),
        destructive = true,
    }

    if not confirmed then
        return
    end

    remove_one({ RemoveNetwork = { id = network_id } }, i18n.tr("removendo rede…"))
end
