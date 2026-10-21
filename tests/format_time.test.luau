--!nonstrict
local Time = require("format/time")

describe("format/time · durações", function()
    test("format_seconds", function()
        expect(Time.format_seconds(0)):toBe("0s")
        expect(Time.format_seconds(59)):toBe("59s")
        expect(Time.format_seconds(60)):toBe("1m 0s")
        expect(Time.format_seconds(125)):toBe("2m 5s")
    end)

    test("format_seconds aceita string, fração e lixo", function()
        expect(Time.format_seconds("90")):toBe("1m 30s")
        expect(Time.format_seconds(59.9)):toBe("59s")
        expect(Time.format_seconds(nil)):toBe("0s")
        expect(Time.format_seconds("abc")):toBe("0s")
    end)

    test("format_uptime escolhe a maior unidade", function()
        expect(Time.format_uptime(5)):toBe("0m 5s")
        expect(Time.format_uptime(3 * 3600 + 120)):toBe("3h 2m")
        expect(Time.format_uptime(2 * 86400 + 5 * 3600 + 7 * 60)):toBe("2d 5h 7m")
        expect(Time.format_uptime(nil)):toBe("0m 0s")
    end)

    test("format_bytes", function()
        expect(Time.format_bytes(0)):toBe("—")
        expect(Time.format_bytes(nil)):toBe("—")
        expect(Time.format_bytes(2048)):toBe("2 KB")
        expect(Time.format_bytes(5 * 1024 * 1024)):toBe("5 MB")
        expect(Time.format_bytes(1.5 * 1024 * 1024 * 1024)):toBe("1.5 GB")
        expect(Time.format_bytes("4096")):toBe("4 KB")
    end)

    test("format_duration subtrai instantes, mesmo com fuso explícito", function()
        local d = { started_at = "2026-03-01T10:00:00Z", finished_at = "2026-03-01T10:01:05Z" }
        expect(Time.format_duration(d)):toBe("1m 5s")
    end)

    test("format_duration nunca é negativa", function()
        local d = { started_at = "2026-03-01T10:05:00Z", finished_at = "2026-03-01T10:00:00Z" }
        expect(Time.format_duration(d)):toBe("0s")
    end)

    test("format_duration sem started_at válido dá 0s", function()
        expect(Time.format_duration({ started_at = "lixo", finished_at = "2026-03-01T10:00:00Z" })):toBe("0s")
    end)
end)

describe("format/time · hora local", function()
    test("aceitam nil e devolvem vazio (finished_at ainda não preenchido)", function()
        expect(Time.time_hms(nil)):toBe("")
        expect(Time.date_day_month_hour_minute(nil)):toBe("")
        expect(Time.date_day_month_hour_minute_second(nil)):toBe("")
    end)

    test("a forma do texto é fixa, qualquer que seja o fuso da máquina", function()
        local ts = "2026-07-06T12:34:56Z"
        expect(Time.time_hms(ts)):toMatch("^%d%d:%d%d:%d%d$")
        expect(Time.date_day_month_hour_minute(ts)):toMatch("^%d%d/%d%d %d%d:%d%d$")
        expect(Time.date_day_month_hour_minute_second(ts)):toMatch("^%d%d/%d%d %d%d:%d%d:%d%d$")
    end)

    test("os minutos e segundos não dependem do fuso inteiro", function()
        -- Só há fusos de meia hora ou de 45 min, nunca de segundos.
        expect(Time.time_hms("2026-07-06T12:34:56Z")):toMatch(":56$")
    end)
end)

describe("format/time · ponte do <timeedit>", function()
    test("hour_minute_join formata com zeros", function()
        expect(Time.hour_minute_join(3, 7)):toBe("03:07")
        expect(Time.hour_minute_join("23", "59")):toBe("23:59")
    end)

    test("hour_minute_join satura fora da faixa e tolera lixo", function()
        expect(Time.hour_minute_join(99, 99)):toBe("23:59")
        expect(Time.hour_minute_join(-5, -5)):toBe("00:00")
        expect(Time.hour_minute_join(nil, "x")):toBe("00:00")
    end)

    test("hour_minute_split é o inverso de join", function()
        local h, m = Time.hour_minute_split("07:45")
        expect(h):toBe(7)
        expect(m):toBe(45)
        for _, par in { { 0, 0 }, { 12, 30 }, { 23, 59 } } do
            local h2, m2 = Time.hour_minute_split(Time.hour_minute_join(par[1], par[2]))
            expect(h2):toBe(par[1])
            expect(m2):toBe(par[2])
        end
    end)

    test("hour_minute_split de chave vazia, malformada ou fora da faixa vira 0h00", function()
        for _, ruim in { "", "abc", "7", "7:", ":30" } do
            local h, m = Time.hour_minute_split(ruim)
            expect(h):toBe(0)
            expect(m):toBe(0)
        end
        local h, m = Time.hour_minute_split("25:70")
        expect(h):toBe(0)
        expect(m):toBe(0)
        local hn, mn = Time.hour_minute_split(nil)
        expect(hn):toBe(0)
        expect(mn):toBe(0)
    end)
end)

describe("format/time · dias da semana", function()
    test("WEEKDAYS_JSON é um array de sete {id,label} com segunda = 0", function()
        local dias = json.decode(Time.WEEKDAYS_JSON)
        expect(#dias):toBe(7)
        expect(dias[1].id):toBe("0")
        expect(dias[1].label):toBe("Seg")
        expect(dias[7].label):toBe("Dom")
    end)
end)
