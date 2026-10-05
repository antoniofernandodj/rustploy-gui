//! Controle da própria janela — o que antes só um clique alcançava.

use glacier_ui::ContextMap;
use std::time::{Duration, Instant};

use glacier_ui::ExternalSender;
use serde_json::{Value, json};

use super::session::SharedSession;

/// Chaves do contexto que **nunca** saem pela API.
const REDIGIDAS: &[&str] = &["api_token", "token"];

/// Quanto esperar o `connect()` da camada Luau concluir.
const TIMEOUT_CONNECT: Duration = Duration::from_secs(30);

/// De quanto em quanto tempo o `connect` reconsulta o espelho.
const POLL: Duration = Duration::from_millis(100);

/// Resultado de um `connect` pedido pela API.
pub(super) enum ConnectOutcome {
    Conectado { remote_url: String },
    Recusado { motivo: String },
    Timeout,
}

/// Entra na sessão: preenche o formulário de login e aciona o botão Connect,
/// exatamente como um usuário faria — e espera o desfecho.
pub(super) async fn connect(
    ui: &ExternalSender,
    session: &SharedSession,
    url: &str,
    token: Option<&str>,
) -> ConnectOutcome {
    ui.patch(vec![
        ("url".into(), url.to_string()),
        ("token".into(), token.unwrap_or_default().to_string()),
        ("error".into(), String::new()),
        ("erro_url".into(), String::new()),
    ]);
    ui.click("connect");

    let comeco = Instant::now();
    loop {
        tokio::time::sleep(POLL).await;

        if let Some(s) = session.get() {
            return ConnectOutcome::Conectado {
                remote_url: s.base_url,
            };
        }

        let motivo = ["error", "erro_url"]
            .iter()
            .filter_map(|k| session.context_key(k))
            .find(|v| !v.trim().is_empty());

        if let Some(motivo) = motivo {
            return ConnectOutcome::Recusado { motivo };
        }

        if comeco.elapsed() >= TIMEOUT_CONNECT {
            return ConnectOutcome::Timeout;
        }
    }
}

/// Sai da sessão.
pub(super) fn disconnect(ui: &ExternalSender) {
    ui.click("disconnect");
}

/// Estado da janela que interessa a quem a dirige de fora.
pub(super) fn state(session: &SharedSession) -> Value {
    let ctx = session.context();
    let get = |k: &str| ctx.get(k).cloned().unwrap_or_default();

    json!({
        "connected": session.get().is_some(),
        "remote_url": session.get().map(|s| s.base_url),
        "screen": get("screen"),
        "view": get("view"),
        "selected_project": get("selected_project"),
        "selected_service": get("selected_service"),
        "search": get("search"),
        "status_line": get("status_line"),
        "error": get("error"),
        "data_loading": get("data_loading") == "true",
        "counts": {
            "projects": get("projects_count"),
            "services": get("services_count"),
            "deployments": get("deployments_count"),
            "jobs": get("jobs_count"),
        },
    })
}

/// Chaves avulsas do contexto, para o que o resumo curado não cobre.
pub(super) fn keys(session: &SharedSession, pedidas: &str) -> Value {
    let ctx = session.context();
    let mut out = serde_json::Map::new();

    for k in pedidas.split(',').map(str::trim).filter(|k| !k.is_empty()) {
        if REDIGIDAS.contains(&k) {
            out.insert(k.to_string(), json!("<redigido>"));
            continue;
        }
        out.insert(
            k.to_string(),
            ctx.get(k).map(|v| json!(v)).unwrap_or(Value::Null),
        );
    }

    Value::Object(out)
}

/// Todas as chaves do contexto, com os segredos redigidos.
pub(super) fn all_keys(session: &SharedSession) -> Value {
    let ctx: ContextMap = session.context();
    let mut out = serde_json::Map::new();

    for (k, v) in ctx {
        let valor = if REDIGIDAS.contains(&k.as_str()) {
            json!("<redigido>")
        } else {
            json!(v)
        };
        out.insert(k, valor);
    }

    Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn com_contexto(pares: &[(&str, &str)]) -> SharedSession {
        let s = SharedSession::default();
        let ctx: ContextMap = pares
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        s.sync_from_context(&ctx);
        s
    }

    #[test]
    fn resumo_traz_tela_e_selecao() {
        let s = com_contexto(&[
            ("connected", "true"),
            ("api_url", "https://x.dev"),
            ("api_token", "segredo"),
            ("screen", "shell"),
            ("view", "projects"),
            ("selected_service", "svc_1"),
            ("projects_count", "3"),
            ("data_loading", "false"),
        ]);

        let v = state(&s);
        assert_eq!(v.get("screen").unwrap(), "shell");
        assert_eq!(v.get("view").unwrap(), "projects");
        assert_eq!(v.get("selected_service").unwrap(), "svc_1");
        assert_eq!(v.pointer("/counts/projects").unwrap(), "3");
        assert_eq!(v.get("data_loading").unwrap(), &json!(false));
        assert!(!v.to_string().contains("segredo"));
    }

    /// O token do daemon é o segredo que esta ponte existe para NÃO expor:
    /// nem por chave avulsa, nem no despejo completo.
    #[test]
    fn token_do_daemon_e_redigido_nas_duas_leituras() {
        let s = com_contexto(&[
            ("connected", "true"),
            ("api_url", "https://x.dev"),
            ("api_token", "segredo"),
            ("token", "segredo"),
            ("view", "docker"),
        ]);

        let avulsas = keys(&s, "view,api_token,token");
        assert_eq!(avulsas.get("view").unwrap(), "docker");
        assert_eq!(avulsas.get("api_token").unwrap(), "<redigido>");
        assert_eq!(avulsas.get("token").unwrap(), "<redigido>");

        let todas = all_keys(&s);
        assert_eq!(todas.get("api_token").unwrap(), "<redigido>");
        assert!(!todas.to_string().contains("segredo"));
    }

    #[test]
    fn chave_inexistente_vira_null_em_vez_de_sumir() {
        let s = com_contexto(&[("view", "docker")]);
        let v = keys(&s, "view,nao_existe");
        assert!(v.as_object().unwrap().contains_key("nao_existe"));
        assert_eq!(v.get("nao_existe").unwrap(), &Value::Null);
    }
}
