//! Os catálogos de idioma (`locales/en.json` e `locales/pt-BR.json`) e as views que os usam.
//!
//! Duas famílias de chave convivem: a **semântica** do markup (`{t('docker_images.no_images')}`,
//! sempre com ponto e sem espaço) e o **texto de origem** do Luau (`i18n.tr("Remover tag?")`, o
//! próprio texto é a chave). Este teste guarda a primeira: toda chave usada num `.gv` existe nos
//! dois idiomas, e nenhuma chave semântica sobra sem uso. Para a segunda não há o que conferir —
//! um texto sem entrada só aparece no idioma em que foi escrito, de propósito.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

fn read_catalog(name: &str) -> BTreeMap<String, String> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("locales")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{}: JSON inválido: {error}", path.display()))
}

fn gv_files(directory: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(directory).expect("ler views/").flatten() {
        let path = entry.path();
        if path.is_dir() {
            gv_files(&path, out);
        } else if path.extension().is_some_and(|extension| extension == "gv") {
            out.push(path);
        }
    }
}

/// Toda chave de `{t('chave'…)}` escrita nas views.
fn keys_used_in_views() -> BTreeSet<String> {
    let mut files = Vec::new();
    gv_files(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("views"),
        &mut files,
    );
    let mut keys = BTreeSet::new();
    for file in files {
        let text = std::fs::read_to_string(&file).expect("ler .gv");
        let mut rest = text.as_str();
        while let Some(start) = rest.find("{t('") {
            let after = &rest[start + 4..];
            if let Some(end) = after.find('\'') {
                keys.insert(after[..end].to_string());
            }
            rest = &after[1.min(after.len())..];
        }
    }
    keys
}

fn looks_semantic(key: &str) -> bool {
    key.contains('.')
        && !key.contains(' ')
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '.')
}

#[test]
fn every_key_used_in_the_views_exists_in_both_languages() {
    let english = read_catalog("en.json");
    let portuguese = read_catalog("pt-BR.json");
    let mut missing = Vec::new();
    for key in keys_used_in_views() {
        if !english.contains_key(&key) {
            missing.push(format!("en: {key}"));
        }
        if !portuguese.contains_key(&key) {
            missing.push(format!("pt-BR: {key}"));
        }
    }
    assert!(
        missing.is_empty(),
        "chaves usadas nas views e ausentes do catálogo:\n  {}",
        missing.join("\n  ")
    );
}

#[test]
fn no_semantic_key_is_left_unused() {
    let used = keys_used_in_views();
    for name in ["en.json", "pt-BR.json"] {
        let orphans: Vec<String> = read_catalog(name)
            .into_keys()
            .filter(|key| looks_semantic(key) && !used.contains(key))
            .collect();
        assert!(
            orphans.is_empty(),
            "{name}: chaves sem uso nas views:\n  {}",
            orphans.join("\n  ")
        );
    }
}

#[test]
fn both_languages_have_the_same_semantic_keys() {
    let semantic = |catalog: BTreeMap<String, String>| -> BTreeSet<String> {
        catalog
            .into_keys()
            .filter(|key| looks_semantic(key))
            .collect()
    };
    assert_eq!(
        semantic(read_catalog("en.json")),
        semantic(read_catalog("pt-BR.json"))
    );
}
