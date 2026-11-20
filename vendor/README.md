# vendor/

## iced_tiny_skia (0.14.0, patch de 3 trechos)

Cópia do `iced_tiny_skia` 0.14.0 com dois ajustes em `src/engine.rs`, ambos marcados
`RUSTPLOY`. (2) No arm `Text::Cached` (`fill_text`: o placeholder de um campo de texto, por
exemplo), o recorte do próprio texto nunca chegava à máscara, só o da camada, e um texto mais
largo que o campo vazava para o vizinho; não está corrigido no upstream que olhei (0.14.0).
(1) No arm `Text::Editor`: o recorte do `text_editor` passa a ser
sempre aplicado. No upstream ele é pulado quando `editor.bounds` cabe no
recorte, mas o editor desenha linhas parciais além dessa caixa — no renderer de
software, a linha cortada na borda de cima/baixo de um `<textarea>` saía inteira
e sobreposta à vizinha (visto na janela de logs). A 0.14.1 tem o mesmo defeito.

(3) Em `draw_quad`, um retângulo **liso** (sem raio) de cor sólida vai por `fill_rect`
recortado por interseção com `clip_bounds`, em vez de `fill_path` com supersampling
passando pela máscara de recorte. É o caminho de todo fundo (janela, conteúdo,
painel, faixas de tabela), e cada quadro de rolagem os mesclava com máscara sobre a
região danificada inteira: na tabela de Deployments, ~110 ms → ~38 ms por quadro
(medido em 2026-11-20, Intel HD 2500). O encaixe nos pixels é feito à mão, pela regra do
centro da máscara: o `Rect::round` do tiny-skia dá no mínimo 1 px e pintava lascas fora
da região (fios de linha por cima do cabeçalho fixo). Não é correção de bug, é
desempenho: ao migrar para o iced 0.15+, conferir se o upstream já tem algo
equivalente antes de jogar a pasta fora.

Ativado por `[patch.crates-io]` no `Cargo.toml` da raiz. O app cai no tiny-skia
quando o wgpu/GL não sobe (ex.: Intel Ivy Bridge, `WGPU_BACKEND=gl`).

O upstream JÁ corrigiu (commit `23170119b`, 2026-01-28, "Always clip
`Text::Editor` in `tiny_skia`"), mas só na `master` (pós-0.14.x). Remover esta
pasta e o `[patch.crates-io]` quando o glacier-ui migrar para um iced que
contenha esse commit (0.15+).
