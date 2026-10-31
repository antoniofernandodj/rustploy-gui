--!strict
--!nolint FunctionUnused
-- handlers/language.luau — idioma da interface: restaura o escolhido da última vez,
-- troca ao vivo e lembra. O catálogo está em locales/ (en.json e pt-BR.json); a locale
-- ativa é a chave `__locale` do contexto, e `i18n.set_locale` a espalha para todas as
-- janelas abertas. Inglês é o padrão.

local STORAGE_KEY = "language"
local LANGUAGE_ENGLISH = "en"
local LANGUAGE_PORTUGUESE = "pt-BR"
local CLASS_SELECTED = "btn btn--primary btn--xs"
local CLASS_UNSELECTED = "btn btn--ghost btn--xs"

local M = {}

-- Aplica a locale na tela e marca qual dos dois botões está ativo.
local function language_apply(locale: string): ()
    -- A linha de status da tela de login é um texto gravado em estado (não se reavalia sozinha):
    -- se ela ainda mostra o "pronto para conectar" da subida, reescreve no idioma novo.
    local status_was_ready = ctx.status_line == i18n.tr("pronto para conectar")
    local active_locale = i18n.set_locale(locale) or LANGUAGE_ENGLISH
    if status_was_ready then
        ctx.status_line = i18n.tr("pronto para conectar")
    end
    local is_portuguese = string.sub(active_locale, 1, 2) == "pt"
    ctx.language_english_class = if is_portuguese then CLASS_UNSELECTED else CLASS_SELECTED
    ctx.language_portuguese_class = if is_portuguese then CLASS_SELECTED else CLASS_UNSELECTED
end

-- Chamado uma vez na subida da janela principal.
function M.restore(): ()
    local stored_language = storage.get(STORAGE_KEY)
    if type(stored_language) == "string" and stored_language ~= "" then
        language_apply(stored_language)
    else
        language_apply(LANGUAGE_ENGLISH)
    end
end

function language_select_english(): ()
    language_apply(LANGUAGE_ENGLISH)
    storage.set(STORAGE_KEY, LANGUAGE_ENGLISH)
end

function language_select_portuguese(): ()
    language_apply(LANGUAGE_PORTUGUESE)
    storage.set(STORAGE_KEY, LANGUAGE_PORTUGUESE)
end

return M
