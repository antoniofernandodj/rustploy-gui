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
