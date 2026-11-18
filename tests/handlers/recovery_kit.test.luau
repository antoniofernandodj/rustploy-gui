--!nonstrict
-- O arquivo de recuperação (`.rpkit`): o leitor em Luau abre o MESMO vetor de
-- bytes que o teste do daemon gera (`vetor_compartilhado_com_os_clientes`, em
-- features/data_backup/recovery_kit.rs), recusa qualquer byte mudado, e a tela
-- Recuperar preenche os quatro campos com o que leu.

local RecoveryKit = require("recovery_kit")

-- O vetor do daemon, em hex. Se o formato mudar, mude os três testes juntos.
local VECTOR_HEX = "8952504b49540d0a0100070001001200000068747470733a2f2f672e"
    .. "696f2f692e6769740200040000006d61696e030003000000746f6b0400110000004147"
    .. "452d5345435245542d4b45592d31580500050000006167653178060003000000767073"
    .. "070014000000323032362d31312d31385431323a30303a30305a1837508b"

local function from_hex(hex)
    return (hex:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function nova(ctx_inicial)
    local tela = component("views/app.gv", ctx_inicial)
    tela:call("init")
    return tela
end

--- o CRC-32 é o IEEE de sempre (o "check value" da especificação)
function test_recovery_kit__crc32_de_referencia()
    assert_eq(RecoveryKit.crc32("123456789"), 0xCBF43926)
end

--- abre o vetor do daemon com todos os campos
function test_recovery_kit__le_o_vetor_do_daemon()
    local kit, erro = RecoveryKit.decode(from_hex(VECTOR_HEX))
    assert_nil(erro)
    assert_eq(kit.infra_remote, "https://g.io/i.git")
    assert_eq(kit.infra_branch, "main")
    assert_eq(kit.infra_token, "tok")
    assert_eq(kit.private_key, "AGE-SECRET-KEY-1X")
    assert_eq(kit.public_key, "age1x")
    assert_eq(kit.server, "vps")
    assert_eq(kit.created_at, "2026-11-18T12:00:00Z")
end

--- qualquer byte mudado é recusado, com mensagem (nunca um kit errado)
function test_recovery_kit__qualquer_byte_mudado_e_recusado()
    local bytes = from_hex(VECTOR_HEX)
    for index = 1, #bytes do
        local trocado = string.char(bit32.bxor(string.byte(bytes, index), 1))
        local danificado = bytes:sub(1, index - 1)
            .. trocado
            .. bytes:sub(index + 1)
        local kit, erro = RecoveryKit.decode(danificado)
        assert_nil(kit, "byte " .. index .. " mudado passou")
        assert_not_nil(erro)
    end
end

--- truncado, com sobra, em modo texto ou sem ser um kit: cada um diz o quê
function test_recovery_kit__mensagens_de_cada_estrago()
    local bytes = from_hex(VECTOR_HEX)
    local _, truncado = RecoveryKit.decode(bytes:sub(1, #bytes - 1))
    assert_not_nil(truncado)
    local _, sobra = RecoveryKit.decode(bytes .. "\n")
    assert_not_nil(sobra)
    -- \r\n virou \n (conversão de fim de linha)
    local _, fim_de_linha =
        RecoveryKit.decode(bytes:sub(1, 6) .. bytes:sub(8))
    assert_true(
        string.find(fim_de_linha, "line-ending", 1, true) ~= nil,
        fim_de_linha
    )
    local _, texto = RecoveryKit.decode("AGE-SECRET-KEY-1ABC\n")
    assert_true(string.find(texto, "not a Rustploy", 1, true) ~= nil, texto)
end

--- a tela Recuperar preenche os quatro campos com o que o arquivo trouxe
function test_recovery_kit__preenche_a_tela_recuperar()
    local tela = nova({})
    tela:set("kit_hex", VECTOR_HEX)
    tela:eval([[
        local hex = ctx.kit_hex
        local bytes = hex:gsub("..", function(pair)
            return string.char(tonumber(pair, 16))
        end)
        local kit = require("recovery_kit").decode(bytes)
        require("handlers/recover").fill_from_kit(kit)
    ]])
    assert_eq(tela:get("recover_remote"), "https://g.io/i.git")
    assert_eq(tela:get("recover_branch"), "main")
    assert_eq(tela:get("recover_token"), "tok")
    assert_eq(tela:get("recover_key"), "AGE-SECRET-KEY-1X")
    assert_true(
        string.find(tela:get("recover_message"), "vps", 1, true) ~= nil,
        tela:get("recover_message")
    )
end
