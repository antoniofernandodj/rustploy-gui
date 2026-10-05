//! Índice das ações dispatcháveis da UI.

use serde_json::{Value, json};

/// Uma ação e onde ela mora.
struct Acao {
    nome: String,
    /// Arquivo relativo a `views/scripts/`, ex.: `handlers/services.luau`.
    origem: String,
}

/// Nome da função global declarada nesta linha, se houver.
fn nome_da_acao(linha: &str) -> Option<&str> {
    let resto = linha.strip_prefix("function ")?;
    let nome = resto.split('(').next()?.trim();

    if nome.is_empty() || nome.contains(['.', ':', ' ']) {
        return None;
    }
    Some(nome)
}

/// Varre um arquivo Luau e devolve suas ações.
fn do_arquivo(origem: &str, conteudo: &str) -> Vec<Acao> {
    conteudo
        .lines()
        .filter_map(nome_da_acao)
        .map(|nome| Acao {
            nome: nome.to_string(),
            origem: origem.to_string(),
        })
        .collect()
}

/// Todos os pares `(caminho, conteúdo)` dos scripts Luau.
#[cfg(debug_assertions)]
fn fontes() -> Vec<(String, String)> {
    fn recolhe(dir: &std::path::Path, base: &std::path::Path, out: &mut Vec<(String, String)>) {
        let Ok(entradas) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entradas.flatten() {
            let caminho = e.path();
            if caminho.is_dir() {
                recolhe(&caminho, base, out);
            } else if caminho.extension().is_some_and(|x| x == "luau") {
                if let Ok(texto) = std::fs::read_to_string(&caminho) {
                    let rel = caminho
                        .strip_prefix(base)
                        .unwrap_or(&caminho)
                        .to_string_lossy()
                        .to_string();
                    out.push((rel, texto));
                }
            }
        }
    }

    let base = std::path::Path::new("views/scripts");
    let mut out = Vec::new();
    recolhe(base, base, &mut out);
    out
}

#[cfg(not(debug_assertions))]
fn fontes() -> Vec<(String, String)> {
    crate::embedded::luau_sources()
        .into_iter()
        .map(|(caminho, texto)| {
            let rel = caminho
                .strip_prefix("scripts/")
                .unwrap_or(&caminho)
                .to_string();
            (rel, texto.to_string())
        })
        .collect()
}

/// O índice, pronto para sair pela API.
pub(super) fn index() -> Value {
    let mut acoes: Vec<Acao> = fontes()
        .iter()
        .flat_map(|(origem, texto)| do_arquivo(origem, texto))
        .collect();

    acoes.sort_by(|a, b| a.nome.cmp(&b.nome));
    acoes.dedup_by(|a, b| a.nome == b.nome);

    let itens: Vec<Value> = acoes
        .iter()
        .map(|a| json!({ "action": a.nome, "source": a.origem }))
        .collect();

    json!({
        "count": itens.len(),
        "actions": itens,
        "how_to_call":
            "POST /agent/ui/action {\"action\":\"<nome>\"} — com \"value\" quando \
             a ação recebe um argumento (o `value` do Luau), sem quando é clique",
        "note":
            "lido da árvore de scripts que o motor executa, não de uma lista \
             escrita à mão — reflete a versão em execução",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconhece_funcao_global() {
        assert_eq!(nome_da_acao("function connect(): ()"), Some("connect"));
        assert_eq!(nome_da_acao("function nav(v: string?): ()"), Some("nav"));
        assert_eq!(nome_da_acao("function init()"), Some("init"));
    }

    /// Auxiliares de módulo e métodos não são dispatcháveis: anunciá-los daria
    /// ao agente nomes que respondem 202 e não fazem nada.
    #[test]
    fn ignora_o_que_nao_e_acao() {
        assert_eq!(nome_da_acao("local function rebuild_lists(): ()"), None);
        assert_eq!(nome_da_acao("function M:headers()"), None);
        assert_eq!(nome_da_acao("function M.new(url)"), None);
        assert_eq!(nome_da_acao("    function aninhada()"), None);
        assert_eq!(nome_da_acao("-- function comentada()"), None);
        assert_eq!(nome_da_acao(""), None);
    }

    #[test]
    fn varre_um_arquivo_inteiro() {
        let fonte = "\
local State = require(\"../state\")

local function helper(): ()
end

function connect(): ()
end

function disconnect(): ()
end
";
        let acoes = do_arquivo("handlers/connection.luau", fonte);
        let nomes: Vec<&str> = acoes.iter().map(|a| a.nome.as_str()).collect();
        assert_eq!(nomes, vec!["connect", "disconnect"]);
        assert_eq!(acoes[0].origem, "handlers/connection.luau");
    }
}
