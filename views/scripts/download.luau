--!strict
-- download.luau — salvar um arquivo "para baixar" (chave de recuperação, token do registry): vai direto
-- para a pasta Downloads do sistema, sem diálogo e sem sobrescrever (`save_download`, glacier-ui 0.160+).
-- Sem pasta Downloads (ambiente headless), pergunta onde salvar — a pessoa nunca fica sem o arquivo, que
-- muitas vezes é a ÚNICA cópia de um segredo. A webui faz o equivalente por `Blob` + `<a download>`
-- (`downloadTextFile` em `webui/app.js`): mude os dois juntos.

local M = {}

--- Grava `contents` e devolve `(true, caminho)`, ou `(false, mensagem)`. `dialog_title` só aparece se o
--- diálogo de "salvar como" for necessário.
function M.save(filename: string, contents: string, dialog_title: string): (boolean, string)
    local saved, where = save_download(filename, contents)
    if saved then
        return true, where
    end
    local path = save_file { title = dialog_title, default_name = filename }
    if not path then
        return false, i18n.tr("não salvou: nenhum local escolhido (") .. where .. ")"
    end
    local wrote, write_error = write_file(path, contents)
    if not wrote then
        return false, i18n.tr("falha ao gravar: ") .. tostring(write_error)
    end
    return true, path
end

return M
