--!strict
-- Fixture do teste `busy.rs`. `salvar` imita um handler real: avisa o resultado
-- (toast) e só então relê o estado com mais um fetch.
function init(): ()
end

function salvar(): ()
    toast{ message = "Salvo", kind = "success" }
    fetch("http://127.0.0.1:9/reler")
end

require("busy").install({ "salvar" })
