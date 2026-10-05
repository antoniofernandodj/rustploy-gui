//! Arquivo de handoff: como um agente na mesma máquina descobre esta API.

use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;

use rand::Rng;

/// Nome do arquivo dentro do data dir.
const FILE: &str = "agent-api.json";

/// Caminho completo do handoff.
pub(crate) fn path() -> PathBuf {
    shared::fallback_data_dir().join(FILE)
}

/// Token de acesso desta execução: 32 bytes de CSPRNG em hex.
pub(crate) fn generate_token() -> String {
    let bytes: [u8; 32] = rand::rng().random();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Grava (ou regrava) o handoff.
pub(crate) fn write(addr: SocketAddr, token: &str, remote: Option<&str>) -> std::io::Result<()> {
    let doc = serde_json::json!({
        "version": 1,
        "url": format!("http://{addr}"),
        "token": token,
        "pid": std::process::id(),
        "remote_url": remote,
        "connected": remote.is_some(),
        "docs": "GET /agent/schema (Authorization: Bearer <token>)",
        "note": "arquivo desta execução do rustploy-gui; confira o pid ou GET /agent/health"
    });

    let destino = path();
    if let Some(dir) = destino.parent() {
        std::fs::create_dir_all(dir)?;
    }

    let temporario = destino.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&temporario)?;
        restrict_permissions(&f)?;
        f.write_all(
            serde_json::to_string_pretty(&doc)
                .unwrap_or_default()
                .as_bytes(),
        )?;
        f.flush()?;
    }
    std::fs::rename(&temporario, &destino)?;
    Ok(())
}

/// Remove o handoff.
pub(crate) fn remove() {
    let _ = std::fs::remove_file(path());
}

#[cfg(unix)]
fn restrict_permissions(f: &std::fs::File) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn restrict_permissions(_f: &std::fs::File) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_tem_64_hex_e_nao_repete() {
        let a = generate_token();
        let b = generate_token();
        assert_eq!(a.len(), 64);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}
