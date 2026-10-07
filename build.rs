//! Build script: logos dos blueprints para o release e recursos do `.exe` no Windows.

use std::path::Path;

/// Extensões de imagem que os logos de blueprint usam (o resto da pasta —
/// `docker-compose.yml`/`template.toml`/`.md` — é do daemon e a GUI nunca lê).
const LOGO_EXTS: &[&str] = &[
    "png", "svg", "webp", "jpg", "jpeg", "gif", "ico", "avif", "bmp",
];

/// Alvo do redimensionamento dos logos raster: a maior dimensão é reduzida para
/// no máximo isto, preservando a proporção.
const LOGO_MAX_DIM: u32 = 96;

fn main() {
    stage_blueprint_logos();
    install_desktop_entry();

    println!("cargo:rerun-if-changed=assets/rustploy.rc");
    println!("cargo:rerun-if-changed=assets/rustploy.ico");
    println!("cargo:rerun-if-changed=assets/application.manifest");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".into());

    let mut parts: Vec<String> = version
        .split(['.', '-', '+'])
        .filter(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_owned)
        .collect();

    while parts.len() < 4 {
        parts.push("0".into());
    }

    let comma = parts[..4].join(",");

    let macros = [
        format!("RUSTPLOY_VER_COMMA={comma}"),
        format!("RUSTPLOY_VER_STR=\"{version}\""),
    ];

    let _ = embed_resource::compile("assets/rustploy.rc", &macros);
}

/// Leva os logos de `assets/blueprint-logos/**` para
/// `$OUT_DIR/blueprint_logos/**`, **espelhando a estrutura `<id>/<arquivo>`** (o
/// caminho por onde o `EmbeddedAssets` os serve) e **reduzindo os raster** (ver
/// [`copy_images`]/[`downscale_png`]).
fn stage_blueprint_logos() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let out = std::env::var("OUT_DIR").expect("OUT_DIR");
    let src = Path::new(&manifest).join("assets/blueprint-logos");
    let dst = Path::new(&out).join("blueprint_logos");

    println!("cargo:rerun-if-changed={}", src.display());

    let _ = std::fs::remove_dir_all(&dst);
    std::fs::create_dir_all(&dst).expect("criar staging de logos");

    copy_images(&src, &dst);
}

/// Percorre recursivamente `src` e leva os logos para `dst`, preservando o
/// caminho relativo.
fn copy_images(src: &Path, dst: &Path) {
    let entries = match std::fs::read_dir(src) {
        Ok(e) => e,
        Err(e) => panic!("lendo {}: {e}", src.display()),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            copy_images(&path, &dst.join(entry.file_name()));
            continue;
        }
        let out = dst.join(entry.file_name());
        if is_raster(&path) {
            std::fs::create_dir_all(dst).expect("criar diretório de staging");
            stage_raster(&path, &out);
        } else if is_logo(&path) {
            std::fs::create_dir_all(dst).expect("criar diretório de staging");
            std::fs::copy(&path, &out)
                .unwrap_or_else(|e| panic!("copiando {}: {e}", path.display()));
        }
    }
}

/// Lê um logo raster, reduz para no máx [`LOGO_MAX_DIM`] (Lanczos3) re-encodando
/// como PNG, e grava em `dst`.
fn stage_raster(src: &Path, dst: &Path) {
    let bytes = std::fs::read(src).unwrap_or_else(|e| panic!("lendo {}: {e}", src.display()));
    let staged = downscale_png(&bytes).unwrap_or(bytes);
    std::fs::write(dst, staged).unwrap_or_else(|e| panic!("gravando {}: {e}", dst.display()));
}

/// Decodifica `bytes`, e — se a maior dimensão passar de [`LOGO_MAX_DIM`] —
/// reduz preservando a proporção (Lanczos3) e re-encoda como PNG.
fn downscale_png(bytes: &[u8]) -> Option<Vec<u8>> {
    let img = image::load_from_memory(bytes).ok()?;
    if img.width().max(img.height()) <= LOGO_MAX_DIM {
        return None;
    }
    let resized = img.resize(
        LOGO_MAX_DIM,
        LOGO_MAX_DIM,
        image::imageops::FilterType::Lanczos3,
    );
    let mut out = Vec::new();
    resized
        .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
        .ok()?;
    Some(out)
}

fn ext_lower(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
}

/// Qualquer arquivo de logo (raster, vetor ou os formatos raros) — decide o que
/// entra no staging.
fn is_logo(path: &Path) -> bool {
    ext_lower(path).is_some_and(|e| LOGO_EXTS.contains(&e.as_str()))
}

/// Um logo raster que o `image` sabe decodificar (as features habilitadas no
/// `Cargo.toml`).
fn is_raster(path: &Path) -> bool {
    matches!(
        ext_lower(path).as_deref(),
        Some("png" | "webp" | "jpg" | "jpeg" | "gif" | "bmp")
    )
}

// ── Integração com o desktop no `cargo install` (Linux) ──────────────────────
//
// O cargo não tem hook de pós-instalação, e o `.desktop`/ícones só chegavam via
// `.deb`. O `build.rs` roda na máquina do usuário durante o `cargo install`, então
// é onde dá para gravá-los em `~/.local/share`. Só faz isso quando o build É um
// `cargo install` — o cargo compila num diretório temporário `cargo-install*`, e
// é isso que `is_cargo_install` reconhece (detalhe interno do cargo; se mudar, só
// deixa de instalar sozinho e `rustploy-gui --install-desktop` continua valendo).
// Nunca falha o build: qualquer erro vira só um `cargo:warning`.
//
// `RUSTPLOY_INSTALL_DESKTOP=0` desliga; `=1` força (útil p/ testar).

fn install_desktop_entry() {
    println!("cargo:rerun-if-env-changed=RUSTPLOY_INSTALL_DESKTOP");
    println!("cargo:rerun-if-changed=packaging/rustploy-gui.desktop");
    println!("cargo:rerun-if-changed=packaging/icons");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("linux") || !cfg!(target_os = "linux")
    {
        return;
    }
    let forced = std::env::var("RUSTPLOY_INSTALL_DESKTOP").ok();
    match forced.as_deref() {
        Some("0") => return,
        Some("1") => {}
        _ if is_cargo_install() => {}
        _ => return,
    }
    if let Err(e) = write_desktop_entry() {
        println!("cargo:warning=rustploy-gui: não instalei o .desktop ({e}); use `rustploy-gui --install-desktop`");
    }
}

fn is_cargo_install() -> bool {
    std::env::var("OUT_DIR").is_ok_and(|out| {
        Path::new(&out)
            .components()
            .any(|c| c.as_os_str().to_string_lossy().starts_with("cargo-install"))
    })
}

fn write_desktop_entry() -> Result<(), String> {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").map_err(|e| e.to_string())?;
    let pkg = Path::new(&manifest).join("packaging");
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty()).ok_or("HOME não definido")?;
    let home = std::path::PathBuf::from(home);

    let data = match std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        Some(x) => std::path::PathBuf::from(x),
        None => home.join(".local/share"),
    };

    // Onde o `cargo install` vai pôr o binário: --root não chega aqui, então
    // vale CARGO_INSTALL_ROOT, CARGO_HOME ou ~/.cargo (o padrão do cargo).
    let bin_dir = if let Some(r) = std::env::var_os("CARGO_INSTALL_ROOT").filter(|v| !v.is_empty()) {
        std::path::PathBuf::from(r).join("bin")
    } else if let Some(c) = std::env::var_os("CARGO_HOME").filter(|v| !v.is_empty()) {
        std::path::PathBuf::from(c).join("bin")
    } else {
        home.join(".cargo/bin")
    };
    let exe = bin_dir.join("rustploy-gui");
    let exe = exe.to_str().ok_or("caminho do executável não é UTF-8")?;

    let desktop = std::fs::read_to_string(pkg.join("rustploy-gui.desktop")).map_err(|e| e.to_string())?;
    let apps = data.join("applications");
    write_file(&apps.join("rustploy-gui.desktop"), exec_com(&desktop, exe).as_bytes())?;

    // Espelha packaging/icons/hicolor/** em $data/icons/hicolor/**.
    let src = pkg.join("icons/hicolor");
    let dst = data.join("icons/hicolor");
    copy_tree(&src, &dst)?;

    let _ = std::process::Command::new("update-desktop-database").arg("-q").arg(&apps).status();
    let _ = std::process::Command::new("gtk-update-icon-cache").arg("-qtf").arg(&dst).status();
    Ok(())
}

/// Mesmo escape de `src/desktop.rs::exec_com` (duplicado: o build script não
/// enxerga o crate). Aspas + `\` dobrado antes de `\`, `"`, `` ` `` e `$`.
fn exec_com(desktop: &str, exe: &str) -> String {
    let mut quoted = String::from("\"");
    for c in exe.chars() {
        if matches!(c, '\\' | '"' | '`' | '$') {
            quoted.push_str("\\\\");
        }
        quoted.push(c);
    }
    quoted.push('"');
    desktop
        .lines()
        .map(|l| if l.starts_with("Exec=") { format!("Exec={quoted}") } else { l.to_string() })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("criar {}: {e}", dir.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("gravar {}: {e}", path.display()))
}

fn copy_tree(src: &Path, dst: &Path) -> Result<(), String> {
    for entry in std::fs::read_dir(src).map_err(|e| format!("ler {}: {e}", src.display()))?.flatten() {
        let (from, to) = (entry.path(), dst.join(entry.file_name()));
        if from.is_dir() {
            copy_tree(&from, &to)?;
        } else {
            write_file(&to, &std::fs::read(&from).map_err(|e| e.to_string())?)?;
        }
    }
    Ok(())
}
