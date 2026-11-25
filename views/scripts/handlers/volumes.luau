--!strict
--!nolint FunctionUnused
-- handlers/volumes.luau — tela Volumes (home/volumes.component.gv): cada
-- volume com quem monta (serviço e caminho; "emprestado" = externo num
-- Compose), dono, órfão, backup; adotar num serviço Application e remover.
-- Também o "usar volume existente" do editor do Compose e a pergunta dos
-- volumes emprestados ao apagar um serviço. Ver
-- docs/arquivo/plano-volumes-tela-e-emprestados.md.

local State = require("../state")

local M = {}

-- O último VolumeList, por nome (adotar e remover partem dele).
local volumes_by_name: { [string]: any } = {}
local volume_list: { any } = {}

local function format_bytes(bytes: number?): string
    if bytes == nil or bytes < 0 then
        return "—"
    end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local value = bytes
    local index = 1
    while value >= 1024 and index < #units do
        value = value / 1024
        index = index + 1
    end
    if index == 1 then
        return string.format("%d B", value)
    end
    return string.format("%.1f %s", value, units[index])
end

local function mounts_label(volume: any): string
    local parts = {}
    for _, mount in ipairs(volume.mounts or {}) do
        local part = mount.service
            .. " ("
            .. mount.project
            .. ") → "
            .. mount.container_path
        if mount.borrowed then
            part = part .. i18n.tr(" · emprestado")
        end
        table.insert(parts, part)
    end
    if #parts == 0 then
        return i18n.tr("ninguém monta")
    end
    return table.concat(parts, "  ·  ")
end

local function status_label(volume: any): (string, string)
    if volume.orphan_of then
        return string.format(i18n.tr("órfão: %s"), volume.orphan_of), "warn"
    end
    if volume.in_use then
        return i18n.tr("em uso"), "ok"
    end
    return i18n.tr("sem uso"), "muted"
end

local function application_service_options(): { any }
    local options = {}
    local snap = State.snap
    for _, pair in ipairs((snap and snap.services) or {}) do
        local service = pair.service
        if service.spec.source.Compose == nil then
            table.insert(options, {
                id = service.id,
                label = service.spec.name .. " (" .. (pair.project_name or "") .. ")",
            })
        end
    end
    table.sort(options, function(left: any, right: any)
        return left.label < right.label
    end)
    return options
end

function M.publish(): ()
    local show_anonymous = ctx.volumes_show_anonymous == true
        or ctx.volumes_show_anonymous == "true"
    local only_orphans = ctx.volumes_only_orphans == true
        or ctx.volumes_only_orphans == "true"
    local rows = {}
    for _, volume in ipairs(volume_list) do
        if (show_anonymous or not volume.anonymous) and (not only_orphans or volume.orphan_of) then
            local status, kind = status_label(volume)
            table.insert(rows, {
                name = volume.name,
                mounts = mounts_label(volume),
                size = format_bytes(volume.size_bytes),
                status = status,
                status_kind = kind,
                backup = volume.has_backup_policy and i18n.tr("backup ligado") or "",
                can_remove = volume.in_use and "0" or "1",
                -- Sem uso de ninguém: adotar um volume em uso poria dois
                -- containers nos mesmos dados.
                can_adopt = (#(volume.mounts or {}) == 0 and not volume.in_use)
                        and "1"
                    or "0",
            })
        end
    end
    ctx.volumes_rows = json.array(rows)
    ctx.volumes_count = tostring(#rows)
end

function M.load(): ()
    local api = State.api
    if not api then
        return
    end
    local list_ok, list_response = api:rpc("VolumeList")
    volume_list = {}
    volumes_by_name = {}
    if list_ok and list_response.Volumes then
        volume_list = list_response.Volumes
        for _, volume in ipairs(volume_list) do
            volumes_by_name[volume.name] = volume
        end
    end
    ctx.volumes_adopt_open = ctx.volumes_adopt_open or "0"
    M.publish()
end

-- Volumes que dá para escolher no "usar volume existente": nomeados, sem
-- quem monte (os órfãos primeiro).
function M.unused_options(): { any }
    local options = {}
    for _, volume in ipairs(volume_list) do
        if not volume.anonymous and #(volume.mounts or {}) == 0 and not volume.in_use then
            local label = volume.name
            if volume.orphan_of then
                label = label .. " — " .. string.format(i18n.tr("órfão: %s"), volume.orphan_of)
            end
            table.insert(options, {
                name = volume.name,
                label = label,
                orphan = volume.orphan_of ~= nil,
            })
        end
    end
    table.sort(options, function(left: any, right: any)
        if left.orphan ~= right.orphan then
            return left.orphan
        end
        return left.name < right.name
    end)
    return options
end

-- Os volumes emprestados (externos) que um serviço Compose monta, pelo último
-- VolumeList (recarregado antes).
function M.borrowed_by(service_id: string): { string }
    M.load()
    local names = {}
    for _, volume in ipairs(volume_list) do
        for _, mount in ipairs(volume.mounts or {}) do
            if mount.service_id == service_id and mount.borrowed then
                table.insert(names, volume.name)
                break
            end
        end
    end
    return names
end

function volumes_refresh(): ()
    M.load()
end

function volumes_toggle(key: string?, value: any): ()
    if key then
        ctx[key] = value
    end
    M.publish()
end

function volumes_adopt(volume_name: string): ()
    ctx.volumes_adopt_open = "1"
    ctx.volumes_adopt_name = volume_name
    ctx.volumes_adopt_title = string.format(i18n.tr("Adotar %s num serviço"), volume_name)
    ctx.volumes_adopt_service_options = json.array(application_service_options())
    ctx.volumes_adopt_service = ""
    ctx.volumes_adopt_target = ""
end

function volumes_adopt_cancel(): ()
    ctx.volumes_adopt_open = "0"
end

function volumes_adopt_confirm(): ()
    local api = State.api
    local service_id = ctx.volumes_adopt_service or ""
    local target = (tostring(ctx.volumes_adopt_target or "")):match("^%s*(.-)%s*$") or ""
    if not api or service_id == "" or target == "" then
        toast {
            message = i18n.tr("Escolha o serviço e o caminho no container."),
            kind = "error",
        }
        return
    end
    local attach_ok, attach_response = api:rpc_checked {
        ServiceVolumeAttach = {
            service_id = service_id,
            volume = {
                host_path = ctx.volumes_adopt_name,
                container_path = target,
                read_only = false,
            },
        },
    }
    if attach_ok then
        toast {
            message = string.format(
                i18n.tr("%s montado em %s: vale no próximo deploy"),
                ctx.volumes_adopt_name,
                target
            ),
            kind = "success",
        }
        ctx.volumes_adopt_open = "0"
        M.load()
    else
        toast { message = tostring(attach_response), kind = "error" }
    end
end

function volumes_remove(volume_name: string): ()
    local volume = volumes_by_name[volume_name]
    local api = State.api
    if not volume or not api then
        return
    end
    local confirmed = confirm {
        title = string.format(i18n.tr("Apagar o volume %s?"), volume_name),
        message = i18n.tr("Os dados dele são apagados, sem volta."),
        confirm_label = i18n.tr("Apagar os dados"),
        destructive = true,
    }
    if not confirmed then
        return
    end
    local remove_ok, remove_response =
        api:rpc_checked { RemoveVolume = { name = volume_name } }
    if remove_ok then
        toast {
            message = string.format(i18n.tr("volume %s apagado"), volume_name),
            kind = "success",
        }
        M.load()
    else
        toast { message = tostring(remove_response), kind = "error" }
    end
end

-- ── "Usar volume existente" no editor do Compose ────────────────────────────

function compose_volume_pick(): ()
    M.load()
    ctx.compose_volume_options = json.array(M.unused_options())
    ctx.compose_volume_choice = ""
    ctx.compose_volume_open = "1"
end

function compose_volume_cancel(): ()
    ctx.compose_volume_open = "0"
end

function compose_volume_insert(): ()
    local api = State.api
    local choice = ctx.compose_volume_choice or ""
    if not api or choice == "" then
        return
    end
    local insert_ok, insert_response = api:rpc_checked {
        ComposeInsertExternalVolume = {
            content = ctx.service_compose or "",
            volume_name = choice,
        },
    }
    if insert_ok and insert_response.ComposeWithVolume then
        ctx.service_compose = insert_response.ComposeWithVolume.content
        ctx.compose_volume_open = "0"
        toast {
            message = string.format(
                i18n.tr("Volume declarado. Monte num serviço com `- %s:/caminho` e salve."),
                insert_response.ComposeWithVolume.key
            ),
            kind = "success",
        }
    else
        toast { message = tostring(insert_response), kind = "error" }
    end
end

return M
