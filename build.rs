//! Build script: logos dos blueprints para o release, `.desktop` no `cargo install`
//! e recursos do `.exe` no Windows. A lógica mora no `glacier-build`.

fn main() {
    // Os originais têm ~512 px e aparecem a ~30 px: reduz para 96 (o binário
    // carregava ~12 MB de logo). Embutidos depois por `embedded.rs`.
    glacier_build::stage_images("assets/blueprint-logos", "blueprint_logos", 96);
    glacier_build::desktop_on_cargo_install(
        "rustploy-gui",
        "packaging",
        "RUSTPLOY_INSTALL_DESKTOP",
    );
    glacier_build::windows_resource(
        "assets/rustploy.rc",
        "RUSTPLOY",
        &["assets/rustploy.ico", "assets/application.manifest"],
    );
}
