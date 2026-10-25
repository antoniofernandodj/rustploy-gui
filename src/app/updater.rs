//! A ponte nativa do "Atualizar app": o que o Luau não consegue fazer sozinho (rodar `curl` e
//! `pkexec`, reabrir o app) e as decisões de segurança que não devem ser reescritas em Luau
//! (comparar versões, escolher o pacote certo da release).
//!
//! Exposto ao Luau como o global `app_update` (ver `views/scripts/glacier.d.luau`). Nada aqui
//! instala algo: quem instala é `/usr/libexec/rustploy-gui-update`, que roda como root via
//! `pkexec` e só aceita um pacote assinado pela chave do projeto.

use glacier_ui::mlua::{Lua, Result as LuaResult, Table};
use std::{
    path::{Path, PathBuf},
    process::Command,
};
use update_core::{
    is_newer, parse_version,
    release::{debian_architecture, parse_release, select_package_assets},
};

/// Repositório das releases do app. Fixo no binário: a UI não escolhe de onde vem uma atualização.
const REPOSITORY: &str = "antoniofernandodj/rustploy";
/// O helper root e o binário que ele troca.
const HELPER: &str = "/usr/libexec/rustploy-gui-update";
const INSTALLED_BINARY: &str = "/usr/bin/rustploy-gui";
/// Relativo ao cache do usuário. Tem de ser o mesmo que o helper lê (`USER_CACHE_SUBDIR`).
const CACHE_SUBDIR: &str = "rustploy-gui/updates";
const MAX_DEB_BYTES: u64 = 200 * 1024 * 1024;

/// Como este executável foi instalado: só a instalação por `.deb` tem helper root.
#[derive(Debug, PartialEq, Eq)]
enum InstallKind {
    /// `/usr/bin/rustploy-gui`, instalado por `.deb`: dá para atualizar pelo app.
    Deb,
    /// `cargo install`, zip portátil, compilado do código: o app só avisa.
    Other,
}

impl InstallKind {
    fn label(&self) -> &'static str {
        match self {
            Self::Deb => "deb",
            Self::Other => "other",
        }
    }
}

fn install_kind_of(executable: &Path) -> InstallKind {
    // Compara o caminho resolvido: um link para fora de /usr/bin não conta como instalado por .deb.
    match std::fs::canonicalize(executable) {
        Ok(resolved) if resolved == Path::new(INSTALLED_BINARY) => InstallKind::Deb,
        _ => InstallKind::Other,
    }
}

fn install_kind() -> InstallKind {
    std::env::current_exe()
        .map(|executable| install_kind_of(&executable))
        .unwrap_or(InstallKind::Other)
}

/// O app pode se atualizar sozinho? `.deb` + helper instalado + `pkexec` no PATH.
fn can_update() -> bool {
    install_kind() == InstallKind::Deb
        && Path::new(HELPER).exists()
        && find_in_path("pkexec").is_some()
}

fn find_in_path(program: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file())
    })
}

/// `$XDG_CACHE_HOME` ou `~/.cache`, resolvido como o helper espera.
fn updates_dir() -> Result<PathBuf, String> {
    let cache = match std::env::var_os("XDG_CACHE_HOME").filter(|value| !value.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(
            std::env::var_os("HOME").ok_or_else(|| "sem HOME para achar o cache".to_string())?,
        )
        .join(".cache"),
    };
    // O helper só olha `<home>/.cache/rustploy-gui/updates`: com XDG_CACHE_HOME fora disso ele não
    // acharia o arquivo. Melhor recusar aqui, com a causa, do que falhar lá com "fora do diretório".
    let expected = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache");
    if cache != expected {
        return Err(format!(
            "o cache do app precisa estar em {} (XDG_CACHE_HOME aponta para {})",
            expected.display(),
            cache.display()
        ));
    }
    Ok(cache.join(CACHE_SUBDIR))
}

/// Baixa `url` para `destination` com o `curl` do sistema (TLS e certificados do sistema), seguindo
/// redirecionamentos só por https. A integridade e a autenticidade NÃO dependem daqui: o helper
/// root confere a assinatura do que chegar.
fn download(url: &str, destination: &Path, max_bytes: u64) -> Result<(), String> {
    if !url.starts_with("https://github.com/") {
        return Err(format!("recusei baixar de fora do GitHub: {url}"));
    }
    let partial = destination.with_extension("partial");
    let status = Command::new("curl")
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--max-redirs",
            "5",
            "--connect-timeout",
            "20",
            "--max-time",
            "600",
            "--max-filesize",
        ])
        .arg(max_bytes.to_string())
        .arg("--output")
        .arg(&partial)
        .arg(url)
        .output()
        .map_err(|error| format!("não consegui rodar o curl: {error}"))?;
    if !status.status.success() {
        let _ = std::fs::remove_file(&partial);
        return Err(format!(
            "o download falhou: {}",
            String::from_utf8_lossy(&status.stderr).trim()
        ));
    }
    std::fs::rename(&partial, destination).map_err(|error| format!("gravando o download: {error}"))
}

/// O nome vira parte de um caminho: só o que um `.deb` do rustploy-gui teria.
fn validate_deb_name(deb_name: &str) -> Result<(), String> {
    let plain = deb_name
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "._+-~".contains(character));
    if plain
        && deb_name.starts_with("rustploy-gui_")
        && deb_name.ends_with(".deb")
        && !deb_name.contains("..")
    {
        Ok(())
    } else {
        Err(format!("nome de pacote inesperado: {deb_name}"))
    }
}

/// Baixa o pacote e a assinatura para o cache do usuário e chama o helper por `pkexec`.
/// Devolve a mensagem do resultado; bloqueia até o fim (download + senha + instalação).
fn install(deb_url: &str, signature_url: &str, deb_name: &str) -> Result<String, String> {
    if !can_update() {
        return Err("este app não foi instalado por .deb (ou falta o pkexec): atualize pelo comando de instalação".into());
    }
    validate_deb_name(deb_name)?;
    let directory = updates_dir()?;
    std::fs::create_dir_all(&directory)
        .map_err(|error| format!("criando {}: {error}", directory.display()))?;
    // Resto de uma tentativa anterior não pode ser confundido com o pacote novo.
    if let Ok(entries) = std::fs::read_dir(&directory) {
        for entry in entries.flatten() {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let deb_path = directory.join(deb_name);
    let signature_path = directory.join(format!("{deb_name}.minisig"));
    download(deb_url, &deb_path, MAX_DEB_BYTES)?;
    download(signature_url, &signature_path, 8 * 1024)?;

    let output = Command::new("pkexec")
        .arg(HELPER)
        .arg("install")
        .arg(&deb_path)
        .arg(&signature_path)
        .output()
        .map_err(|error| format!("não consegui rodar o pkexec: {error}"))?;
    let _ = std::fs::remove_file(&deb_path);
    let _ = std::fs::remove_file(&signature_path);
    match output.status.code() {
        Some(0) => Ok("instalado".to_string()),
        // 126/127 do pkexec: o usuário cancelou o diálogo ou não está autorizado.
        Some(126) | Some(127) => Err("a autenticação foi cancelada ou negada".into()),
        _ => {
            let detail = String::from_utf8_lossy(&output.stderr);
            let detail = detail
                .lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .unwrap_or("falhou");
            Err(detail.trim().to_string())
        }
    }
}

/// Abre uma nova instância do app e encerra esta.
fn restart() -> Result<(), String> {
    Command::new(INSTALLED_BINARY)
        .spawn()
        .map_err(|error| format!("não consegui reabrir o app: {error}"))?;
    std::process::exit(0);
}

/// Instala o global `app_update` numa VM Luau nova.
pub(crate) fn install_lua(lua: &Lua) -> LuaResult<()> {
    let table: Table = lua.create_table()?;

    // { version, install_kind, can_update }
    table.set(
        "info",
        lua.create_function(|lua, ()| {
            let info = lua.create_table()?;
            info.set("version", env!("CARGO_PKG_VERSION"))?;
            info.set("install_kind", install_kind().label())?;
            info.set("can_update", can_update())?;
            Ok(info)
        })?,
    )?;

    // Lê o JSON de `releases/latest` e devolve { tag, latest_version, is_update_available, html_url,
    // deb_url, signature_url, deb_name } — ou `nil, mensagem`.
    table.set(
        "plan",
        lua.create_function(|lua, json: String| {
            let plan = (|| -> Result<Table, String> {
                let release = parse_release(&json)?;
                let latest = parse_version(&release.tag).map_err(|error| error.to_string())?;
                let is_update_available = is_newer(&release.tag, env!("CARGO_PKG_VERSION"))
                    .map_err(|error| error.to_string())?;
                let result = lua.create_table().map_err(|error| error.to_string())?;
                let set = |key: &str, value: String| {
                    result.set(key, value).map_err(|error| error.to_string())
                };
                set("tag", release.tag.clone())?;
                set("latest_version", latest.to_string())?;
                set("html_url", release.html_url.clone())?;
                result
                    .set("is_update_available", is_update_available)
                    .map_err(|error| error.to_string())?;
                if is_update_available {
                    let (deb, signature) = select_package_assets(
                        &release.assets,
                        REPOSITORY,
                        "rustploy-gui",
                        debian_architecture()?,
                        &release.tag,
                    )?;
                    set("deb_url", deb.url)?;
                    set("deb_name", deb.name)?;
                    set("signature_url", signature.url)?;
                }
                Ok(result)
            })();
            Ok(match plan {
                Ok(table) => (Some(table), None),
                Err(message) => (None, Some(message)),
            })
        })?,
    )?;

    // Baixa, autentica (pkexec) e instala. Devolve `true, mensagem` ou `false, causa`.
    table.set(
        "install",
        lua.create_function(
            |_, (deb_url, signature_url, deb_name): (String, String, String)| {
                Ok(match install(&deb_url, &signature_url, &deb_name) {
                    Ok(message) => (true, message),
                    Err(message) => (false, message),
                })
            },
        )?,
    )?;

    table.set("restart", lua.create_function(|_, ()| Ok(restart().err()))?)?;

    lua.globals().set("app_update", table)
}

#[cfg(test)]
mod tests {
    use super::*;
    use glacier_ui::mlua::Value;

    #[test]
    fn only_the_installed_path_counts_as_deb() {
        // Um caminho que não existe, ou que não é /usr/bin/rustploy-gui, nunca é "deb".
        assert_eq!(
            install_kind_of(Path::new("/nao/existe/rustploy-gui")),
            InstallKind::Other
        );
        assert_eq!(
            install_kind_of(Path::new("/usr/bin/true")),
            InstallKind::Other
        );
        assert_eq!(InstallKind::Deb.label(), "deb");
        assert_eq!(InstallKind::Other.label(), "other");
    }

    #[test]
    fn deb_names_are_validated_before_becoming_paths() {
        assert!(validate_deb_name("rustploy-gui_0.1.21-1_amd64.deb").is_ok());
        for bad in [
            "",
            "rustployd_0.1.11-1_amd64.deb",
            "rustploy-gui_x/../../etc/passwd.deb",
            "rustploy-gui_a b.deb",
            "rustploy-gui_..deb",
            "rustploy-gui_0.1.21-1_amd64.deb;rm",
            "rustploy-gui_0.1.21-1_amd64.tar",
        ] {
            assert!(
                validate_deb_name(bad).is_err(),
                "{bad:?} deveria ser recusado"
            );
        }
    }

    #[test]
    fn downloads_only_from_github() {
        let destination = std::env::temp_dir().join("rustploy-gui-never");
        for url in [
            "http://github.com/x",
            "https://evil.example/x",
            "file:///etc/passwd",
            "ftp://github.com/x",
        ] {
            let error = download(url, &destination, 1024).unwrap_err();
            assert!(error.contains("fora do GitHub"), "{url}: {error}");
        }
        assert!(!destination.exists());
    }

    #[test]
    fn updates_dir_must_match_where_the_helper_looks() {
        // SAFETY: único teste deste binário que mexe nessas variáveis.
        unsafe {
            std::env::set_var("HOME", "/home/pessoa");
            std::env::set_var("XDG_CACHE_HOME", "/outro/lugar");
        }
        let error = updates_dir().unwrap_err();
        assert!(error.contains("/home/pessoa/.cache"), "{error}");

        unsafe { std::env::set_var("XDG_CACHE_HOME", "/home/pessoa/.cache") };
        assert_eq!(
            updates_dir().unwrap(),
            PathBuf::from("/home/pessoa/.cache/rustploy-gui/updates")
        );

        unsafe { std::env::remove_var("XDG_CACHE_HOME") };
        assert_eq!(
            updates_dir().unwrap(),
            PathBuf::from("/home/pessoa/.cache/rustploy-gui/updates")
        );
    }

    /// A VM é devolvida junto: uma `Table` não vive mais que a `Lua` que a criou.
    fn run_plan(json: &str) -> (Lua, Option<Table>, Option<String>) {
        let lua = Lua::new();
        install_lua(&lua).unwrap();
        let native: Table = lua.globals().get("app_update").unwrap();
        let function: glacier_ui::mlua::Function = native.get("plan").unwrap();
        let (plan, error) = function
            .call::<(Option<Table>, Option<String>)>(json.to_string())
            .unwrap();
        (lua, plan, error)
    }

    fn release_json(tag: &str) -> String {
        let base = format!("https://github.com/{REPOSITORY}/releases/download/{tag}");
        format!(
            r#"{{"tag_name":"{tag}","html_url":"https://github.com/{REPOSITORY}/releases/tag/{tag}","assets":[
              {{"name":"rustploy-gui_9.9.9-1_amd64.deb","browser_download_url":"{base}/rustploy-gui_9.9.9-1_amd64.deb"}},
              {{"name":"rustploy-gui_9.9.9-1_amd64.deb.minisig","browser_download_url":"{base}/rustploy-gui_9.9.9-1_amd64.deb.minisig"}},
              {{"name":"rustploy-gui_9.9.9-1_arm64.deb","browser_download_url":"{base}/rustploy-gui_9.9.9-1_arm64.deb"}},
              {{"name":"rustploy-gui_9.9.9-1_arm64.deb.minisig","browser_download_url":"{base}/rustploy-gui_9.9.9-1_arm64.deb.minisig"}}
            ]}}"#
        )
    }

    #[test]
    fn plan_picks_this_architectures_package_and_its_signature() {
        let (_lua, plan, error) = run_plan(&release_json("v9.9.9"));
        assert_eq!(error, None);
        let plan = plan.unwrap();
        assert!(plan.get::<bool>("is_update_available").unwrap());
        assert_eq!(plan.get::<String>("latest_version").unwrap(), "9.9.9");
        let architecture = debian_architecture().unwrap();
        let deb_name: String = plan.get("deb_name").unwrap();
        assert_eq!(deb_name, format!("rustploy-gui_9.9.9-1_{architecture}.deb"));
        assert!(
            plan.get::<String>("signature_url")
                .unwrap()
                .ends_with(".deb.minisig")
        );
        assert!(
            plan.get::<String>("deb_url")
                .unwrap()
                .starts_with("https://github.com/")
        );
    }

    #[test]
    fn plan_for_an_older_or_equal_release_has_no_files() {
        let (_lua, plan, error) = run_plan(&release_json("v0.0.1"));
        assert_eq!(error, None);
        let plan = plan.unwrap();
        assert!(!plan.get::<bool>("is_update_available").unwrap());
        assert!(matches!(plan.get::<Value>("deb_url").unwrap(), Value::Nil));
    }

    #[test]
    fn plan_reports_garbage_as_an_error_message() {
        for json in ["<html>", "{}", r#"{"tag_name":"nightly","html_url":"x"}"#] {
            let (_lua, plan, error) = run_plan(json);
            assert!(plan.is_none(), "{json}");
            assert!(error.is_some(), "{json}");
        }
    }

    #[test]
    fn plan_without_a_signature_in_the_release_is_refused() {
        let json = release_json("v9.9.9").replace(".deb.minisig", ".deb.sig");
        let (_lua, plan, error) = run_plan(&json);
        assert!(plan.is_none());
        assert!(error.unwrap().contains("só instalo pacote assinado"));
    }
}
