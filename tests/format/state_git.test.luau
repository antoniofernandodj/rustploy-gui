--!nonstrict
local StateGit = require("format/state_git")
local Dashboard = require("format/dashboard")

local SHA = "da3da09aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

--- sem status ou desligado: nenhum aviso
function test_state_git__sem_status_ou_desligado_nao_ha_aviso()
    assert_eq(StateGit.alert_message(nil), "")
    assert_eq(StateGit.alert_message({ mode = "off", paused_reason = "x" }), "")
    assert_eq(StateGit.alert_message({ mode = "sync" }), "")
end

--- pausa, commit recusado e commits suspensos viram aviso (nessa ordem de prioridade)
function test_state_git__avisos_por_prioridade()
    local paused = StateGit.alert_message({
        mode = "sync",
        paused_reason = "o histórico divergiu",
        incoming_rejected = { sha = SHA, reason = "x" },
    })
    -- (o idioma do harness não é garantido: confere o conteúdo, não a palavra)
    assert_ne(paused, "")
    assert_true(string.find(paused, SHA, 1, true) == nil)
    local rejected = StateGit.alert_message({ mode = "sync", incoming_rejected = { sha = SHA, reason = "x" } })
    assert_ne(rejected, paused, "a pausa tem prioridade e muda o texto")
    assert_true(string.find(rejected, "da3da09", 1, true) ~= nil)
    assert_true(string.find(rejected, SHA, 1, true) == nil, "só o sha curto")
    local blocked = StateGit.alert_message({ mode = "commit", blocked_by_plaintext = 3 })
    assert_true(string.find(blocked, "3", 1, true) ~= nil)
end

--- conjunto de serviços com mudança pendente de deploy
function test_state_git__pending_ids()
    local ids = StateGit.pending_ids({ pending_deploy = { "svc_a", "svc_b" } })
    assert_true(ids["svc_a"])
    assert_true(ids["svc_b"])
    assert_eq(ids["svc_c"], nil)
    assert_eq(next(StateGit.pending_ids(nil)), nil)
end

--- removidos no git: nome, tipo, projeto e sha curto; vazio vira "[]"
function test_state_git__removed_rows()
    assert_eq(StateGit.removed_rows(nil), "[]")
    local rows = json.decode(StateGit.removed_rows({
        removed_in_git = {
            { id = "serviço:s1", kind = "serviço", name = "web", project = "E2E", sha = SHA, at = "2026-11-02T06:28:44Z" },
            { id = "projeto:p1", kind = "projeto", name = "Velho", project = "", sha = SHA, at = "2026-11-02T06:28:44Z" },
        },
    }))
    assert_eq(#rows, 2)
    assert_eq(rows[1].id, "serviço:s1")
    assert_eq(rows[1].name, "web")
    assert_true(string.find(rows[1].detail, "E2E", 1, true) ~= nil)
    assert_true(string.find(rows[1].detail, "da3da09", 1, true) ~= nil)
    assert_true(string.find(rows[2].detail, " ·  ·", 1, true) == nil, "projeto sem projeto-pai não deixa separador vazio")
end

--- auditoria: certeza não pode ser liberada; suspeita sim; liberada pode voltar a travar
function test_state_git__audit_rows()
    local rows = json.decode(StateGit.audit_rows({
        { definite = true, allowed = false, project = "E2E", scope = "serviço api", what = "token de webhook sem cifra" },
        { definite = false, allowed = false, project = "E2E", scope = "projeto", what = "env PASSWORD_MIN_LENGTH" },
        { definite = false, allowed = true, project = "E2E", scope = "projeto", what = "env OUTRA" },
    }))
    assert_eq(#rows, 3)
    assert_eq(rows[1].can_allow, "0")
    assert_eq(rows[1].can_block_again, "0")
    assert_eq(rows[2].can_allow, "1")
    assert_eq(rows[2].index, "2")
    assert_eq(rows[3].can_allow, "0")
    assert_eq(rows[3].can_block_again, "1")
    assert_eq(StateGit.audit_rows(nil), "[]")
end

--- dono do container: o órfão é dito como tal
function test_state_git__container_owner()
    assert_true(string.find(StateGit.container_owner({ removed_in_git = "banco", managed = false }), "banco", 1, true) ~= nil)
    assert_eq(StateGit.container_owner({ project = "P", service = "S" }), "P / S")
    assert_eq(StateGit.container_owner({ managed = true }), "rustploy")
    assert_eq(StateGit.container_owner({}), "—")
end

--- contexto: booleans viram "true"/"false" e os padrões não deixam `nil`
function test_state_git__context_padroes_e_booleans()
    local empty = StateGit.context(nil, nil)
    assert_eq(empty.state_git_mode, "off")
    assert_eq(empty.state_git_is_enabled, "false")
    assert_eq(empty.state_git_is_paused, "false")
    assert_eq(empty.state_git_git_missing, "false")
    assert_eq(empty.state_git_removed, "[]")
    assert_eq(empty.state_git_audit_count, "0")
    local full = StateGit.context({
        mode = "sync",
        git_available = false,
        recovery_configured = false,
        paused_reason = "divergiu",
        ahead = 1,
        behind = 2,
        last_commit = { sha = SHA, at = "2026-11-02T06:28:44Z", subject = "Atualiza projeto E2E" },
        incoming_rejected = { sha = SHA, reason = "motivo" },
        removed_in_git = { { id = "serviço:s1", kind = "serviço", name = "web", project = "E2E", sha = SHA, at = "2026-11-02T06:28:44Z" } },
    }, { { definite = false, allowed = false, project = "", scope = "projeto", what = "env X" } })
    assert_eq(full.state_git_is_sync, "true")
    assert_eq(full.state_git_git_missing, "true")
    assert_eq(full.state_git_recovery_missing, "true")
    assert_eq(full.state_git_is_paused, "true")
    assert_eq(full.state_git_has_rejected, "true")
    assert_eq(full.state_git_ahead_behind_label, "1 / 2")
    assert_eq(full.state_git_last_commit_label, "da3da09 · Atualiza projeto E2E")
    assert_eq(full.state_git_removed_count, "1")
    assert_eq(full.state_git_audit_count, "1")
    assert_eq(full.state_git_rejected_reason, "motivo")
end

--- Runtime → Containers: só o órfão que ainda roda oferece "Parar"
function test_state_git__docker_containers_can_stop_so_no_orfao_rodando()
    local rows = json.decode(Dashboard.docker_containers({
        { id = "a", name = "orfao_vivo", image = "i", state = "running", managed = true, removed_in_git = "web" },
        { id = "b", name = "orfao_parado", image = "i", state = "exited", managed = true, removed_in_git = "web" },
        { id = "c", name = "servico_vivo", image = "i", state = "running", managed = true, project = "P", service = "S" },
    }, nil))
    local by_name = {}
    for _, row in ipairs(rows) do
        by_name[row.id_full] = row
    end
    assert_eq(by_name["a"].can_stop, "1")
    assert_eq(by_name["a"].can_remove, "0")
    assert_eq(by_name["b"].can_stop, "0")
    assert_eq(by_name["b"].can_remove, "1")
    assert_eq(by_name["c"].can_stop, "0", "container de serviço vivo nunca oferece Parar aqui")
end
