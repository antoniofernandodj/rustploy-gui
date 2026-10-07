//! `rustploy-gui --install-desktop`: integração com o desktop para quem instalou
//! por `cargo install` (o `.deb` já instala esses arquivos; o cargo não).
//!
//! Grava, só para o usuário atual, o `.desktop` e os ícones hicolor em
//! `$XDG_DATA_HOME` (padrão `~/.local/share`), com `Exec=` apontando para este
//! executável. Os arquivos vão embutidos no binário. Só Linux; nunca roda sozinho.

use std::path::{Path, PathBuf};
use std::process::Command;

const DESKTOP: &str = include_str!("../packaging/rustploy-gui.desktop");

/// `(subdiretório hicolor, bytes)` — espelha `packaging/icons/hicolor/`.
const ICONS: &[(&str, &[u8])] = &[
    ("16x16", include_bytes!("../packaging/icons/hicolor/16x16/apps/rustploy-gui.png")),
    ("32x32", include_bytes!("../packaging/icons/hicolor/32x32/apps/rustploy-gui.png")),
    ("48x48", include_bytes!("../packaging/icons/hicolor/48x48/apps/rustploy-gui.png")),
    ("64x64", include_bytes!("../packaging/icons/hicolor/64x64/apps/rustploy-gui.png")),
    ("128x128", include_bytes!("../packaging/icons/hicolor/128x128/apps/rustploy-gui.png")),
    ("256x256", include_bytes!("../packaging/icons/hicolor/256x256/apps/rustploy-gui.png")),
];
const ICON_SVG: &[u8] = include_bytes!("../packaging/icons/hicolor/scalable/apps/rustploy-gui.svg");

/// Trata `--install-desktop`. `Some(código)` = o argumento era esse e o processo
/// deve terminar com ele; `None` = não era, segue o fluxo normal.
pub fn handle_args() -> Option<i32> {
    if !std::env::args().skip(1).any(|a| a == "--install-desktop") {
        return None;
    }
    Some(match install() {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("rustploy-gui: --install-desktop falhou: {e}");
            1
        }
    })
}

#[cfg(not(target_os = "linux"))]
fn install() -> Result<(), String> {
    Err("só há integração de desktop no Linux".into())
}

#[cfg(target_os = "linux")]
fn install() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| format!("executável atual: {e}"))?;
    let exe = exe.to_str().ok_or("caminho do executável não é UTF-8")?;
    let data = data_home()?;

    let apps = data.join("applications");
    write(&apps.join("rustploy-gui.desktop"), exec_com(DESKTOP, exe).as_bytes())?;

    let hicolor = data.join("icons/hicolor");
    for (size, bytes) in ICONS {
        write(&hicolor.join(size).join("apps/rustploy-gui.png"), bytes)?;
    }
    write(&hicolor.join("scalable/apps/rustploy-gui.svg"), ICON_SVG)?;

    // Best-effort: sem essas ferramentas o menu só atualiza no próximo login.
    let _ = Command::new("update-desktop-database").arg("-q").arg(&apps).status();
    let _ = Command::new("gtk-update-icon-cache").arg("-qtf").arg(&hicolor).status();

    println!("Instalado em {} (Exec={exe})", data.display());
    Ok(())
}

fn data_home() -> Result<PathBuf, String> {
    if let Some(x) = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(x));
    }
    let home = std::env::var_os("HOME").ok_or("HOME não definido")?;
    Ok(PathBuf::from(home).join(".local/share"))
}

/// Troca a linha `Exec=` pelo caminho absoluto deste executável (entre aspas,
/// como exige a spec do Desktop Entry quando há espaços ou caracteres especiais).
fn exec_com(desktop: &str, exe: &str) -> String {
    // Dois níveis de escape: o do valor do arquivo (`\\` → `\`) e o do Exec (`\` + char).
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

fn write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("criar {}: {e}", dir.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("gravar {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_aponta_para_o_executavel_e_preserva_o_resto() {
        let out = exec_com(DESKTOP, "/home/u/.cargo/bin/rustploy-gui");
        assert!(out.contains("Exec=\"/home/u/.cargo/bin/rustploy-gui\"\n"));
        assert!(!out.contains("Exec=rustploy-gui"));
        assert!(out.contains("StartupWMClass=rustploy-gui"));
    }

    #[test]
    fn exec_escapa_caracteres_especiais() {
        let out = exec_com("Exec=x\n", "/a b/$c");
        assert_eq!(out, "Exec=\"/a b/\\\\$c\"\n");
    }
}
