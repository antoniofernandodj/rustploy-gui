//! A ponte nativa do "Atualizar app": o que o Luau não consegue fazer sozinho (baixar o pacote
//! pela camada de rede do glacier, rodar `pkexec`, reabrir o app) e as decisões de segurança que não devem ser reescritas em Luau
//! (comparar versões, escolher o pacote certo da release).
//!
//! Exposto ao Luau como o global `app_update` (ver `views/scripts/glacier.d.luau`). Nada aqui
//! instala algo: quem instala é `/usr/libexec/rustploy-gui-update`, que roda como root via
//! `pkexec` e só aceita um pacote assinado pela chave do projeto.
//!
//! No Windows (zip portátil em `%LOCALAPPDATA%\Rustploy`, o que o `install.ps1` instala) não há
//! privilégio: o app baixa o zip e a assinatura, o `rustploy-gui-update.exe` confere (`check`) e,
//! ao reabrir, espera esta janela fechar, troca a pasta e reabre o app (`swap`). Ver
//! `src/bin/rustploy-gui-update/portable.rs`.

use glacier_ui::mlua::{Lua, Result as LuaResult, Table};
use glacier_ui::net::{AbortHandle, Progress, Request};
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::Mutex,
};
use update_core::{
    is_newer,
    release::{
        ReleaseAsset, debian_architecture, package_version, parse_release, select_package_assets,
    },
};

/// Repositório das releases do app. Fixo no binário: a UI não escolhe de onde vem uma atualização.
const REPOSITORY: &str = "antoniofernandodj/rustploy";
/// O helper root e o binário que ele troca.
const HELPER: &str = "/usr/libexec/rustploy-gui-update";
const INSTALLED_BINARY: &str = "/usr/bin/rustploy-gui";
/// Relativo ao cache do usuário. Tem de ser o mesmo que o helper lê (`USER_CACHE_SUBDIR`).
const CACHE_SUBDIR: &str = "rustploy-gui/updates";
const MAX_DEB_BYTES: u64 = 200 * 1024 * 1024;
/// Windows: a pasta que o `install.ps1` cria em `%LOCALAPPDATA%` e o helper que vem no zip.
const PORTABLE_DIR_NAME: &str = "Rustploy";
const PORTABLE_HELPER: &str = "rustploy-gui-update.exe";
const WINDOWS_PACKAGE: &str = "rustploy-gui-windows";

/// Como este executável foi instalado: só `.deb` e o zip do `install.ps1` se atualizam pelo app.
#[derive(Debug, PartialEq, Eq)]
enum InstallKind {
    /// `/usr/bin/rustploy-gui`, instalado por `.deb`: atualiza pelo helper root.
    Deb,
    /// `%LOCALAPPDATA%\Rustploy\rustploy-gui.exe`, o zip do `install.ps1`: atualiza trocando a pasta.
    Zip,
    /// `cargo install`, zip descompactado em outro lugar, compilado do código: o app só avisa.
    Other,
}

impl InstallKind {
    fn label(&self) -> &'static str {
        match self {
            Self::Deb => "deb",
            Self::Zip => "zip",
            Self::Other => "other",
        }
    }
}

fn install_kind_of(executable: &Path, portable_dir: Option<&Path>) -> InstallKind {
    // Compara o caminho resolvido: um link para fora de /usr/bin não conta como instalado por .deb.
    let Ok(resolved) = std::fs::canonicalize(executable) else {
        return InstallKind::Other;
    };
    if resolved == Path::new(INSTALLED_BINARY) {
        return InstallKind::Deb;
    }
    let in_portable_dir = portable_dir
        .and_then(|directory| std::fs::canonicalize(directory).ok())
        .is_some_and(|directory| resolved.parent() == Some(directory.as_path()));
    if in_portable_dir {
        InstallKind::Zip
    } else {
        InstallKind::Other
    }
}

/// `%LOCALAPPDATA%\Rustploy`, só no Windows.
fn portable_dir() -> Option<PathBuf> {
    if !cfg!(windows) {
        return None;
    }
    std::env::var_os("LOCALAPPDATA")
        .filter(|value| !value.is_empty())
        .map(|local| PathBuf::from(local).join(PORTABLE_DIR_NAME))
}

/// `<pasta-do-app>-update`. Tem de ser o mesmo do helper (`staging_dir` em `portable.rs`).
fn staging_dir(install_dir: &Path) -> PathBuf {
    let mut name = install_dir.file_name().unwrap_or_default().to_os_string();
    name.push("-update");
    install_dir.with_file_name(name)
}

fn install_kind() -> InstallKind {
    std::env::current_exe()
        .map(|executable| install_kind_of(&executable, portable_dir().as_deref()))
        .unwrap_or(InstallKind::Other)
}

/// O app pode se atualizar sozinho? `.deb` + helper + `pkexec`, ou zip + helper.
fn can_update() -> bool {
    match install_kind() {
        InstallKind::Deb => Path::new(HELPER).exists() && find_in_path("pkexec").is_some(),
        InstallKind::Zip => {
            portable_dir().is_some_and(|directory| directory.join(PORTABLE_HELPER).is_file())
        }
        InstallKind::Other => false,
    }
}

fn find_in_path(program: &str) -> Option<PathBuf> {
    let file_name = format!("{program}{}", std::env::consts::EXE_SUFFIX);
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|directory| directory.join(&file_name))
            .find(|candidate| candidate.is_file())
    })
}

/// Sem janela de console piscando quando o app roda um programa no Windows.
fn without_console(command: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
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

/// O andamento da instalação, lido pelo Luau (`app_update.install_status`) enquanto a thread de
/// instalação trabalha: o download do pacote (bytes), a fase em texto e, no fim, o resultado.
struct InstallState {
    running: bool,
    phase: &'static str,
    done: u64,
    total: Option<u64>,
    abort: Option<AbortHandle>,
    result: Option<Result<String, String>>,
}

static INSTALL: Mutex<InstallState> = Mutex::new(InstallState {
    running: false,
    phase: "",
    done: 0,
    total: None,
    abort: None,
    result: None,
});

fn install_state() -> std::sync::MutexGuard<'static, InstallState> {
    INSTALL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn set_phase(phase: &'static str) {
    let mut state = install_state();
    state.phase = phase;
    state.done = 0;
    state.total = None;
}

/// Baixa `url` para `destination` pela camada de rede do glacier (`glacier_ui::net`), seguindo
/// até 5 redirecionamentos — que nunca descem de https para http — e recusando um corpo acima
/// de `max_bytes`. O progresso vai para o `INSTALL` e o `abort` cancela. A integridade e a
/// autenticidade NÃO dependem daqui: o helper root confere a assinatura do que chegar.
fn download(
    url: &str,
    destination: &Path,
    max_bytes: u64,
    abort: &AbortHandle,
) -> Result<(), String> {
    if !url.starts_with("https://github.com/") {
        return Err(format!("recusei baixar de fora do GitHub: {url}"));
    }
    let partial = destination.with_extension("partial");
    let request = Request::get(url)
        .max_redirects(5)
        .max_bytes(max_bytes)
        .timeout_ms(600_000)
        .no_cookies()
        .abortable(abort)
        .download_to(partial.to_string_lossy().into_owned())
        .on_progress(|progress: Progress| {
            let mut state = install_state();
            state.done = progress.done;
            state.total = progress.total;
        });
    // Esta thread não é a do iced: um runtime próprio, só para este pedido.
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("não consegui iniciar o download: {error}"))?;
    let result = runtime.block_on(request.send());
    if !result.ok {
        let _ = std::fs::remove_file(&partial);
        let reason = if result.error.is_empty() {
            format!("HTTP {}", result.status)
        } else {
            result.error
        };
        return Err(format!("o download falhou: {reason}"));
    }
    std::fs::rename(&partial, destination).map_err(|error| format!("gravando o download: {error}"))
}

/// O nome vira parte de um caminho: só letras, dígitos e `._+-~`, com o começo e o fim dados.
fn validate_package_name(name: &str, start: &str, end: &str) -> Result<(), String> {
    let plain = name
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "._+-~".contains(character));
    if plain && name.starts_with(start) && name.ends_with(end) && !name.contains("..") {
        Ok(())
    } else {
        Err(format!("nome de pacote inesperado: {name}"))
    }
}

fn validate_deb_name(deb_name: &str) -> Result<(), String> {
    validate_package_name(deb_name, "rustploy-gui_", ".deb")
}

fn validate_zip_name(zip_name: &str) -> Result<(), String> {
    validate_package_name(zip_name, &format!("{WINDOWS_PACKAGE}-v"), ".zip")
}

/// O zip do Windows da release (`rustploy-gui-windows-<tag>.zip`) e a `.minisig` dele, só entre os
/// arquivos do repositório. O nome leva a **tag**, não a versão do app: a versão vem do `.deb`.
fn select_windows_zip(
    assets: &[ReleaseAsset],
    tag: &str,
) -> Result<(ReleaseAsset, ReleaseAsset), String> {
    let allowed_prefix = format!("https://github.com/{REPOSITORY}/releases/download/");
    let find = |name: &str| {
        assets
            .iter()
            .find(|asset| asset.name == name && asset.url.starts_with(&allowed_prefix))
            .cloned()
    };
    let zip_name = format!("{WINDOWS_PACKAGE}-{tag}.zip");
    let zip = find(&zip_name)
        .ok_or_else(|| format!("a release {tag} não tem o zip do Windows ({zip_name})"))?;
    let signature = find(&format!("{zip_name}.minisig")).ok_or_else(|| {
        format!(
            "a release {tag} não tem a assinatura ({zip_name}.minisig); só instalo pacote assinado"
        )
    })?;
    Ok((zip, signature))
}

/// A troca já conferida, esperando o `restart` (que fecha esta janela para o helper agir).
struct PendingSwap {
    helper: PathBuf,
    install_dir: PathBuf,
    zip: PathBuf,
    signature: PathBuf,
}

static PENDING_SWAP: Mutex<Option<PendingSwap>> = Mutex::new(None);

/// Baixa o pacote certo para este jeito de instalar. `.deb`: instala já (pede a senha). Zip:
/// baixa, confere com o helper e deixa a troca para o `restart`.
fn install(
    package_url: &str,
    signature_url: &str,
    package_name: &str,
    abort: &AbortHandle,
) -> Result<String, String> {
    if !can_update() {
        return Err("este app não foi instalado por .deb nem pelo install.ps1 (ou falta o pkexec): atualize pelo comando de instalação".into());
    }
    match install_kind() {
        InstallKind::Zip => prepare_portable(package_url, signature_url, package_name, abort),
        _ => install_deb(package_url, signature_url, package_name, abort),
    }
}

/// Começa a instalação numa thread (o download e o `pkexec` bloqueiam: na thread da UI a janela
/// congelava) e volta na hora. `install_status` mostra o andamento; `install_cancel` interrompe o
/// download (a senha e a instalação, depois dele, não se cancelam daqui).
fn install_start(
    package_url: String,
    signature_url: String,
    package_name: String,
) -> Result<(), String> {
    let abort = AbortHandle::new();
    {
        let mut state = install_state();
        if state.running {
            return Err("já há uma atualização em andamento".into());
        }
        *state = InstallState {
            running: true,
            phase: "preparando",
            done: 0,
            total: None,
            abort: Some(abort.clone()),
            result: None,
        };
    }
    std::thread::spawn(move || {
        let result = install(&package_url, &signature_url, &package_name, &abort);
        let mut state = install_state();
        state.running = false;
        state.abort = None;
        state.result = Some(result);
    });
    Ok(())
}

fn install_cancel() {
    if let Some(abort) = &install_state().abort {
        abort.abort();
    }
}

fn prepare_portable(
    zip_url: &str,
    signature_url: &str,
    zip_name: &str,
    abort: &AbortHandle,
) -> Result<String, String> {
    validate_zip_name(zip_name)?;
    let install_dir = portable_dir().ok_or_else(|| "sem LOCALAPPDATA".to_string())?;
    let staging = staging_dir(&install_dir);
    // Resto de uma tentativa anterior não pode ser confundido com o pacote novo.
    if staging.exists() {
        std::fs::remove_dir_all(&staging)
            .map_err(|error| format!("apagando {}: {error}", staging.display()))?;
    }
    std::fs::create_dir_all(&staging)
        .map_err(|error| format!("criando {}: {error}", staging.display()))?;
    let zip = staging.join(zip_name);
    let signature = staging.join(format!("{zip_name}.minisig"));
    set_phase("baixando o pacote");
    download(zip_url, &zip, MAX_DEB_BYTES, abort)?;
    set_phase("baixando a assinatura");
    download(signature_url, &signature, 8 * 1024, abort)?;
    set_phase("conferindo a assinatura");

    // O helper roda de fora da pasta que vai trocar.
    let helper = staging.join(PORTABLE_HELPER);
    std::fs::copy(install_dir.join(PORTABLE_HELPER), &helper)
        .map_err(|error| format!("copiando o {PORTABLE_HELPER}: {error}"))?;
    // Confere antes de fechar a janela, com o código do próprio helper: um download ruim não
    // fecha o app à toa.
    let output = without_console(&mut Command::new(&helper))
        .arg("check")
        .arg(&install_dir)
        .arg(&zip)
        .arg(&signature)
        .output()
        .map_err(|error| format!("não consegui rodar o {PORTABLE_HELPER}: {error}"))?;
    if !output.status.success() {
        return Err(last_line(&output.stderr));
    }
    *PENDING_SWAP
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(PendingSwap {
        helper,
        install_dir,
        zip,
        signature,
    });
    Ok("conferido".to_string())
}

fn last_line(stderr: &[u8]) -> String {
    let detail = String::from_utf8_lossy(stderr);
    detail
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("falhou")
        .trim()
        .to_string()
}

/// O resultado da última troca no Windows (`result.json` do helper), lido uma vez só.
fn take_last_result() -> Option<(bool, String)> {
    let path = staging_dir(&portable_dir()?).join("result.json");
    let text = std::fs::read_to_string(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    parse_last_result(&text)
}

fn parse_last_result(text: &str) -> Option<(bool, String)> {
    let json: serde_json::Value = serde_json::from_str(text).ok()?;
    if json["ok"].as_bool()? {
        let version = json["version"].as_str().unwrap_or("?");
        Some((true, format!("App atualizado (release v{version}).")))
    } else {
        let message = json["message"].as_str().unwrap_or("falhou");
        Some((false, format!("A atualização do app falhou: {message}")))
    }
}

/// Baixa o pacote e a assinatura para o cache do usuário e chama o helper por `pkexec`.
/// Devolve a mensagem do resultado; bloqueia até o fim (download + senha + instalação) — por isso
/// roda numa thread (`install_start`).
fn install_deb(
    deb_url: &str,
    signature_url: &str,
    deb_name: &str,
    abort: &AbortHandle,
) -> Result<String, String> {
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
    set_phase("baixando o pacote");
    download(deb_url, &deb_path, MAX_DEB_BYTES, abort)?;
    set_phase("baixando a assinatura");
    download(signature_url, &signature_path, 8 * 1024, abort)?;
    set_phase("aguardando a senha e instalando");

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
        _ => Err(last_line(&output.stderr)),
    }
}

/// Abre uma nova instância do app e encerra esta. No Windows, com uma troca conferida, quem
/// reabre é o helper, depois de trocar a pasta.
fn restart() -> Result<(), String> {
    let pending = PENDING_SWAP
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    if let Some(pending) = pending {
        without_console(&mut Command::new(&pending.helper))
            .arg("swap")
            .arg(&pending.install_dir)
            .arg(&pending.zip)
            .arg(&pending.signature)
            .spawn()
            .map_err(|error| format!("não consegui rodar o {PORTABLE_HELPER}: {error}"))?;
        std::process::exit(0);
    }
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
            info.set("os", std::env::consts::OS)?;
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
                let architecture = debian_architecture()?;
                // A versão do PACOTE que a release traz, não a tag: a tag (`v0.1.18`) e a versão do
                // app (`0.1.23`) são numerações independentes.
                let package =
                    package_version(&release.assets, REPOSITORY, "rustploy-gui", architecture)
                        .ok_or_else(|| {
                            format!(
                                "a release {} não traz um pacote do app para {architecture}",
                                release.tag
                            )
                        })?;
                let is_update_available = is_newer(&package.upstream, env!("CARGO_PKG_VERSION"))
                    .map_err(|error| error.to_string())?;
                let result = lua.create_table().map_err(|error| error.to_string())?;
                let set = |key: &str, value: String| {
                    result.set(key, value).map_err(|error| error.to_string())
                };
                set("tag", release.tag.clone())?;
                set("latest_version", package.upstream.clone())?;
                set("html_url", release.html_url.clone())?;
                result
                    .set("is_update_available", is_update_available)
                    .map_err(|error| error.to_string())?;
                if is_update_available {
                    // `deb_*` é "o pacote deste jeito de instalar": no Windows, o zip. O zip sai do
                    // mesmo commit que o `.deb`, então a versão do app é a que o `.deb` anuncia.
                    let (package, signature) = if cfg!(windows) {
                        select_windows_zip(&release.assets, &release.tag)?
                    } else {
                        select_package_assets(
                            &release.assets,
                            REPOSITORY,
                            "rustploy-gui",
                            debian_architecture()?,
                            &release.tag,
                        )?
                    };
                    set("deb_url", package.url)?;
                    set("deb_name", package.name)?;
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

    // Começa a baixar, autenticar (pkexec) e instalar, numa thread. Devolve `true` ou `false, causa`.
    table.set(
        "install_start",
        lua.create_function(
            |_, (deb_url, signature_url, deb_name): (String, String, String)| {
                Ok(match install_start(deb_url, signature_url, deb_name) {
                    Ok(()) => (true, None),
                    Err(message) => (false, Some(message)),
                })
            },
        )?,
    )?;

    // { running, phase, done, total?, percent?, ok?, message? } — `ok`/`message` só depois do fim.
    table.set(
        "install_status",
        lua.create_function(|lua, ()| {
            let status = lua.create_table()?;
            let state = install_state();
            status.set("running", state.running)?;
            status.set("phase", state.phase)?;
            status.set("done", state.done)?;
            if let Some(total) = state.total {
                status.set("total", total)?;
                if total > 0 {
                    status.set("percent", state.done as f64 * 100.0 / total as f64)?;
                }
            }
            match &state.result {
                Some(Ok(message)) => {
                    status.set("ok", true)?;
                    status.set("message", message.as_str())?;
                }
                Some(Err(message)) => {
                    status.set("ok", false)?;
                    status.set("message", message.as_str())?;
                }
                None => {}
            }
            Ok(status)
        })?,
    )?;

    // Cancela o download em andamento (um `install_status` seguinte traz `ok = false`).
    table.set(
        "install_cancel",
        lua.create_function(|_, ()| {
            install_cancel();
            Ok(())
        })?,
    )?;

    table.set("restart", lua.create_function(|_, ()| Ok(restart().err()))?)?;

    // Windows: o resultado da troca feita pelo helper antes desta janela abrir. `ok, mensagem` ou
    // `nil` (nada a contar); só a primeira chamada vê.
    table.set(
        "last_result",
        lua.create_function(|_, ()| {
            Ok(match take_last_result() {
                Some((ok, message)) => (Some(ok), Some(message)),
                None => (None, None),
            })
        })?,
    )?;

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
            install_kind_of(Path::new("/nao/existe/rustploy-gui"), None),
            InstallKind::Other
        );
        assert_eq!(
            install_kind_of(Path::new("/usr/bin/true"), None),
            InstallKind::Other
        );
        assert_eq!(InstallKind::Deb.label(), "deb");
        assert_eq!(InstallKind::Zip.label(), "zip");
        assert_eq!(InstallKind::Other.label(), "other");
    }

    #[test]
    fn only_an_executable_directly_in_the_portable_dir_counts_as_zip() {
        let temp = std::env::temp_dir().join(format!("rustploy-gui-kind-{}", std::process::id()));
        let portable = temp.join("Rustploy");
        std::fs::create_dir_all(portable.join("sub")).unwrap();
        for file in [
            portable.join("rustploy-gui.exe"),
            portable.join("sub/rustploy-gui.exe"),
        ] {
            std::fs::write(&file, "").unwrap();
        }
        let elsewhere = temp.join("rustploy-gui.exe");
        std::fs::write(&elsewhere, "").unwrap();

        let kind = |executable: &Path| install_kind_of(executable, Some(&portable));
        assert_eq!(kind(&portable.join("rustploy-gui.exe")), InstallKind::Zip);
        assert_eq!(
            kind(&portable.join("sub/rustploy-gui.exe")),
            InstallKind::Other
        );
        assert_eq!(kind(&elsewhere), InstallKind::Other);
        assert_eq!(
            install_kind_of(&portable.join("rustploy-gui.exe"), None),
            InstallKind::Other
        );
        let _ = std::fs::remove_dir_all(&temp);
    }

    #[test]
    fn staging_is_next_to_the_portable_dir() {
        assert_eq!(
            staging_dir(Path::new("/x/Local/Rustploy")),
            PathBuf::from("/x/Local/Rustploy-update")
        );
    }

    #[test]
    fn zip_names_are_validated_before_becoming_paths() {
        assert!(validate_zip_name("rustploy-gui-windows-v0.1.22.zip").is_ok());
        for bad in [
            "rustploy-gui-windows-v0.1.22.zip/../x.zip",
            "rustploy-gui-windows-v..zip",
            "rustploy-gui_0.1.22-1_amd64.deb",
            "outro-v0.1.22.zip",
            "rustploy-gui-windows-v0.1.22.zip.minisig",
        ] {
            assert!(
                validate_zip_name(bad).is_err(),
                "{bad:?} deveria ser recusado"
            );
        }
    }

    #[test]
    fn the_windows_zip_is_picked_by_tag_and_only_from_the_repository() {
        let json = release_json("v9.9.9").replace(
            "\n            ]}",
            &format!(
                r#",
              {{"name":"rustploy-gui-windows-v9.9.9.zip","browser_download_url":"https://github.com/{REPOSITORY}/releases/download/v9.9.9/rustploy-gui-windows-v9.9.9.zip"}},
              {{"name":"rustploy-gui-windows-v9.9.9.zip.minisig","browser_download_url":"https://github.com/{REPOSITORY}/releases/download/v9.9.9/rustploy-gui-windows-v9.9.9.zip.minisig"}}
            ]}}"#
            ),
        );
        let release = parse_release(&json).unwrap();
        let (zip, signature) = select_windows_zip(&release.assets, "v9.9.9").unwrap();
        assert_eq!(zip.name, "rustploy-gui-windows-v9.9.9.zip");
        assert_eq!(signature.name, "rustploy-gui-windows-v9.9.9.zip.minisig");

        // Sem a assinatura, ou com o zip vindo de fora do repositório: recusa.
        let unsigned: Vec<_> = release
            .assets
            .iter()
            .filter(|asset| !asset.name.ends_with(".zip.minisig"))
            .cloned()
            .collect();
        let error = select_windows_zip(&unsigned, "v9.9.9").unwrap_err();
        assert!(error.contains("só instalo pacote assinado"), "{error}");
        let foreign: Vec<_> = release
            .assets
            .iter()
            .map(|asset| ReleaseAsset {
                name: asset.name.clone(),
                url: asset.url.replace("github.com/", "github.com/outro/"),
            })
            .collect();
        assert!(select_windows_zip(&foreign, "v9.9.9").is_err());
    }

    #[test]
    fn the_last_windows_result_becomes_a_message() {
        assert_eq!(
            parse_last_result(r#"{"ok":true,"version":"0.1.22"}"#),
            Some((true, "App atualizado (release v0.1.22).".to_string()))
        );
        let (ok, message) =
            parse_last_result(r#"{"ok":false,"message":"o app não fechou"}"#).unwrap();
        assert!(!ok);
        assert!(message.contains("o app não fechou"));
        assert_eq!(parse_last_result("lixo"), None);
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
            let error = download(url, &destination, 1024, &AbortHandle::new()).unwrap_err();
            assert!(error.contains("fora do GitHub"), "{url}: {error}");
        }
        assert!(!destination.exists());
    }

    #[test]
    fn install_runs_in_a_thread_and_reports_the_result() {
        // Aqui o executável não é um `.deb` instalado, então a instalação recusa — mas o caminho
        // inteiro (thread, estado, resultado) roda, e uma segunda chamada enquanto roda é recusada.
        install_start(
            "https://github.com/x".into(),
            "https://github.com/y".into(),
            "x.deb".into(),
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let state = install_state();
            if !state.running {
                let result = state.result.as_ref().expect("terminou com um resultado");
                assert!(
                    result.as_ref().unwrap_err().contains("não foi instalado"),
                    "{result:?}"
                );
                break;
            }
            drop(state);
            assert!(
                std::time::Instant::now() < deadline,
                "a thread não terminou"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    /// Rede de verdade (`cargo test -- --ignored`): baixa o `.deb` do app de uma release pública,
    /// que o GitHub redireciona para outro host, e confere tamanho e progresso.
    #[test]
    #[ignore = "usa a rede (GitHub)"]
    fn downloads_a_real_release_asset_through_redirects() {
        let url = "https://github.com/antoniofernandodj/rustploy/releases/download/v0.1.29/rustploy-gui_0.1.32-1_amd64.deb";
        let destination = std::env::temp_dir().join("rustploy-gui-real-download.deb");
        let _ = std::fs::remove_file(&destination);
        set_phase("teste");
        download(url, &destination, MAX_DEB_BYTES, &AbortHandle::new()).unwrap();
        assert_eq!(std::fs::metadata(&destination).unwrap().len(), 10_558_520);
        let state = install_state();
        assert_eq!(state.done, 10_558_520);
        assert_eq!(state.total, Some(10_558_520));
        drop(state);
        let _ = std::fs::remove_file(&destination);
        // O teto de tamanho recusa antes de gravar.
        let error = download(url, &destination, 1024, &AbortHandle::new()).unwrap_err();
        assert!(error.contains("teto"), "{error}");
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
        release_json_with(tag, tag.trim_start_matches('v'))
    }

    /// `tag` e a versão do app que a release traz são numerações independentes.
    fn release_json_with(tag: &str, app_version: &str) -> String {
        let base = format!("https://github.com/{REPOSITORY}/releases/download/{tag}");
        format!(
            r#"{{"tag_name":"{tag}","html_url":"https://github.com/{REPOSITORY}/releases/tag/{tag}","assets":[
              {{"name":"rustploy-gui_{app_version}-1_amd64.deb","browser_download_url":"{base}/rustploy-gui_{app_version}-1_amd64.deb"}},
              {{"name":"rustploy-gui_{app_version}-1_amd64.deb.minisig","browser_download_url":"{base}/rustploy-gui_{app_version}-1_amd64.deb.minisig"}},
              {{"name":"rustploy-gui_{app_version}-1_arm64.deb","browser_download_url":"{base}/rustploy-gui_{app_version}-1_arm64.deb"}},
              {{"name":"rustploy-gui_{app_version}-1_arm64.deb.minisig","browser_download_url":"{base}/rustploy-gui_{app_version}-1_arm64.deb.minisig"}}
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
        let (_lua, plan, error) =
            run_plan(&release_json(&format!("v{}", env!("CARGO_PKG_VERSION"))));
        assert_eq!(error, None);
        let plan = plan.unwrap();
        assert!(!plan.get::<bool>("is_update_available").unwrap());
        assert!(matches!(plan.get::<Value>("deb_url").unwrap(), Value::Nil));
    }

    #[test]
    fn the_release_tag_does_not_decide_only_the_app_package_does() {
        // Tag nova (v9.9.9) com o MESMO app que já roda: em dia. Tag velha com app mais novo: há versão.
        let running = env!("CARGO_PKG_VERSION");
        let (_lua, plan, error) = run_plan(&release_json_with("v9.9.9", running));
        assert_eq!(error, None);
        let plan = plan.unwrap();
        assert!(!plan.get::<bool>("is_update_available").unwrap());
        assert_eq!(plan.get::<String>("latest_version").unwrap(), running);

        let (_lua, plan, _) = run_plan(&release_json_with("v0.0.1", "9.9.9"));
        assert!(plan.unwrap().get::<bool>("is_update_available").unwrap());
    }

    #[test]
    fn a_release_without_an_app_package_is_an_error() {
        let json = release_json("v9.9.9").replace("rustploy-gui_", "outro-produto_");
        let (_lua, plan, error) = run_plan(&json);
        assert!(plan.is_none());
        assert!(error.unwrap().contains("não traz um pacote do app"));
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
