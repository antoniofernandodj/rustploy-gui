--!nonstrict
local DockerCleanup = require("format/docker_cleanup")

local function target(id, kind, project_id, warm, extra)
    local t = {
        id = id,
        kind = kind,
        project_id = project_id,
        project_name = project_id == "prj_flow" and "Flow" or "Site",
        name = "nome-" .. id,
        warm = warm,
        default_warm = warm,
        pre_deploy = false,
    }
    for k, v in pairs(extra or {}) do
        t[k] = v
    end
    return t
end

local TARGETS = {
    target("svc_api", "Service", "prj_flow", true),
    target("job_migrate", "Job", "prj_flow", true, { pre_deploy = true }),
    target("svc_web", "Service", "prj_site", false),
}

--- um cabeçalho por projeto e os itens embaixo, na ordem do daemon
function test_lista_agrupa_por_projeto()
    local rows = DockerCleanup.warm_target_rows(TARGETS, nil)
    assert_eq(#rows, 5)
    assert_eq(rows[1].kind, "project")
    assert_eq(rows[1].label, "Flow")
    assert_eq(rows[2].id, "svc_api")
    assert_eq(rows[2].label, "nome-svc_api")
    assert_eq(rows[3].label, "Job: nome-job_migrate")
    assert_eq(rows[3].pre_deploy, "true")
    assert_eq(rows[4].label, "Site")
    assert_eq(rows[5].checked, "false")
end

--- a escolha ainda não salva vence a do daemon
function test_escolha_pendente_vence()
    local rows = DockerCleanup.warm_target_rows(TARGETS, { svc_api = false, svc_web = true })
    assert_eq(rows[2].checked, "false")
    assert_eq(rows[5].checked, "true")
end

--- sem lista ainda, nada
function test_sem_lista()
    assert_eq(#DockerCleanup.warm_target_rows(nil, nil), 0)
end

--- toggle do serviço: travado e desmarcado quando a limpeza está desligada
function test_toggle_travado_sem_limpeza()
    local choice = DockerCleanup.service_warm_choice(
        { cleanup_enabled = false, warm_after_cleanup = true, targets = TARGETS },
        "svc_api"
    )
    assert_eq(choice.present, "true")
    assert_eq(choice.locked, "true")
    assert_eq(choice.checked, "false")
    assert_true(string.find(choice.locked_reason, "cleanup is off", 1, true) ~= nil)
end

--- toggle do serviço: travado quando o aquecimento geral está desligado
function test_toggle_travado_sem_aquecimento()
    local choice = DockerCleanup.service_warm_choice(
        { cleanup_enabled = true, warm_after_cleanup = false, targets = TARGETS },
        "svc_api"
    )
    assert_eq(choice.locked, "true")
    assert_true(string.find(choice.locked_reason, "Warming after cleanup is off", 1, true) ~= nil)
end

--- toggle do serviço: editável com tudo ligado, com a escolha do daemon
function test_toggle_editavel()
    local response = { cleanup_enabled = true, warm_after_cleanup = true, targets = TARGETS }
    local api = DockerCleanup.service_warm_choice(response, "svc_api")
    assert_eq(api.locked, "false")
    assert_eq(api.checked, "true")
    assert_eq(DockerCleanup.service_warm_choice(response, "svc_web").checked, "false")
    assert_eq(DockerCleanup.service_warm_choice(response, "svc_sem_build").present, "false")
end
