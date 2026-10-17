# vendor/

## iced_tiny_skia (0.14.0, patch de 2 trechos)

Cópia do `iced_tiny_skia` 0.14.0 com dois ajustes em `src/engine.rs`, ambos marcados
`RUSTPLOY`. (2) No arm `Text::Cached` (`fill_text`: o placeholder de um campo de texto, por
exemplo), o recorte do próprio texto nunca chegava à máscara, só o da camada, e um texto mais
largo que o campo vazava para o vizinho; não está corrigido no upstream que olhei (0.14.0).
(1) No arm `Text::Editor`: o recorte do `text_editor` passa a ser
sempre aplicado. No upstream ele é pulado quando `editor.bounds` cabe no
recorte, mas o editor desenha linhas parciais além dessa caixa — no renderer de
software, a linha cortada na borda de cima/baixo de um `<textarea>` saía inteira
e sobreposta à vizinha (visto na janela de logs). A 0.14.1 tem o mesmo defeito.

Ativado por `[patch.crates-io]` no `Cargo.toml` da raiz. O app cai no tiny-skia
quando o wgpu/GL não sobe (ex.: Intel Ivy Bridge, `WGPU_BACKEND=gl`).

O upstream JÁ corrigiu (commit `23170119b`, 2026-01-28, "Always clip
`Text::Editor` in `tiny_skia`"), mas só na `master` (pós-0.14.x). Remover esta
pasta e o `[patch.crates-io]` quando o glacier-ui migrar para um iced que
contenha esse commit (0.15+).
