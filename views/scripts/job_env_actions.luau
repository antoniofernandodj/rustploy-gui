--!strict
--!nolint FunctionUnused
-- job_env_actions.luau — as funções globais que os botões do painel das envs do job chamam
-- (components/job_env_panel.component.gv). Só repassam para job_env_core.luau. Carregado pelo app
-- (handlers/job_env.luau) e pela janela Novo/Editar job (new_job_window.luau): cada motor Luau
-- registra as suas.

local Core = require("job_env_core")

function job_env_show_validation_errors(_erros_json: string?): ()
    Core.show_validation_errors()
end
function job_env_add(): ()
    Core.add()
end
function job_env_delete(key: string): ()
    Core.delete(key)
end
function job_env_text_toggle(): ()
    Core.text_toggle()
end
function job_env_text_cancel(): ()
    Core.text_cancel()
end
function job_env_import(): ()
    Core.import()
end
function job_env_reorder(reorder_json: string?): ()
    Core.reorder(reorder_json)
end
-- Linha editável no lugar (o sufixo da ação é a chave gravada da variável).
function job_env_row_key(key: string, value: string): ()
    Core.row_change(key, "key", value)
end
function job_env_row_value(key: string, value: string): ()
    Core.row_change(key, "value", value)
end
function job_env_row_use_secret(key: string, value: any): ()
    Core.row_change(key, "use_secret", value)
end
function job_env_row_secret(key: string, value: string): ()
    Core.row_change(key, "secret", value)
end
function job_env_row_save(key: string): ()
    Core.row_save(key)
end
function job_env_row_reset(key: string): ()
    Core.row_reset(key)
end
function job_env_new_use_secret(value: any): ()
    Core.new_use_secret(value)
end
-- Substituídos pela linha editável (2026-11-16):
-- function job_env_edit_key(key: string): ()
--     Core.edit_key(key)
-- end
-- function job_env_edit_value(key: string): ()
--     Core.edit_value(key)
-- end
-- function job_env_edit_cancel(): ()
--     Core.edit_cancel()
-- end
-- function job_env_edit_apply(): ()
--     Core.edit_apply()
-- end
function job_secret_name_change(name: string, value: string): ()
    Core.secret_name_change(name, value)
end
function job_env_to_secret(key: string): ()
    Core.env_to_secret(key)
end
function job_secret_to_env(name: string): ()
    Core.secret_to_env(name)
end
function job_env_to_project(key: string): ()
    Core.env_to_project(key)
end
function job_secret_to_project(name: string): ()
    Core.secret_to_project(name)
end
function job_secret_add_show_validation_errors(_erros_json: string?): ()
    Core.secret_add_show_validation_errors()
end
function job_secret_add(): ()
    Core.secret_add()
end
function job_secret_delete(name: string): ()
    Core.secret_delete(name)
end
function job_secret_reveal(name: string): ()
    Core.secret_reveal(name)
end
function job_secret_hide(name: string): ()
    Core.secret_hide(name)
end
function job_secret_copy(ref: string): ()
    Core.secret_copy(ref)
end

return {}
