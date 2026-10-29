//! O helper no Windows: troca a pasta do app portátil (`%LOCALAPPDATA%\Rustploy`) pela do zip
//! **assinado** da release e reabre o app. Ver `main.rs`.
//!
//! Não há privilégio a ganhar (a pasta é do próprio usuário), então este modo não protege contra
//! quem já roda como o usuário. O que ele garante é que só entra na pasta o que o projeto assinou:
//! a mesma verificação (`update_core::signature`) e as mesmas chaves do helper do Linux.
//!
//! ```text
//! rustploy-gui-update.exe check <pasta-do-app> <zip> <minisig>   confere e sai (o app chama antes de fechar)
//! rustploy-gui-update.exe swap  <pasta-do-app> <zip> <minisig>   espera o app fechar, troca e reabre
//! ```
//!
//! O app copia este executável para `<pasta-do-app>-update\` antes de rodá-lo: o original fica
//! dentro da pasta que vai ser trocada. O zip e a assinatura têm de estar direto nesse diretório.
//! O resultado do `swap` vai para `<pasta-do-app>-update\result.json`, que o app reaberto lê.

use std::{fs, io::Read, path::{Path, PathBuf}, process::ExitCode, thread, time::{Duration, Instant}};
use update_core::signature::{TRUSTED_PUBLIC_KEYS, verify};

/// O que o comentário assinado do zip tem de dizer (`tools/sign-release.sh`).
const PACKAGE: &str = "rustploy-gui-windows";
const ARCH: &str = "amd64";
/// A pasta de topo do zip (`release.yml`, passo "Package").
const ZIP_ROOT: &str = "rustploy-gui-windows";
const BINARY: &str = "rustploy-gui.exe";
const MAX_ZIP_BYTES: u64 = 200 * 1024 * 1024;
const MAX_SIGNATURE_BYTES: u64 = 8 * 1024;
/// Quanto o `swap` espera o app fechar (a pasta só pode ser renomeada sem o `.exe` aberto).
const WAIT_FOR_APP: Duration = Duration::from_secs(60);
const RESULT_FILE: &str = "result.json";

/// `<pasta-do-app>-update`, ao lado da pasta do app (mesmo volume, para o `rename` funcionar).
/// Tem de ser o mesmo que o app usa (`staging_dir` em `src/app/updater.rs`).
pub fn staging_dir(install_dir: &Path) -> PathBuf {
    let mut name = install_dir.file_name().unwrap_or_default().to_os_string();
    name.push("-update");
    install_dir.with_file_name(name)
}

/// Confere a assinatura do zip e o que ela afirma; devolve a versão (a da tag, `0.1.22`).
pub fn check(
    install_dir: &Path, zip: &Path, signature: &Path, keys: &[&str]
) -> Result<String, String> {
    let staging = staging_dir(install_dir);
    for file in [zip, signature] {
        if file.parent() != Some(staging.as_path()) {
            return Err(format!(
                "{} não está em {}",
                file.display(),
                staging.display()
            ));
        }
    }
    if !install_dir.join(BINARY).is_file() {
        return Err(format!(
            "{} não tem {BINARY}: não é a pasta do app",
            install_dir.display()
        ));
    }
    let data = read_limited(zip, MAX_ZIP_BYTES)?;
    let signature_text = String::from_utf8(read_limited(signature, MAX_SIGNATURE_BYTES)?)
        .map_err(|_| "a assinatura não é texto".to_string())?;
    let claims = verify(&data, &signature_text, keys).map_err(|error| error.to_string())?;
    if claims.package != PACKAGE || claims.arch != ARCH {
        return Err(format!(
            "a assinatura é de outro pacote ({} {}), não de {PACKAGE} {ARCH}",
            claims.package, claims.arch
        ));
    }
    // O nome do arquivo e a versão assinada têm de ser os mesmos: um zip assinado de outra
    // release não passa por este.
    let expected_name = format!("{PACKAGE}-v{}.zip", claims.version);
    if zip.file_name().and_then(|name| name.to_str()) != Some(expected_name.as_str()) {
        return Err(format!(
            "a assinatura é da versão {}, mas o arquivo é {}",
            claims.version,
            zip.display()
        ));
    }
    Ok(claims.version)
}

fn read_limited(path: &Path, max_bytes: u64) -> Result<Vec<u8>, String> {
    let file = fs::File::open(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut data = Vec::new();
    file.take(max_bytes + 1)
        .read_to_end(&mut data)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    if data.len() as u64 > max_bytes {
        return Err(format!("{} é grande demais", path.display()));
    }
    Ok(data)
}

/// Extrai o zip em `destination` (que não pode existir). Recusa entrada fora de `ZIP_ROOT/` ou que
/// tente sair dela (`..`, caminho absoluto); devolve a pasta do app extraída.
fn extract(zip: &Path, destination: &Path) -> Result<PathBuf, String> {
    let file = fs::File::open(zip).map_err(|error| format!("{}: {error}", zip.display()))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|error| format!("zip ilegível: {error}"))?;
    fs::create_dir(destination)
        .map_err(|error| format!("criando {}: {error}", destination.display()))?;
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| format!("zip ilegível: {error}"))?;
        let relative = entry
            .enclosed_name()
            .filter(|path| path.starts_with(ZIP_ROOT))
            .ok_or_else(|| format!("o zip tem um caminho inesperado: {}", entry.name()))?;
        let target = destination.join(relative);
        if entry.is_dir() {
            fs::create_dir_all(&target)
        } else {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| format!("criando {}: {error}", parent.display()))?;
            }
            fs::File::create(&target)
                .and_then(|mut output| std::io::copy(&mut entry, &mut output).map(drop))
        }
        .map_err(|error| format!("extraindo {}: {error}", target.display()))?;
    }
    let root = destination.join(ZIP_ROOT);
    if !root.join(BINARY).is_file() {
        return Err(format!("o zip não tem {ZIP_ROOT}/{BINARY}"));
    }
    Ok(root)
}

/// Confere, extrai e troca a pasta do app. Se a troca falhar no meio, devolve a pasta antiga.
pub fn swap(
    install_dir: &Path,
    zip: &Path,
    signature: &Path,
    keys: &[&str],
    wait: Duration,
) -> Result<String, String> {
    let version = check(install_dir, zip, signature, keys)?;
    let staging = staging_dir(install_dir);
    let new = staging.join("new");
    let old = staging.join("old");
    for leftover in [&new, &old] {
        if leftover.exists() {
            fs::remove_dir_all(leftover)
                .map_err(|error| format!("apagando {}: {error}", leftover.display()))?;
        }
    }
    let extracted = extract(zip, &new)?;

    // No Windows, a pasta não pode ser renomeada enquanto o app (o `.exe` dela) está aberto: é
    // assim que se espera ele fechar, sem precisar do PID.
    let deadline = Instant::now() + wait;
    loop {
        match fs::rename(install_dir, &old) {
            Ok(()) => break,
            Err(error) if Instant::now() >= deadline => {
                let _ = fs::remove_dir_all(&new);
                return Err(format!(
                    "o app não fechou (ou outro programa está usando {}): {error}",
                    install_dir.display()
                ));
            }
            Err(_) => thread::sleep(Duration::from_millis(500)),
        }
    }
    if let Err(error) = fs::rename(&extracted, install_dir) {
        let restored = fs::rename(&old, install_dir);
        let _ = fs::remove_dir_all(&new);
        return Err(match restored {
            Ok(()) => {
                format!("não consegui pôr a versão nova no lugar ({error}); a anterior foi mantida")
            }
            Err(restore_error) => format!(
                "não consegui pôr a versão nova no lugar ({error}) nem devolver a anterior \
                 ({restore_error}); ela está em {}",
                old.display()
            ),
        });
    }
    let _ = fs::remove_dir_all(&old);
    let _ = fs::remove_dir_all(&new);
    Ok(version)
}

fn write_result(install_dir: &Path, result: &Result<String, String>) {
    let json = match result {
        Ok(version) => serde_json::json!({ "ok": true, "version": version }),
        Err(message) => serde_json::json!({ "ok": false, "message": message }),
    };
    let _ = fs::write(staging_dir(install_dir).join(RESULT_FILE), json.to_string());
}

fn reopen(install_dir: &Path) {
    let _ = std::process::Command::new(install_dir.join(BINARY))
        .current_dir(install_dir)
        .spawn();
}

pub fn run() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let [mode, install_dir, zip, signature] = arguments.as_slice() else {
        eprintln!("uso: rustploy-gui-update.exe check|swap <pasta-do-app> <zip> <minisig>");
        return ExitCode::from(2);
    };
    let (install_dir, zip, signature) =
        (Path::new(install_dir), Path::new(zip), Path::new(signature));
    let result = match mode.as_str() {
        "check" => check(install_dir, zip, signature, TRUSTED_PUBLIC_KEYS),
        "swap" => {
            let result = swap(
                install_dir,
                zip,
                signature,
                TRUSTED_PUBLIC_KEYS,
                WAIT_FOR_APP,
            );
            write_result(install_dir, &result);
            // Reabre de qualquer jeito: a versão nova, ou a antiga se a troca não aconteceu.
            reopen(install_dir);
            result
        }
        other => {
            eprintln!("modo desconhecido: {other} (use check ou swap)");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(version) => {
            println!("{version}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/windows-update");

    fn test_key() -> String {
        let text = fs::read_to_string(format!("{FIXTURES}/test.pub")).unwrap();
        text.lines().nth(1).unwrap().trim().to_string()
    }

    /// `<tmp>/Rustploy` com o app "antigo" e `<tmp>/Rustploy-update` com o zip `fixture` e a
    /// assinatura `signature`, já com o nome que a release usa.
    struct Setup {
        _temp: tempfile::TempDir,
        install_dir: PathBuf,
        zip: PathBuf,
        signature: PathBuf,
    }

    fn setup(fixture: &str, signature: &str) -> Setup {
        let temp = tempfile::tempdir().unwrap();
        let install_dir = temp.path().join("Rustploy");
        fs::create_dir_all(install_dir.join("views")).unwrap();
        fs::write(install_dir.join(BINARY), "exe antigo").unwrap();
        fs::write(install_dir.join("views/app.gv"), "view antiga").unwrap();
        let staging = staging_dir(&install_dir);
        fs::create_dir(&staging).unwrap();
        let zip = staging.join("rustploy-gui-windows-v9.9.9.zip");
        let signature_path = staging.join("rustploy-gui-windows-v9.9.9.zip.minisig");
        fs::copy(format!("{FIXTURES}/{fixture}"), &zip).unwrap();
        fs::copy(format!("{FIXTURES}/{signature}"), &signature_path).unwrap();
        Setup {
            _temp: temp,
            install_dir,
            zip,
            signature: signature_path,
        }
    }

    fn run_swap(setup: &Setup) -> Result<String, String> {
        let key = test_key();
        swap(
            &setup.install_dir,
            &setup.zip,
            &setup.signature,
            &[key.as_str()],
            Duration::from_secs(1),
        )
    }

    fn assert_untouched(setup: &Setup) {
        assert_eq!(
            fs::read_to_string(setup.install_dir.join(BINARY)).unwrap(),
            "exe antigo"
        );
        assert_eq!(
            fs::read_to_string(setup.install_dir.join("views/app.gv")).unwrap(),
            "view antiga"
        );
    }

    #[test]
    fn staging_is_a_sibling_of_the_app_folder() {
        assert_eq!(
            staging_dir(Path::new("/x/AppData/Local/Rustploy")),
            PathBuf::from("/x/AppData/Local/Rustploy-update")
        );
    }

    #[test]
    fn a_signed_zip_replaces_the_whole_folder() {
        let setup = setup("good.zip", "good.zip.minisig");
        assert_eq!(run_swap(&setup).unwrap(), "9.9.9");
        assert_eq!(
            fs::read_to_string(setup.install_dir.join(BINARY)).unwrap(),
            "novo exe"
        );
        assert_eq!(
            fs::read_to_string(setup.install_dir.join("views/app.gv")).unwrap(),
            "nova view"
        );
        let staging = staging_dir(&setup.install_dir);
        assert!(!staging.join("old").exists() && !staging.join("new").exists());
    }

    #[test]
    fn check_only_reads() {
        let setup = setup("good.zip", "good.zip.minisig");
        let key = test_key();
        let version = check(
            &setup.install_dir,
            &setup.zip,
            &setup.signature,
            &[key.as_str()],
        );
        assert_eq!(version.unwrap(), "9.9.9");
        assert_untouched(&setup);
    }

    #[test]
    fn a_tampered_zip_is_refused_without_touching_the_app() {
        let setup = setup("good.zip", "good.zip.minisig");
        let mut data = fs::read(&setup.zip).unwrap();
        data.push(b'x');
        fs::write(&setup.zip, data).unwrap();
        let error = run_swap(&setup).unwrap_err();
        assert!(error.contains("assinatura inválida"), "{error}");
        assert_untouched(&setup);
    }

    #[test]
    fn a_zip_signed_by_another_key_is_refused() {
        let setup = setup("good.zip", "good.zip.minisig");
        let error = swap(
            &setup.install_dir,
            &setup.zip,
            &setup.signature,
            TRUSTED_PUBLIC_KEYS,
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert!(error.contains("assinatura inválida"), "{error}");
        assert_untouched(&setup);
    }

    #[test]
    fn the_signed_claims_must_be_the_windows_app() {
        for signature in ["otherpkg.zip.minisig", "arm.zip.minisig"] {
            let setup = setup("good.zip", signature);
            let error = run_swap(&setup).unwrap_err();
            assert!(error.contains("outro pacote"), "{signature}: {error}");
            assert_untouched(&setup);
        }
    }

    #[test]
    fn the_file_name_must_match_the_signed_version() {
        let setup = setup("good.zip", "good.zip.minisig");
        let renamed = setup.zip.with_file_name("rustploy-gui-windows-v9.9.10.zip");
        fs::rename(&setup.zip, &renamed).unwrap();
        let key = test_key();
        let error = check(
            &setup.install_dir,
            &renamed,
            &setup.signature,
            &[key.as_str()],
        )
        .unwrap_err();
        assert!(error.contains("versão 9.9.9"), "{error}");
    }

    #[test]
    fn files_outside_the_staging_dir_are_refused() {
        let setup = setup("good.zip", "good.zip.minisig");
        let elsewhere = setup
            .install_dir
            .parent()
            .unwrap()
            .join("rustploy-gui-windows-v9.9.9.zip");
        fs::copy(&setup.zip, &elsewhere).unwrap();
        let key = test_key();
        let error = check(
            &setup.install_dir,
            &elsewhere,
            &setup.signature,
            &[key.as_str()],
        )
        .unwrap_err();
        assert!(error.contains("não está em"), "{error}");
    }

    #[test]
    fn a_folder_without_the_app_is_never_replaced() {
        let setup = setup("good.zip", "good.zip.minisig");
        fs::remove_file(setup.install_dir.join(BINARY)).unwrap();
        let error = run_swap(&setup).unwrap_err();
        assert!(error.contains("não é a pasta do app"), "{error}");
    }

    #[test]
    fn signed_zips_with_bad_contents_are_refused() {
        for (fixture, expected) in [
            ("slip.zip", "caminho inesperado"),
            ("outside.zip", "caminho inesperado"),
            ("noexe.zip", "não tem rustploy-gui-windows/rustploy-gui.exe"),
        ] {
            let setup = setup(fixture, &format!("{fixture}.minisig"));
            let error = run_swap(&setup).unwrap_err();
            assert!(error.contains(expected), "{fixture}: {error}");
            assert_untouched(&setup);
            let parent = setup.install_dir.parent().unwrap();
            assert!(!parent.join("fora.txt").exists());
        }
    }

    #[test]
    fn the_result_file_is_where_the_app_looks() {
        let setup = setup("good.zip", "good.zip.minisig");
        write_result(&setup.install_dir, &Err("deu ruim".into()));
        let text = fs::read_to_string(staging_dir(&setup.install_dir).join(RESULT_FILE)).unwrap();
        let json: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(json["ok"], false);
        assert_eq!(json["message"], "deu ruim");
    }
}
