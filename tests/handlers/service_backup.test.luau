--!nonstrict
-- Aba Dados → Backup no S3: sem conexão os handlers são inertes (o botão pode ser clicado quando a
-- sessão cai) e o texto da última operação cobre os três estados.

local ServiceBackup = require("handlers/service_backup")

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- sem sessão, fazer backup, restaurar e apagar não fazem nada (nem toast)
function test_service_backup__sem_conexao_e_inerte()
    local tela = nova({ selected_service = "svc_1" })
    tela:call("service_backup_now")
    tela:call("service_backup_refresh")
    tela:call("service_backup_restore", "k")
    tela:call("service_backup_delete", "k")
    assert_eq(#tela:toasts(), 0)
end

--- a aba nasce sem lista e sem o botão pronto (o markup nunca lê nil)
function test_service_backup__estado_inicial()
    local tela = nova({})
    assert_eq(tela:get("data_backups_count"), "0")
    assert_eq(tela:get("data_backup_running"), "false")
    assert_eq(tela:get("data_backup_ready"), "false")
end

--- a última operação vira uma linha legível nos três estados
function test_service_backup__linha_da_ultima_operacao()
    assert_eq(ServiceBackup.run_label(nil), "")
    local rodando =
        ServiceBackup.run_label({ op = "backup", state = "running" })
    assert_true(
        string.find(rodando, "andamento", 1, true) ~= nil
            or string.find(rodando, "progress", 1, true) ~= nil
    )
    local falhou = ServiceBackup.run_label({
        op = "restore",
        state = "failed",
        error = "sem espaço",
    })
    assert_true(string.find(falhou, "sem espaço", 1, true) ~= nil)
    local ok = ServiceBackup.run_label({
        op = "backup",
        state = "ok",
        finished_at = "2026-11-11T10:00:05Z",
        size_bytes = 3008554,
    })
    assert_true(
        string.find(ok, "3 MB", 1, true) ~= nil
            or string.find(ok, "2.9 MB", 1, true) ~= nil,
        ok
    )
end

--- o formulário da política ida e volta: semanal, a cada N horas, diário e "nunca configurada" (UTC)
function test_service_backup__formulario_da_politica_ida_e_volta()
    local semanal = ServiceBackup.policy_from_values({
        enabled = "true",
        kind = "weekly",
        weekday = "2",
        time = "04:30",
        hours = "6",
        keep = "5",
        stop = "false",
    })
    assert_eq(semanal.enabled, true)
    assert_eq(semanal.keep, 5)
    assert_eq(semanal.stop, false)
    assert_eq(semanal.recurrence.Weekly.weekday, 2)
    assert_eq(semanal.recurrence.Weekly.hour, 4)
    assert_eq(semanal.recurrence.Weekly.minute, 30)

    local horas = ServiceBackup.form_from_policy({
        enabled = true,
        recurrence = { IntervalHours = 12 },
        keep = 3,
        stop = true,
    })
    assert_eq(horas.kind, "interval")
    assert_eq(horas.hours, "12")
    assert_eq(horas.keep, "3")
    assert_eq(
        ServiceBackup.policy_from_values(horas).recurrence.IntervalHours,
        12
    )

    local diario = ServiceBackup.form_from_policy({
        enabled = false,
        recurrence = { Daily = { hour = 3, minute = 15 } },
        keep = 7,
        stop = true,
    })
    assert_eq(diario.time, "03:15")
    local volta = ServiceBackup.policy_from_values(diario)
    assert_eq(volta.enabled, false)
    assert_eq(volta.recurrence.Daily.hour, 3)
    assert_eq(volta.recurrence.Daily.minute, 15)

    -- nunca configurada: o formulário nasce desligado, com os padrões
    local vazio = ServiceBackup.form_from_policy(nil)
    assert_eq(vazio.enabled, "false")
    assert_eq(vazio.keep, "7")
    assert_eq(vazio.stop, "true")
end

--- sem sessão, salvar a política não faz nada
function test_service_backup__salvar_politica_sem_conexao_e_inerte()
    local tela = nova({ selected_service = "svc_1" })
    tela:call("service_backup_policy_save")
    assert_eq(#tela:toasts(), 0)
end
