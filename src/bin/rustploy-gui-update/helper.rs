//! O helper de verdade (só Unix: `geteuid`, `getpwuid_r`, dpkg). Ver `main.rs`.

use std::{ffi::CStr, path::PathBuf, process::ExitCode, time::Duration};
use update_core::{
    installer::{Paths, Settings, Updater},
    outcome::OutcomeKind,
    signature::TRUSTED_PUBLIC_KEYS,
    system::RealSystem,
};

const STATE_DIR: &str = "/var/lib/rustploy-gui-update";
const BINARY: &str = "/usr/bin/rustploy-gui";
const MAX_DEB_BYTES: u64 = 200 * 1024 * 1024;
/// Relativo à home do usuário que chamou. O app baixa aqui (ver `src/app/updater.rs`).
const USER_CACHE_SUBDIR: &str = ".cache/rustploy-gui/updates";

/// As chaves em que este helper confia: as de produção embutidas em `update-core`.
///
/// Exceção só para o teste de ponta a ponta (`tests/e2e-updater-gui`): se
/// `RUSTPLOY_E2E_TRUSTED_KEY` estiver definida **na hora de compilar**, ela vale no lugar da de
/// produção. É em tempo de compilação de propósito (um ambiente alterado em execução nunca troca
/// as chaves de um helper root); o CI e o `make deb` não a definem e um teste confere.
fn trusted_keys() -> Vec<String> {
    match option_env!("RUSTPLOY_E2E_TRUSTED_KEY") {
        Some(key) if !key.is_empty() => vec![key.to_string()],
        _ => TRUSTED_PUBLIC_KEYS.iter().map(|key| key.to_string()).collect(),
    }
}

/// A home de `uid` na tabela de usuários (`getpwuid_r`), nunca de `$HOME`.
fn home_of(uid: u32) -> Result<PathBuf, String> {
    let mut buffer = vec![0u8; 16 * 1024];
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: `entry`, `buffer` e `result` vivem durante a chamada; o buffer tem o tamanho passado.
    let status = unsafe {
        libc::getpwuid_r(uid, &mut entry, buffer.as_mut_ptr().cast(), buffer.len(), &mut result)
    };
    if status != 0 || result.is_null() {
        return Err(format!("não achei o usuário {uid} na tabela de usuários"));
    }
    // SAFETY: com `result` não nulo, `pw_dir` aponta para uma string C válida dentro de `buffer`.
    let home = unsafe { CStr::from_ptr(entry.pw_dir) }
        .to_str().map_err(|_| "a home do usuário não é UTF-8".to_string())?;
    if !home.starts_with('/') {
        return Err(format!("home inválida para o usuário {uid}: {home:?}"));
    }
    Ok(PathBuf::from(home))
}

/// De onde este helper aceita um `.deb`: o cache do usuário que rodou o `pkexec`.
fn allowed_dir() -> Result<PathBuf, String> {
    match std::env::var("PKEXEC_UID") {
        Ok(text) => {
            let uid: u32 = text.parse().map_err(|_| format!("PKEXEC_UID inválido: {text:?}"))?;
            Ok(home_of(uid)?.join(USER_CACHE_SUBDIR))
        }
        // Sem `pkexec` quem chama já é root (teste, `sudo`): o diretório vem do ambiente. Sob o
        // `pkexec` o ambiente é limpo pelo próprio `pkexec`, então isto nunca é alcançável por um
        // usuário comum.
        Err(_) => std::env::var("RUSTPLOY_GUI_UPDATE_ALLOWED_DIR")
            .map(PathBuf::from)
            .map_err(|_| {
                "rode por `pkexec` (sem PKEXEC_UID não sei de onde ler o pacote)".to_string()
            }),
    }
}

pub fn run() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let [_, verb, deb, signature] = args.as_slice() else {
        eprintln!("uso: rustploy-gui-update install <pacote.deb> <pacote.deb.minisig>");
        return ExitCode::from(2);
    };
    if verb != "install" {
        eprintln!("verbo desconhecido: {verb} (só existe `install`)");
        return ExitCode::from(2);
    }
    // SAFETY: `geteuid` não tem pré-condições.
    if unsafe { libc::geteuid() } != 0 {
        eprintln!("precisa rodar como root: use `pkexec`");
        return ExitCode::from(1);
    }

    let allowed_dir = match allowed_dir() {
        Ok(directory) => directory,
        Err(message) => { eprintln!("{message}"); return ExitCode::from(1); }
    };
    let paths = Paths {
        allowed_dir,
        state_dir: PathBuf::from(
            std::env::var("RUSTPLOY_GUI_UPDATE_STATE_DIR")
                .ok().filter(|_| std::env::var_os("PKEXEC_UID").is_none())
                .unwrap_or_else(|| STATE_DIR.to_string()),
        ),
        managed_binaries: vec![PathBuf::from(BINARY)],
    };
    let settings = Settings {
        package: "rustploy-gui".into(),
        // O app desktop não é um serviço: não há o que reiniciar nem esperar.
        service: None,
        trusted_keys: trusted_keys(),
        max_deb_bytes: MAX_DEB_BYTES,
        poll_interval: Duration::from_secs(1),
        stable_polls: 1,
        max_polls: 1,
    };
    let system = RealSystem;
    let updater = Updater { paths: &paths, settings: &settings, system: &system, };

    match updater.prepare(deb, signature) {
        Ok(prepared) => {
            let outcome = updater.execute(prepared);
            println!("{}", serde_json::to_string(&outcome).unwrap_or_else(|_| "{}".into()));
            if outcome.kind == OutcomeKind::Installed { ExitCode::SUCCESS }
            else { eprintln!("{}", outcome.message); ExitCode::from(1) }
        }
        Err(message) => { eprintln!("{message}"); ExitCode::from(1) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Guarda contra um build de teste que vaze para o pacote.
    #[test]
    fn a_normal_build_trusts_only_the_production_keys() {
        assert!(
            option_env!("RUSTPLOY_E2E_TRUSTED_KEY").is_none_or(str::is_empty),
            "RUSTPLOY_E2E_TRUSTED_KEY está definida neste build: não é um build de produção"
        );
        let expected: Vec<String> = TRUSTED_PUBLIC_KEYS
            .iter().map(|key| key.to_string()).collect();
        assert_eq!(trusted_keys(), expected);
    }

    #[test]
    fn root_home_comes_from_the_user_table_not_the_environment() {
        // O uid 0 existe em qualquer Linux; a home dele vem de /etc/passwd.
        let home = home_of(0).unwrap();
        assert!(home.is_absolute());
        // Um uid que não existe é erro, não um caminho inventado.
        assert!(home_of(4_000_000_000).is_err());
    }

    #[test]
    fn pkexec_uid_must_be_a_number() {
        // SAFETY: teste isolado; nenhum outro teste deste binário lê PKEXEC_UID.
        unsafe { std::env::set_var("PKEXEC_UID", "não-é-número") };
        let error = allowed_dir().unwrap_err();
        unsafe { std::env::remove_var("PKEXEC_UID") };
        assert!(error.contains("PKEXEC_UID inválido"), "{error}");
    }
}
