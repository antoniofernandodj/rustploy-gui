local ManifestZip = require("manifest_zip")

local dir = "/tmp/rustploy_gui_test_" .. tostring(os.time())

describe("manifest_zip", function()
    test("ida e volta preserva yaml e toml", function()
        local path = dir .. "/ok.zip"
        local ok = ManifestZip.write(path, "svc: yaml", "vars = 1")
        expect(ok):toBe(true)
        local got = ManifestZip.read(path)
        expect(got.ok):toBe(true)
        expect(got.yaml):toBe("svc: yaml")
        expect(got.toml):toBe("vars = 1")
    end)

    test("recusa arquivo extra", function()
        local path = dir .. "/extra.zip"
        zip_write(path, {
            { name = "a.yml", text = "y" },
            { name = "b.toml", text = "t" },
            { name = "readme.txt", text = "x" },
        })
        local got = ManifestZip.read(path)
        expect(got.ok):toBe(false)
        expect(got.error):toContain("readme.txt")
    end)

    test("recusa subpasta", function()
        local path = dir .. "/sub.zip"
        zip_write(path, {
            { name = "a.yml", text = "y" },
            { name = "b.toml", text = "t" },
            { name = "pasta/c.toml", text = "t" },
        })
        expect(ManifestZip.read(path).ok):toBe(false)
    end)

    test("recusa sem toml", function()
        local path = dir .. "/notoml.zip"
        zip_write(path, { { name = "only.yml", text = "y" } })
        local got = ManifestZip.read(path)
        expect(got.ok):toBe(false)
        expect(got.error):toContain(".toml")
    end)

    test("recusa dois yaml", function()
        local path = dir .. "/twoyaml.zip"
        zip_write(path, {
            { name = "a.yml", text = "y" },
            { name = "b.yaml", text = "y2" },
            { name = "c.toml", text = "t" },
        })
        local got = ManifestZip.read(path)
        expect(got.ok):toBe(false)
        expect(got.error):toContain(".yml")
    end)

    test("zip inexistente dá erro", function()
        expect(ManifestZip.read(dir .. "/nao_existe.zip").ok):toBe(false)
    end)
end)
