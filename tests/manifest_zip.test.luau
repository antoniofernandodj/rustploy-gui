local ManifestZip = require("manifest_zip")

local dir = "/tmp/rustploy_gui_test_" .. tostring(os.time())

--- ida e volta preserva yaml e toml
function test_ida_e_volta_preserva_yaml_e_toml()
    local path = dir .. "/ok.zip"
    local ok = ManifestZip.write(path, "svc: yaml", "vars = 1")
    assert_eq(ok, true)
    local got = ManifestZip.read(path)
    assert_eq(got.ok, true)
    assert_eq(got.yaml, "svc: yaml")
    assert_eq(got.toml, "vars = 1")
end

--- recusa arquivo extra
function test_recusa_arquivo_extra()
    local path = dir .. "/extra.zip"
    zip_write(path, {
        { name = "a.yml", text = "y" },
        { name = "b.toml", text = "t" },
        { name = "readme.txt", text = "x" },
    })
    local got = ManifestZip.read(path)
    assert_eq(got.ok, false)
    assert_has(got.error, "readme.txt")
end

--- recusa subpasta
function test_recusa_subpasta()
    local path = dir .. "/sub.zip"
    zip_write(path, {
        { name = "a.yml", text = "y" },
        { name = "b.toml", text = "t" },
        { name = "pasta/c.toml", text = "t" },
    })
    assert_eq(ManifestZip.read(path).ok, false)
end

--- recusa sem toml
function test_recusa_sem_toml()
    local path = dir .. "/notoml.zip"
    zip_write(path, { { name = "only.yml", text = "y" } })
    local got = ManifestZip.read(path)
    assert_eq(got.ok, false)
    assert_has(got.error, ".toml")
end

--- recusa dois yaml
function test_recusa_dois_yaml()
    local path = dir .. "/twoyaml.zip"
    zip_write(path, {
        { name = "a.yml", text = "y" },
        { name = "b.yaml", text = "y2" },
        { name = "c.toml", text = "t" },
    })
    local got = ManifestZip.read(path)
    assert_eq(got.ok, false)
    assert_has(got.error, ".yml")
end

--- zip inexistente dá erro
function test_zip_inexistente_da_erro()
    assert_eq(ManifestZip.read(dir .. "/nao_existe.zip").ok, false)
end
