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
function job_env_edit_key(key: string): ()
    Core.edit_key(key)
end
function job_env_edit_value(key: string): ()
    Core.edit_value(key)
end
function job_env_edit_cancel(): ()
    Core.edit_cancel()
end
function job_env_edit_apply(): ()
    Core.edit_apply()
end
function job_secret_rename_pick(name: string): ()
    Core.secret_rename_pick(name)
end
function job_rename_cancel(): ()
    Core.rename_cancel()
end
function job_rename_apply(): ()
    Core.rename_apply()
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
