//! Rustploy (glacier-ui) — desktop client whose UI is described in XML
//! templates and rendered by the published `glacier-ui` engine.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod app;
#[cfg(not(debug_assertions))]
mod embedded;

fn main() -> iced::Result {
    limit_malloc_arenas();
    #[cfg(debug_assertions)]
    {
        let (view_file, assets_env_var, installed_assets_dir) =
            ("views/app.gv", "RUSTPLOY_UI_ASSETS", "/usr/share/rustploy");
        glacier_ui::locate_assets_and_chdir(view_file, assets_env_var, Some(installed_assets_dir));
    }
    app::run()
}

/// Limita o malloc do glibc a 2 arenas (o mesmo que `MALLOC_ARENA_MAX=2`), antes de subir
/// qualquer thread.
///
/// Por padrão o glibc cria até 8 arenas por núcleo — uma para cada thread que aloca —, e a
/// memória livre numa arena não serve às outras. A GUI tem ~16 threads (iced, wgpu, tokio,
/// bandeja) e quase todo o trabalho numa só, então as arenas extras são memória parada.
/// Medido em 2026-11-20 (docs/arquivo/estudo-consumo-de-ram.md, R-6): −4,5 MB de memória anônima;
/// jemalloc (no lugar do mimalloc) ficou PIOR, +5 MB, por isso não trocamos de alocador.
/// Uma variável `MALLOC_ARENA_MAX` no ambiente continua valendo (o glibc a lê antes).
fn limit_malloc_arenas() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    if std::env::var_os("MALLOC_ARENA_MAX").is_none() {
        // SAFETY: `mallopt` só ajusta um parâmetro do alocador; chamado no começo do
        // `main`, antes de qualquer thread nossa existir.
        unsafe {
            libc::mallopt(libc::M_ARENA_MAX, 2);
        }
    }
}
