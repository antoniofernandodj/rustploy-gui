--!nonstrict
local Time = require("format/time")

--- format_seconds
function test_duracoes__format_seconds()
    assert_eq(Time.format_seconds(0), "0s")
    assert_eq(Time.format_seconds(59), "59s")
    assert_eq(Time.format_seconds(60), "1m 0s")
    assert_eq(Time.format_seconds(125), "2m 5s")
end

--- format_seconds aceita string, fração e lixo
function test_duracoes__format_seconds_aceita_string_fracao_e_lixo()
    assert_eq(Time.format_seconds("90"), "1m 30s")
    assert_eq(Time.format_seconds(59.9), "59s")
    assert_eq(Time.format_seconds(nil), "0s")
    assert_eq(Time.format_seconds("abc"), "0s")
end

--- format_uptime escolhe a maior unidade
function test_duracoes__format_uptime_escolhe_a_maior_unidade()
    assert_eq(Time.format_uptime(5), "0m 5s")
    assert_eq(Time.format_uptime(3 * 3600 + 120), "3h 2m")
    assert_eq(Time.format_uptime(2 * 86400 + 5 * 3600 + 7 * 60), "2d 5h 7m")
    assert_eq(Time.format_uptime(nil), "0m 0s")
end

--- format_bytes
function test_duracoes__format_bytes()
    assert_eq(Time.format_bytes(0), "—")
    assert_eq(Time.format_bytes(nil), "—")
    assert_eq(Time.format_bytes(2048), "2 KB")
    assert_eq(Time.format_bytes(5 * 1024 * 1024), "5 MB")
    assert_eq(Time.format_bytes(1.5 * 1024 * 1024 * 1024), "1.5 GB")
    assert_eq(Time.format_bytes("4096"), "4 KB")
end

--- format_duration subtrai instantes, mesmo com fuso explícito
function test_duracoes__format_duration_subtrai_instantes_mesmo_com_fuso_explicito()
    local d = { started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:01:05Z" }
    assert_eq(Time.format_duration(d), "1m 5s")
end

--- format_duration nunca é negativa
function test_duracoes__format_duration_nunca_e_negativa()
    local d = { started_at = "2026-03-01T10:05:00Z", finished_at = "2026-03-01T10:00:00Z" }
    assert_eq(Time.format_duration(d), "0s")
end

--- format_duration sem started_at válido dá 0s
function test_duracoes__format_duration_sem_started_at_valido_da_0s()
    assert_eq(Time.format_duration({ started_at = "lixo", finished_at = "2026-03-01T10:00:00Z" }), "0s")
end

--- aceitam nil e devolvem vazio (finished_at ainda não preenchido)
function test_hora_local__aceitam_nil_e_devolvem_vazio_finished_at_ainda_nao_preenchido()
    assert_eq(Time.time_hms(nil), "")
    assert_eq(Time.date_day_month_hour_minute(nil), "")
    assert_eq(Time.date_day_month_hour_minute_second(nil), "")
end

--- a forma do texto é fixa, qualquer que seja o fuso da máquina
function test_hora_local__a_forma_do_texto_e_fixa_qualquer_que_seja_o_fuso_da_maquina()
    local ts = "2026-07-06T12:34:56Z"
    assert_match(Time.time_hms(ts), "^%d%d:%d%d:%d%d$")
    assert_match(Time.date_day_month_hour_minute(ts), "^%d%d/%d%d %d%d:%d%d$")
    assert_match(Time.date_day_month_hour_minute_second(ts), "^%d%d/%d%d %d%d:%d%d:%d%d$")
end

--- os minutos e segundos não dependem do fuso inteiro
function test_hora_local__os_minutos_e_segundos_nao_dependem_do_fuso_inteiro()
    -- Só há fusos de meia hora ou de 45 min, nunca de segundos.
    assert_match(Time.time_hms("2026-07-06T12:34:56Z"), ":56$")
end

--- hour_minute_join formata com zeros
function test_ponte_do_timeedit__hour_minute_join_formata_com_zeros()
    assert_eq(Time.hour_minute_join(3, 7), "03:07")
    assert_eq(Time.hour_minute_join("23", "59"), "23:59")
end

--- hour_minute_join satura fora da faixa e tolera lixo
function test_ponte_do_timeedit__hour_minute_join_satura_fora_da_faixa_e_tolera_lixo()
    assert_eq(Time.hour_minute_join(99, 99), "23:59")
    assert_eq(Time.hour_minute_join(-5, -5), "00:00")
    assert_eq(Time.hour_minute_join(nil, "x"), "00:00")
end

--- hour_minute_split é o inverso de join
function test_ponte_do_timeedit__hour_minute_split_e_o_inverso_de_join()
    local h, m = Time.hour_minute_split("07:45")
    assert_eq(h, 7)
    assert_eq(m, 45)
    for _, par in { { 0, 0 }, { 12, 30 }, { 23, 59 } } do
        local h2, m2 = Time.hour_minute_split(Time.hour_minute_join(par[1], par[2]))
        assert_eq(h2, par[1])
        assert_eq(m2, par[2])
    end
end

--- hour_minute_split de chave vazia, malformada ou fora da faixa vira 0h00
function test_ponte_do_timeedit__hour_minute_split_de_chave_vazia_malformada_ou_fora_da_faixa_vira_0h00()
    for _, ruim in { "", "abc", "7", "7:", ":30" } do
        local h, m = Time.hour_minute_split(ruim)
        assert_eq(h, 0)
        assert_eq(m, 0)
    end
    local h, m = Time.hour_minute_split("25:70")
    assert_eq(h, 0)
    assert_eq(m, 0)
    local hn, mn = Time.hour_minute_split(nil)
    assert_eq(hn, 0)
    assert_eq(mn, 0)
end

--- WEEKDAYS_JSON é um array de sete {id,label} com segunda = 0
function test_dias_da_semana__weekdays_json_e_um_array_de_sete_id_label_com_segunda_0()
    local dias = json.decode(Time.WEEKDAYS_JSON)
    assert_eq(#dias, 7)
    assert_eq(dias[1].id, "0")
    assert_eq(dias[1].label, "Seg")
    assert_eq(dias[7].label, "Dom")
end
