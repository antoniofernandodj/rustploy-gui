//! O `fmt/time.luau` rodando no motor de verdade.

use glacier_ui::GlacierUI;

fn boot() -> GlacierUI {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    let ws_root = std::path::Path::new(crate_dir);
    std::env::set_current_dir(ws_root).expect("cd workspace root");

    unsafe {
        std::env::set_var("GLACIER_LUAU_PATH", "views/scripts");
    }

    let mut m = GlacierUI::new();
    m.register_component("tempo", "tests/fixtures/tempo.gvb")
        .expect("registrar a fixture");
    m.set_initial_screen("tempo");
    m
}

#[test]
fn time_luau_converte_utc_para_hora_local() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    let z = g("hms_z");
    assert_eq!(z.len(), 8, "HH:MM:SS, deu {z:?}");
    assert_eq!(
        z,
        g("hms_off"),
        "`...Z` e `...-03:00` do mesmo instante têm de renderizar igual"
    );
    assert_eq!(z, g("hms_frac"));

    let offset = offset_local_segundos();
    let esperado = hora_deslocada("12:34:56", offset);
    assert_eq!(z, esperado, "offset local de {offset}s não foi aplicado");
}

#[test]
fn time_luau_formata_data_e_hora_e_tolera_vazio() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    let dm_hm = g("dm_hm");
    assert_eq!(dm_hm.len(), 11, "dd/mm HH:MM, deu {dm_hm:?}");
    assert!(dm_hm.contains('/') && dm_hm.contains(':'));
    assert_eq!(g("dm_hms").len(), 14, "dd/mm HH:MM:SS");
    assert!(g("dm_hms").starts_with(&dm_hm));

    assert_eq!(g("vazio_nil"), "");
    assert_eq!(g("vazio_lixo"), "");
}

#[test]
fn time_luau_mede_duracao_entre_instantes_com_fuso() {
    let m = boot();
    let g = |k: &str| m.context().get(k).cloned().unwrap_or_default();

    assert_eq!(g("dur"), "1m 30s");
    assert!(
        g("dur_aberta").ends_with('s'),
        "duração aberta: {:?}",
        g("dur_aberta")
    );
    assert_eq!(g("dur_invalida"), "0s");
}

/// Offset local em segundos, perguntado ao sistema — a mesma fonte que o
/// `localtime` do Luau consulta.
fn offset_local_segundos() -> i64 {
    let saida = std::process::Command::new("date")
        .arg("+%z")
        .output()
        .expect("date +%z");
    let txt = String::from_utf8_lossy(&saida.stdout).trim().to_string();
    let sinal = if txt.starts_with('-') { -1 } else { 1 };
    let horas: i64 = txt[1..3].parse().expect("horas do offset");
    let minutos: i64 = txt[3..5].parse().expect("minutos do offset");
    sinal * (horas * 3600 + minutos * 60)
}

/// `HH:MM:SS` + offset, com a virada de dia descartada (só as horas importam).
fn hora_deslocada(hms: &str, offset: i64) -> String {
    let partes: Vec<i64> = hms.split(':').map(|p| p.parse().unwrap()).collect();
    let total = (partes[0] * 3600 + partes[1] * 60 + partes[2] + offset).rem_euclid(86400);
    format!(
        "{:02}:{:02}:{:02}",
        total / 3600,
        total % 3600 / 60,
        total % 60
    )
}
