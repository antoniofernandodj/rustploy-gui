//! API de agente — um servidor HTTP local que empresta a sessão desta janela.

mod actions;
mod catalog;
mod client;
mod handoff;
mod routes;
mod servers;
mod session;
mod ui;

pub(crate) use session::SharedSession;

use std::net::SocketAddr;

use glacier_ui::ExternalSender;
use std::sync::atomic::{AtomicBool, Ordering};

/// Se esta execução chegou a subir o servidor.
static STARTED: AtomicBool = AtomicBool::new(false);

/// Endereço padrão.
const DEFAULT_ADDR: &str = "127.0.0.1:9800";

/// Variável que desliga a API (`RUSTPLOY_AGENT_API=off`) ou troca o endereço
/// (`RUSTPLOY_AGENT_API=127.0.0.1:9910`).
const ENV_VAR: &str = "RUSTPLOY_AGENT_API";

/// Sobe o servidor numa thread própria, com um runtime tokio próprio.
pub(crate) fn spawn(session: SharedSession, ui: ExternalSender) {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }

    let addr = match configured_addr() {
        Some(addr) => addr,
        None => {
            eprintln!("[agent-api] desligada por {ENV_VAR}=off");
            return;
        }
    };

    std::thread::Builder::new()
        .name("rustploy-agent-api".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("[agent-api] falha ao criar o runtime: {e}");
                    return;
                }
            };
            if let Err(e) = rt.block_on(routes::serve(addr, session, ui)) {
                eprintln!("[agent-api] encerrada: {e}");
            }
        })
        .map(|_| ())
        .unwrap_or_else(|e| eprintln!("[agent-api] falha ao criar a thread: {e}"));
}

/// Apaga o arquivo de handoff.
pub(crate) fn cleanup() {
    if STARTED.load(Ordering::SeqCst) {
        handoff::remove();
    }
}

/// Endereço a usar, ou `None` quando a API foi desligada por env var.
fn configured_addr() -> Option<SocketAddr> {
    resolve_addr(std::env::var(ENV_VAR).unwrap_or_default().trim())
}

/// Regra de resolução do endereço, separada da leitura da env var para poder
/// ser testada.
fn resolve_addr(raw: &str) -> Option<SocketAddr> {
    if raw.eq_ignore_ascii_case("off") || raw == "0" {
        return None;
    }

    let escolhido = if raw.is_empty() { DEFAULT_ADDR } else { raw };

    match escolhido.parse::<SocketAddr>() {
        Ok(addr) if addr.ip().is_loopback() => Some(addr),
        Ok(addr) => {
            eprintln!(
                "[agent-api] {ENV_VAR}={addr} não é loopback — ignorado, usando {DEFAULT_ADDR}"
            );
            DEFAULT_ADDR.parse().ok()
        }
        Err(e) => {
            eprintln!("[agent-api] {ENV_VAR}={escolhido} inválido ({e}) — usando {DEFAULT_ADDR}");
            DEFAULT_ADDR.parse().ok()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vazio_usa_o_default() {
        assert_eq!(resolve_addr(""), DEFAULT_ADDR.parse().ok());
    }

    #[test]
    fn off_desliga() {
        assert_eq!(resolve_addr("off"), None);
        assert_eq!(resolve_addr("OFF"), None);
        assert_eq!(resolve_addr("0"), None);
    }

    #[test]
    fn porta_alternativa_em_loopback_e_aceita() {
        assert_eq!(
            resolve_addr("127.0.0.1:9910"),
            "127.0.0.1:9910".parse().ok()
        );
        assert_eq!(resolve_addr("[::1]:9910"), "[::1]:9910".parse().ok());
    }

    /// O guard que importa: pedir bind público não abre a ponte para a rede,
    /// cai no default de loopback.
    #[test]
    fn endereco_publico_cai_no_default() {
        assert_eq!(resolve_addr("0.0.0.0:9800"), DEFAULT_ADDR.parse().ok());
        assert_eq!(resolve_addr("192.168.1.10:9800"), DEFAULT_ADDR.parse().ok());
    }

    #[test]
    fn lixo_cai_no_default() {
        assert_eq!(resolve_addr("nao-e-endereco"), DEFAULT_ADDR.parse().ok());
    }
}
