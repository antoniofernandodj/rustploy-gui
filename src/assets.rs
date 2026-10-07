//! Runtime asset location.

use std::path::{Path, PathBuf};

/// A file that must exist under any valid asset base — used as the probe.
const MARKER: &str = "views/app.gvb";

/// System-wide install prefix used by the Debian package (see the `deb`
/// metadata in `Cargo.toml`).
const SYSTEM_PREFIX: &str = "/usr/share/rustploy";

/// Finds the asset base directory and `chdir`s into it so all the
/// CWD-relative asset paths resolve.
pub fn locate_and_chdir() {
    if let Some(base) = find_base() {
        if let Err(e) = std::env::set_current_dir(&base) {
            eprintln!("assets: falha ao entrar em {}: {e}", base.display());
        }
    }
}

fn find_base() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("RUSTPLOY_UI_ASSETS") {
        let p = PathBuf::from(dir);
        if has_marker(&p) { return Some(p); }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            if has_marker(dir) { return Some(dir.to_path_buf()); }
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        if has_marker(&cwd) { return None; }
    }

    let system = PathBuf::from(SYSTEM_PREFIX);
    if has_marker(&system) { return Some(system); }

    None
}

fn has_marker(base: &Path) -> bool {
    base.join(MARKER).is_file()
}
