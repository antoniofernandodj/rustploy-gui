# rustploy-gui por dentro

Este documento explica o código do `rustploy-gui`: o **Rust** (`src/`, `build.rs`,
`tests/`) e os **templates de markup** (`views/**/*.gvb`). Ele existe porque o código
foi deliberadamente enxugado. No Rust, cada item tem **uma frase** de documentação (a que
o `make index` usa como descrição) e nenhum comentário `//`. Nos `.gvb`, cada arquivo
guarda só a primeira frase do cabeçalho e comentários discretos de uma linha (divisores,
rótulos). Tudo o que é *porquê*, *contexto* e *decisão descartada* mora aqui. Os nomes
entre crases (`arquivo.rs::função`, `views/x.gvb`) apontam para onde cada assunto vive.

Os assuntos, na ordem em que fazem sentido para quem chega agora:

1. [O que é este crate e o que ele não é](#1-o-que-é-este-crate-e-o-que-ele-não-é)
2. [Onde estão os assets](#2-onde-estão-os-assets)
3. [A ponte do zip do Infra as Code](#3-a-ponte-do-zip-do-infra-as-code)
4. [A API de agente](#4-a-api-de-agente)
5. [Os testes e o que cada um trava](#5-os-testes-e-o-que-cada-um-trava)
6. [Os templates `.gvb` por dentro](#6-os-templates-gvb-por-dentro)

Documentos relacionados: `docs/api-agente-no-gui.md` (desenho da API de agente),
`docs/plano-erro-de-deploy-invisivel.md` (de onde veio a motivação da rota de
deploy) e `docs/plano-reforma-gui-glacier-0.102.md` (a reforma da UI).

---

## 1. O que é este crate e o que ele não é

O Rustploy GUI é um cliente desktop cuja interface é descrita em **templates de
markup** (`views/**/*.gvb`) e renderizada pelo motor `glacier-ui` publicado. Toda
a lógica de rede vive em **Luau** (`views/scripts/app.luau` e os módulos que ele
carrega), falando HTTP/JSON e SSE com o daemon. O Rust é só a casca da janela:
`src/main.rs` e `src/app/mod.rs`.

### O manifesto `app(...)`

A configuração de janela, de aplicativo e as telas moram no **markup** de
`views/app.gvb`, cuja raiz é o `app(...)` (glacier-ui 0.117+):

- `id`, `single_instance` e `remember_geometry` — instância única, geometria
  lembrada e o diretório de dados do `storage` do Luau;
- a janela principal: `size`, `min_size`, `decorations`, `icon`;
- a `tray`, com o menu da bandeja;
- as `screen`s: a principal e as cinco janelas auxiliares, abertas por
  `open_window{ component = "…", size = "…" }`.

O runner `GlacierDaemon` lê isso antes de abrir qualquer janela. A partir do
glacier-ui 0.119 o mesmo `app(...)` também declara as fontes (`font(src, family)`
e `font = …`), o `antialiasing`, o `toast_period` e o `application_id` do Linux.

Sobra para o Rust só o que o markup não expressa:

1. a **extensão Luau do `.zip`** (ver [seção 3](#3-a-ponte-do-zip-do-infra-as-code));
2. o **espelho da sessão** para a API de agente (ver [seção 4](#4-a-api-de-agente));
3. a **fonte de assets embutida** em release (ver [seção 2](#2-onde-estão-os-assets)).

O `.main_template("views/app.gvb")` carrega o manifesto. O caminho é relativo ao
workspace, onde `assets::locate_and_chdir` deixa o diretório corrente. Um
`.main(|motor| …)` só serviria para registrar um `impl Component` escrito em
Rust, e este app não tem nenhum.

### O ciclo de vida em `app::run`

`app::run` sobe o daemon multi-janela e roda o loop do `iced` até a última
janela fechar. Fechar a janela apenas recolhe o app para a bandeja; `run` só
volta quando o app encerra de verdade. A ordem das peças importa:

1. **Sessão compartilhada.** Cria-se o `SharedSession` da API de agente, o
   servidor HTTP local (hyper) que empresta a sessão desta janela a um agente
   rodando na mesma máquina para operar o rustploy **remoto**.
2. **Canal de mão contrária.** `glacier_ui::external::sender()` (glacier-ui
   0.58.6+) deixa a thread do servidor injetar ações no motor desta janela — é o
   que torna login, navegação e qualquer botão alcançáveis por HTTP. Ele é criado
   **antes** de `run()`, porque é nesse momento que o daemon decide registrar a
   subscription que o drena.
3. **Extensão Luau.** `lua_extension(manifest_zip::install)` registra
   `manifest_zip_read`/`manifest_zip_write`, usadas pelo Infra as Code (Settings).
   O motor tem `zip_dir`, mas não o inverso, e a camada Lua não abre um `.zip`.
4. **Gancho `on_message`.** Roda depois de **cada** dispatch da janela
   principal. Ele espelha a sessão da GUI (`api_url`/`api_token`/`connected`,
   escritos no contexto por `handlers/connection.luau`) para a API de agente, e
   assim cobre login, logout e troca de servidor sem conhecer nenhum dos três;
   a escrita em disco só acontece quando algo de fato mudou. É também aqui que a
   API de agente sobe: o `.main()` que a subia saiu. O gancho só roda na instância
   **primária** — a instância única encerra a segunda antes de qualquer dispatch,
   então um segundo lançamento não reescreve o handoff da instância viva — e
   `agent::spawn` é idempotente (um `AtomicBool`), de modo que chamá-lo a cada
   dispatch custa uma troca atômica.
5. **Release.** Injeta-se a fonte de assets embutida: o motor passa a ler
   templates, estilos, scripts e binários de dentro do executável, e nada do
   disco. Em dev o daemon fica com o `DiskAssets` padrão (disco com hot-reload).
6. **Encerramento.** Quando `run` volta, o handoff da API de agente deixa de
   valer: o token morre com o processo, e um arquivo sobrevivente só confundiria
   quem o lesse depois.

### `main.rs`

- `#![cfg_attr(…, windows_subsystem = "windows")]` vale só em release no Windows:
  abrir a GUI não deve mostrar (e manter aberta) uma janela de console atrás
  dela. É ignorado nos outros alvos e em debug, onde o console é útil para logs.
- `mod manifest_zip` é a ponte Lua ↔ Rust do zip do Infra as Code (ler/gravar o
  `.zip` de manifesto), registrada como extensão da camada Luau no builder do
  daemon.
- `assets::locate_and_chdir()` só existe em **debug**: lá os assets são lidos do
  disco, com hot-reload, por caminho relativo ao diretório corrente, então é
  preciso entrar na pasta-base antes de qualquer carga. Em release eles estão
  embutidos no binário (`embedded` + `app::run`); nem o localizador nem o `chdir`
  existem, e o executável roda de qualquer diretório, sozinho.
- A casca customizada (fontes, janela *borderless*, ícone, persistência de
  geometria) é multi-janela sobre `iced::daemon` e vive em `app::run`.

---

### Instalação por `cargo install` e o menu de aplicativos (`desktop.rs`)

`cargo install rustploy-gui` só copia o binário para `~/.cargo/bin`: o cargo não
tem hook de pós-instalação, então o `.desktop` e os ícones (que o `.deb` instala)
não chegam. Para ter o app no menu/dock no Linux, rode **uma vez**:

```
rustploy-gui --install-desktop
```

Grava `rustploy-gui.desktop` e os ícones hicolor em `$XDG_DATA_HOME` (padrão
`~/.local/share`), com `Exec=` apontando para o executável que rodou o comando
(rode de novo se mover o binário). Os arquivos vão embutidos no binário. Nunca é
automático — o app não escreve fora de si sem o usuário pedir.

## 2. Onde estão os assets

Todo template, folha de estilo, ícone e logo de blueprint é referenciado por um
caminho **relativo ao diretório corrente do processo** — tanto do Rust
(`views/styles/app.gss`, `views/app.gvb`, `assets/blueprint-logos/<id>/<logo>`)
quanto de *dentro* dos próprios templates (`import … from="views/service.gvb"`,
`theme "views/styles/theme.json"`, `Svg "assets/icons/…"`).

Em vez de reescrever cada literal, a solução tem duas metades, uma por modo de
compilação.

### 2.1 Debug: achar a pasta-base e entrar nela (`assets.rs`)

`assets::locate_and_chdir` localiza **uma vez**, na partida, o diretório que
contém as árvores `views/` e `assets/` e faz `chdir` para ele. Depois disso todo
caminho relativo resolve, não importa como o app foi lançado: `cargo run` na raiz
do workspace, o `.zip` do Windows (assets ao lado do `.exe`) ou o pacote Debian
(assets em `/usr/share/rustploy`).

A ordem de resolução:

1. `$RUSTPLOY_UI_ASSETS` — sobrescrita explícita;
2. o diretório do próprio executável — layout portátil / `.zip` do Windows;
3. o diretório corrente, se ele já contém os assets — o `cargo run` na raiz do
   workspace em desenvolvimento, **sem** `chdir`. Vem **antes** de
   `SYSTEM_PREFIX` de propósito: um `.deb` instalado em `/usr/share/rustploy` não
   pode esconder a árvore de trabalho durante um `cargo run`;
4. `SYSTEM_PREFIX` (`/usr/share/rustploy`) — o layout do pacote Debian (ver a
   metadata `deb` no `Cargo.toml`).

O teste de validade é a existência de `views/app.gvb` (`MARKER`), o arquivo que
precisa existir em qualquer base válida. A função é *best-effort*: se nenhum
candidato servir, o diretório corrente fica como está e o app mostra um erro de
"stylesheet/template não encontrado", que é o sinal mais claro possível.

### 2.2 Release: tudo dentro do binário (`embedded.rs`)

Em **release** (`cfg(not(debug_assertions))`) toda a árvore de assets que o motor
lê em runtime é embutida no executável com `include_dir!`, e uma
`EmbeddedAssets` é injetada no `GlacierDaemon` (em `app::run`). O binário fica
**100% desacoplado dos arquivos**: pode ser copiado sozinho para qualquer lugar e
rodar, sem as árvores `views/` e `assets/` ao lado e sem o `chdir` de
`assets.rs`. Em debug o módulo nem é compilado.

Os caminhos que chegam são os mesmos que o motor resolve hoje (relativos ao
diretório corrente antes do modo standalone), roteados por prefixo:

| prefixo de runtime | árvore embutida |
|---|---|
| `views/…` | `VIEWS` — `.gvb`, `styles/*.gss`, `styles/theme.json`, `scripts/**/*.luau` (resolvidos por `require`/`<script src>`) |
| `assets/icons/…` | `ICONS` — ícones SVG referenciados por `<svg src="assets/icons/…">` |
| `assets/blueprint-logos/…` | `BLUEPRINTS` — logos dos templates, via o `{logo}` data-driven do catálogo do daemon (`<id>/<arquivo>`) |
| `assets/fonts/…` | `FONTS` — as fontes declaradas com `font(src = …)` no `app(...)` (JetBrains Mono) |

Detalhes que valem saber:

- **Só as imagens dos blueprints** entram. O `build.rs` as espelha em
  `<id>/<arquivo>` e filtra o `docker-compose.yml`/`template.toml` (ver
  [2.3](#23-o-buildrs)).
- `route` normaliza os separadores (`\` vira `/`) e um eventual `./` inicial: as
  chaves do `include_dir` são sempre relativas e com `/`.
- Como o embutido não muda sob o processo, `EmbeddedAssets` devolve `None` em
  `modified` (desliga o hot-reload) e responde `false` à pergunta "há algo para
  vigiar?". Sem esse segundo ponto o daemon manteria o *ticker* de hot-reload
  rodando para sempre — redesenhando a tela inteira a cada tick — sem nunca ter
  trabalho de verdade a fazer.
- `luau_sources` devolve os scripts Luau embutidos como `(caminho, conteúdo)`.
  Serve ao índice de ações da API de agente (`agent::actions`): as ações
  dispatcháveis da UI são as funções globais desses arquivos, e um binário de
  release não tem a árvore `views/` no disco para varrer. Em debug o índice lê do
  disco e nem passa por aqui. O caminho embutido vem relativo a `views/`
  (`scripts/x.luau`); `actions.rs` o normaliza para o mesmo formato do modo debug.
- **Os testes deste módulo só existem em release** (o módulo inteiro é
  `cfg(not(debug_assertions))`): rode com `cargo test --release -p rustploy-gui`.
  Um confere que cada caminho realmente referenciado em runtime resolve na árvore
  embutida — as três convenções de prefixo, texto e binário, e que um caminho
  ausente dá `NotFound`/`exists = false`. O outro é a prova de ponta a ponta,
  *headless*, sem janela e sem `chdir`: o motor carrega o app inteiro só da
  árvore embutida (template, `<link>` de estilo/tema, `<script src>` Luau, a
  cadeia de `require` dos handlers) e renderiza. Se qualquer asset — inclusive um
  módulo `require`d — faltasse, `register_component`/`render` falharia.

### 2.3 O `build.rs`

O build script faz duas coisas.

**1. Prepara os logos dos blueprints** (só imagens) em `$OUT_DIR`; é de lá que o
`embedded.rs` os embute no binário de release.

- *Origem.* Os logos moram em `assets/blueprint-logos/` (saíram do crate
  `rustploy-shared`, que não os carrega mais); o nome de cada um vem do catálogo
  do shared (`templates/logos.txt`). Só as extensões de imagem entram (`LOGO_EXTS`);
  o resto da pasta — `docker-compose.yml`, `template.toml`, `.md` — é do daemon e a
  GUI nunca o lê.
- *Por que reduzir.* Os logos raster originais têm ~512×512 e aparecem a ~30px
  (`template_row.gvb`). Sem redução, a GPU faria um *downscale* de ~17× por
  quadro (serrilhado) e o binário carregaria ~12 MB de logo. Por isso os raster
  são reduzidos com **Lanczos3** para no máximo `LOGO_MAX_DIM` = **96px** na
  maior dimensão, preservando a proporção, e re-codificados como PNG. 96px cobre
  telas HiDPI (até ~3×) e ainda corta os originais em ordens de grandeza. O
  processo só **reduz**: imagem que já é menor, e todo vetor, passa intacta — não
  se borra o que já é pequeno.
- *Vetor e formatos raros.* SVG é copiado intacto (nítido em qualquer tamanho). O
  mesmo vale para `.ico`/`.avif`, que o crate `image` não cobre: continuam sendo
  logos válidos e caem no ramo de cópia, sem passar pelo resize. `is_logo` decide
  o que entra no staging; `is_raster` é o subconjunto que o `image` decodifica (as
  features habilitadas no `Cargo.toml`).
- *Degradação.* `stage_raster` nunca derruba o build: se não consegue decodificar
  (ou a imagem já é pequena), copia os bytes originais. `downscale_png` devolve
  `None` nesses casos — re-codificar não valeria o custo e o risco de mexer no que
  já está bom.
- *Nomes.* O nome do arquivo no staging tem de ser **idêntico** ao original: o
  daemon devolve o caminho `<id>/<arquivo>` e o `EmbeddedAssets` o serve por essa
  chave. Re-codificar um raster para PNG mantendo, digamos, um nome `.jpg` é
  inofensivo — o `iced`/`image` decodifica por conteúdo (*magic bytes*), não pela
  extensão.
- *Staging.* A pasta é limpa a cada build (para não reter logos de blueprints
  removidos) e o build é refeito quando a árvore de blueprints muda
  (`cargo:rerun-if-changed`).

**2. Embute no `.exe` do Windows** o ícone da aplicação, o manifesto e os
metadados de versão. Build scripts rodam no *host*, então o **alvo** é detectado
pela variável `CARGO_CFG_TARGET_OS` que o Cargo define — `cfg!(windows)` refletiria
o host e ficaria falso durante o cross build Linux→Windows. O recurso é compilado
pela ferramenta RC que o `embed-resource` achar; no cross build é o `llvm-rc`
(o `assets/rustploy.rc` não tem `#include`, então nenhum header do Windows SDK é
necessário). As macros do `VERSIONINFO` são derivadas de `CARGO_PKG_VERSION`
(ex.: `"0.1.0"` → vírgulas `0,1,0,0` e string `"0.1.0"`) e passadas como defines
ao RC, de modo que a versão do `.exe` nunca sai do lugar em relação ao
`Cargo.toml`. O `llvm-rc` recebe os defines via macros do `embed-resource`, e a
string precisa de aspas escapadas para chegar como literal entre aspas no `.rc`.

---

## 3. A ponte do zip do Infra as Code

`manifest_zip.rs` existe porque o motor glacier-ui traz `zip_dir` (compacta um
diretório) mas **não** o inverso, e a camada Lua não tem como abrir um `.zip`. O
Infra as Code precisa dos dois sentidos:

- **exportar** grava um `.zip` com exatamente dois arquivos, `rustploy.yml` e
  `rustploy.vars.toml`, na raiz — sem diretório de staging: os dois são escritos
  direto no arquivo final (`write_manifest_zip`);
- **importar** lê um `.zip` e exige **exatamente** um `*.yml`/`*.yaml` e um
  `*.toml`, na raiz, e mais nada (`read_manifest_zip`). Diretórios e qualquer
  subpasta contam como "extra" e invalidam o arquivo. O retorno é `(yaml, toml)`
  ou uma mensagem de erro pronta para exibir.

As duas funções entram como globais de todo `<script>` via
`GlacierDaemon::lua_extension` (`app::run`), implementadas com o mesmo crate `zip`
que o glacier já usa — então o Cargo deduplica e não há uma segunda cópia no
binário. `install` registra:

- `manifest_zip_write(zip_path, yaml, toml) -> (ok: boolean, err: string?)`
- `manifest_zip_read(zip_path) -> { ok: boolean, yaml: string?, toml: string?, error: string? }`

---

## 4. A API de agente

O módulo `src/agent/` é um servidor HTTP local que empresta a sessão desta janela
a quem opera por fora.

### 4.1 O problema

O daemon do rustploy já expõe tudo por HTTP (`POST /api/rpc`): dá para conduzir
um deploy inteiro por fora da GUI. O que faltava era o **caminho até lá**. Quem
quer operar um rustploy remoto por agente precisa da URL pública do daemon e do
bearer token dele em mãos, na máquina do agente, fora do lugar onde essas
credenciais já vivem — que é este app.

### 4.2 O desenho: a direção se inverte

O app já está logado no daemon remoto (o usuário digitou URL + token na tela de
login). O módulo sobe um servidor HTTP em **loopback** que aceita comandos de um
agente na mesma máquina e os encaminha ao daemon usando a sessão da GUI. O agente
nunca vê o token do daemon, não precisa saber o endereço do servidor remoto, e o
que ele alcança é exatamente o que a janela alcança: trocar de servidor na GUI
troca o alvo do agente junto.

```text
  agente local ──HTTP──> 127.0.0.1:9800 (este módulo) ──HTTPS──> rustploy remoto
                             ▲                                    (POST /api/rpc)
                             └── sessão (url + token) lida do contexto da GUI
```

### 4.3 Descoberta: o arquivo de handoff (`handoff.rs`)

Ao subir, o app grava um JSON (`agent-api.json`) com a URL local, o token de acesso
e o PID. É o **único passo de descoberta**: o agente lê o arquivo e já sabe tudo
para a primeira requisição; `GET /agent/schema` conta o resto.

- **Onde.** No data dir do usuário — o mesmo que a GUI já usa para o `storage` do
  Luau e a geometria da janela (`shared::fallback_data_dir()`) —, então não
  inventa diretório novo nem depende do diretório corrente.
- **É um segredo.** Quem lê o token opera o rustploy remoto inteiro. O arquivo
  nasce `0600` no unix. No Windows, onde não há modo POSIX, o diretório de dados
  do usuário é a fronteira — o mesmo nível de proteção do resto da persistência
  local do app.
- **Token efêmero.** `generate_token` produz 32 bytes de CSPRNG em hex, **novo a
  cada boot** de propósito: não há motivo para ele sobreviver ao processo que o
  serve, e assim um handoff velho esquecido no disco não vale nada.
- **O campo `remote`.** É o daemon ao qual a janela está conectada agora, ou
  `None` na tela de login. Expor isso poupa ao agente uma requisição só para
  descobrir que ainda não há sessão.
- **O campo `note`.** O arquivo pode ter sido escrito por um processo que morreu
  sem limpar; por isso o leitor deve conferir o `pid` (ou simplesmente tentar
  `/agent/health`) antes de concluir que a API está no ar.
- **Escrita atômica.** Grava-se num arquivo temporário (`.json.tmp`) e faz-se
  `rename`. Sem isso, um agente que lesse exatamente durante a regravação — que
  acontece a cada login/logout — poderia pegar um JSON truncado.
- **Remoção.** `remove` apaga o handoff ao encerrar o servidor. Um handoff órfão
  não é perigoso (o token morre com o processo), mas confunde quem for ler depois.

### 4.4 Limites deliberados

- **Só loopback.** O bind é sempre `127.0.0.1`; não há opção de expor na rede.
  Isto é uma ponte para processos da mesma máquina, não um segundo daemon.
- **Token mesmo assim.** Loopback não é fronteira de segurança num desktop
  multiusuário, e o que está do outro lado da ponte derruba produção. O arquivo de
  handoff nasce `0600`.
- **Sem escopo.** Quem tem o token do handoff tem o mesmo poder que a janela — o
  poder do bearer do daemon, hoje sem escopo nenhum. Enquanto o daemon não tiver
  tokens com escopo (ver a nota de segurança em
  `docs/plano-erro-de-deploy-invisivel.md`), esta ponte não tem como inventar um.

### 4.5 Subida, endereço e ciclo de vida (`agent/mod.rs`)

- **Thread própria, runtime próprio.** `spawn` sobe o servidor numa thread
  separada com um runtime tokio `current_thread` próprio. É deliberado: o loop do
  `iced` é dono da thread principal e o executor dele não é lugar onde se possa
  `tokio::spawn` antes de `run()`. Uma thread assim custa quase nada e mantém a API
  viva independente do que a UI esteja fazendo — inclusive com a janela fechada,
  quando o app fica recolhido na bandeja (o motor *headless* continua vivo e a
  sessão junto).
- **Não devolve erro.** Falhar ali não pode impedir o app de abrir; qualquer
  problema vira aviso no stderr e a GUI segue como sempre foi.
- **Idempotência (`STARTED`).** O `.on_message()` do `GlacierDaemon`, de onde
  `spawn` é chamado, roda a **cada** dispatch da principal. Uma segunda thread
  tentaria *bind* na mesma porta e reescreveria o handoff com um token novo —
  invalidando o que o agente já tem. O `AtomicBool` também responde "esta execução
  chegou a subir o servidor?".
- **`cleanup` só de quem subiu.** Apaga o handoff ao encerrar (o token é desta
  execução e não vale depois dela), mas só se `STARTED` está ligado. Sem esse
  guard, um segundo lançamento do app — que o `single_instance` encerra em silêncio
  sem abrir janela — apagaria o arquivo da instância que continua no ar, e o
  agente perderia o caminho de volta sem nada ter acontecido de fato.
- **Endereço.** `DEFAULT_ADDR` é `127.0.0.1:9800`: porta alta e fixa para o
  handoff ser previsível. Se estiver ocupada, `bind` cai para uma porta efêmera no
  mesmo IP (outro app, ou uma instância anterior ainda encerrando) e o handoff diz
  qual foi — por isso o agente lê o arquivo em vez de assumir a porta.
- **Variável de ambiente `RUSTPLOY_AGENT_API`.** `off` desliga a API;
  `127.0.0.1:9910` troca o endereço. A regra de resolução (`resolve_addr`) é
  separada da leitura da variável (`configured_addr`) para poder ser testada. Um
  valor **não-loopback é recusado** e cai no padrão: o desenho todo supõe que só
  processos da mesma máquina alcançam esta porta, e uma variável de ambiente num
  `.desktop` não é lugar de furar isso sem querer. `::1` também é loopback e é
  aceito.

### 4.6 A sessão (`session.rs`)

A thread da UI **escreve** a sessão; a thread do servidor **lê**, a cada
requisição.

Quem escreve é o gancho `on_message` do `GlacierDaemon`: toda mensagem
despachada na janela principal passa por lá com o motor no estado resultante, e o
contexto do motor é onde a camada Luau guarda `api_url`/`api_token`/`connected`
ao conectar (`handlers/connection.luau`). Não há um "evento de login" no glacier
para assinar, e nem faz falta: o `on_message` roda depois de cada dispatch, então
observar o contexto ali é equivalente — e cobre de graça o logout (que apaga o
contexto inteiro) e a troca de servidor, sem que o módulo conheça nenhum dos dois
fluxos.

- **`Session`** é a conexão viva com um daemon, do ponto de vista da API:
  `base_url` sem barra final (`https://rustploy.exemplo.com`) e `token`, que é
  `None` quando o daemon roda sem token.
- **O espelho do contexto.** Além da sessão, guarda-se uma **cópia** do contexto
  do motor, refeita a cada dispatch. Ela existe porque o contexto só é legível de
  dentro do gancho, na thread do iced, e a thread da API precisa dele para
  responder "em que tela a GUI está?", "qual serviço está selecionado?", "qual
  foi o erro do último login?". Copiar em vez de referenciar permite que as duas
  threads sigam sem trava compartilhada. O custo é um clone do mapa por dispatch
  (~120 chaves, algumas com JSON de dezenas de KB), a cada 2s no ritmo do snapshot
  do SSE; numa aplicação de desktop isso é ruído, e a alternativa (comparar campo
  a campo para copiar só o que mudou) custaria a mesma ordem de trabalho.
- **`sync_from_context`** relê o contexto, atualiza o espelho (sempre) e a sessão
  (se algo mudou). Devolve `true` quando a **sessão** mudou — o chamador usa isso
  para regravar o handoff sem escrever em disco a cada tick do snapshot do SSE
  (que dispara um dispatch a cada 2s e, portanto, uma chamada aqui).
- **O gate `connected`.** `from_context` só devolve sessão quando a camada Luau
  marcou `connected`, o que acontece quando o `DaemonStatus` de validação passou
  (`handlers/connection.luau::connect`). Sem isso a API aceitaria requisições
  enquanto a tela de login ainda mostra credenciais que o usuário está digitando:
  o usuário já digitou a URL, mas o *Connect* não validou nada, e isso a API de
  agente não pode usar.
- **`SharedSession`** é o handle compartilhado. Sessão `None` significa que a
  janela não está conectada a daemon nenhum (tela de login, ou logout); aí a API
  responde **503** dizendo exatamente isso, em vez de falhar de um jeito que
  pareça bug de rede.

### 4.7 O cliente do daemon remoto (`client.rs`)

- **hyper cru**, via o `Client` legado do `hyper-util`, e não `reqwest`: é a mesma
  regra do daemon — um cliente HTTP só no workspace, e ele é o hyper. O que se
  precisa é pequeno e conhecido: um `POST` de JSON com bearer.
- **Sem gzip, de propósito.** O daemon comprime a resposta do `/api/rpc` **quando
  o cliente pede** (`Accept-Encoding: gzip`). Este cliente não pede: o ganho é de
  link remoto lento e o custo seria carregar um descompressor aqui para nada.
- **Provider de cripto explícito.** O glacier-ui já instala o provider `ring` como
  padrão do processo, mas depender dessa ordem seria frágil; passa-se o provider
  explicitamente (`rustls::crypto::ring::default_provider`), e assim tanto faz quem
  instalou o quê antes. `new` só falharia se o provider não pudesse ser
  configurado, o que na prática não acontece.
- **`https_or_http`, não `https_only`.** Um rustploy de laboratório na rede local
  roda em HTTP puro, e é a GUI que decide isso ao conectar — não cabe a esta ponte
  recusar o que a janela aceitou.
- **`TIMEOUT` de 60 s por requisição.** Um `Command` pesado (o `Snapshot` faz
  várias idas ao Docker) leva segundos; o que o limite protege é o daemon
  inalcançável, para o agente receber um erro em vez de ficar pendurado.
- **`RemoteError`** já separa o que o agente precisa distinguir: problema de
  **transporte** (`Transport`: não chegou lá — DNS, TLS, conexão recusada,
  timeout) × resposta de **erro do próprio daemon** (`Status`: chegou e ele
  recusou — 401 de token vencido, 404…) × **`Decode`** (a resposta chegou mas não
  é o JSON esperado).
- **`rpc`** executa um `Command` com `POST /api/rpc` e devolve a `Response` como
  JSON cru. Quem chama decide o que fazer com `{"Err":{…}}`, que é resposta 200 do
  ponto de vista HTTP.
- **`upload_archive`** sobe um zip para `POST /api/services/<id>/archive`. Merece
  método próprio porque **não é um `Command`**: é rota HTTP com corpo binário, e
  um agente que só leu `protocol.rs` não descobre que ela existe — era o último
  caminho do fluxo "criar serviço Archive → deployar" que a ponte não alcançava.
  O nome original do arquivo vai em `X-Rustploy-Filename` (o daemon o lê dali; não
  há multipart) e é o que aparece depois na aba do serviço. O timeout é de **600 s**,
  sem o curto do `rpc`: um zip de projeto leva bem mais que uma chamada de
  protocolo, e o custo é de rede, não de espera por um daemon travado.
- **Ler uma `Response`.** O protocolo é *serde externally-tagged*, então "que
  resposta é essa?" é sempre a única chave do objeto (`{"Projects":[…]}` →
  `"Projects"`) — **menos** quando a variante não tem campos, que o serde
  serializa como string pura (`"Ok"`). Esquecer o segundo caso é o erro clássico de
  quem escreve cliente para esta API. `response_kind`, `response_payload` (o
  conteúdo de uma variante com campos, ou `None` para a unitária) e
  `response_error` (`Some((code, message))` quando é `Response::Err`) encapsulam
  isso.

### 4.8 O servidor e o roteamento (`routes.rs`)

Servidor **e** cliente são hyper: o daemon já serve a própria API assim, e não faz
sentido carregar um segundo framework HTTP num app de desktop só para servir sete
rotas em loopback. Todas as rotas devolvem JSON, **inclusive os erros** — um agente
não deveria precisar distinguir "corpo de erro em texto" de "corpo de resposta em
JSON" no meio de um fluxo. O formato de erro é sempre
`{"error": {"code": "...", "message": "..."}}` (`ApiFail`).

**Constantes.** `MAX_BODY` = 32 MiB: generoso porque um `ManifestApply` ou um
`ServiceUpdate` de fonte Compose carrega YAML de verdade (dezenas de KB) e
mesquinho o bastante para um cliente maluco não comer a RAM do app.
`POLL_INTERVAL` = 2 s é o intervalo com que o `wait` de um deploy reconsulta o
daemon. `MAX_WAIT` = 3600 s é o teto do `timeout_s` aceito em
`POST /agent/deploys`.

**Estado (`Ctx`).** Compartilhado por todas as conexões: o canal `ui` para injetar
ações no motor (glacier-ui 0.58.6+) — sem ele, login e navegação só por clique, é o
que torna a GUI dirigível —, o `token` exigido no `Authorization` (o **desta** API,
não o do daemon) e a sessão.

**Códigos de erro.**
- `ApiFail::desconectado` → **503**, com uma mensagem que diz o que fazer, porque é
  o erro que um agente mais vai encontrar: o app abriu, mas ninguém logou ainda.
- Falha de transporte para o daemon → **502**: quem falhou foi o salto daqui para o
  daemon, não o pedido do agente, e a distinção importa para ele saber se adianta
  repetir. Pelo mesmo motivo, um `connect` recusado pelo daemon (token errado,
  host inalcançável) é 502.
- `Response::Err` do daemon vira **400** com o código e a mensagem dele — não um
  200 que o agente teria de inspecionar para descobrir que falhou.

**Servir.** `serve` sobe o listener e atende até o processo morrer. Se não
conseguir gravar o handoff, a API sobe do mesmo jeito mas ninguém a descobre — vale
um aviso alto, não um encerramento. `accept_loop` é separado de `serve` para os
testes exercitarem o roteamento sem gerar token nem escrever o handoff no data dir
do usuário; um cliente que desiste no meio é rotina e nada se reporta. `bind` tenta
o endereço pedido e cai para uma porta efêmera (ver 4.5).

**Acompanhar a sessão (`watch_session`).** Mantém `remote_url`/`connected` do
handoff em dia. A sessão muda na thread da UI (login, logout, troca de servidor) e
o handoff é escrito aqui, na thread da API: um *poll* curto é o acoplamento mais
barato entre as duas, e não há nada a perder em detectar a mudança 2 s depois.

**Roteamento (`handle`).** Liveness sem token, depois o gate de token, as rotas de
dados (repassadas ao daemon) e as de controle da janela.

- `GET /agent/health` fica **fora** do gate: serve para o agente saber se o app
  está no ar antes de ter lido o handoff, e não revela nada — nem o endereço do
  daemon remoto, que é dado do usuário.
- `check_token` compara o bearer da API de agente em **tempo constante**: o token é
  curto e local, mas comparar segredo com `==` é o tipo de detalhe que não vale
  economizar.

**Rotas de dados.**

- `GET /agent/status` — a janela, o daemon e a fila de deploys num lugar só.
- `GET /agent/services` — índice achatado projeto→serviço. Existe porque o
  caminho cru para "qual é o id do serviço chamado X?" é `ProjectList` seguido de
  um `ServiceList` por projeto, e a alternativa de uma chamada só (`Snapshot`)
  devolve o dashboard inteiro — Docker, jobs, registry, métricas. Aqui vai só o que
  identifica um serviço. (`snapshot` desembrulha as duas camadas de
  `Response::Snapshot(String)`, que é JSON **dentro** de uma string.)
- `GET /agent/deploys` — últimos deploys com o desfecho já resolvido.
- `POST /agent/deploys` — dispara um deploy e, com `wait`, só responde quando ele
  terminou. **É a rota que motivou este módulo.** Sem ela, "o deploy funcionou?"
  custa ao agente um `DeployStart`, um laço de `DeployHistory` filtrando por id, um
  `GetBuildLogs` inteiro e o conhecimento de que a causa da falha mora no
  `states_log` e não no estado — conhecimento que ninguém tem na primeira vez.
  - `resolve_service` aceita o `service_id` direto **ou o nome** do serviço: o nome
    é o que o usuário diz ("sobe o stand-imob"), o ULID não. O nome é único por
    projeto, não globalmente: havendo ambiguidade, a rota não escolhe por conta
    própria e responde erro.
  - `wait_for_outcome` faz *poll* até um estado terminal (ou o prazo acabar). É
    poll e não SSE porque manter uma conexão de eventos aberta significaria
    consumir e reemitir o *firehose* do daemon só para observar um id; o deploy
    mais rápido leva segundos, e 2 s de granularidade não custam nada. Se expirar,
    devolve o **último estado conhecido** em vez de um erro seco — "ainda em
    `BuildingImage` depois de 15 min" é informação útil, e o agente decide se espera
    mais ou investiga.
- `GET /agent/deploys/<id>/logs` — build log com cursor. O daemon só sabe devolver
  o log inteiro (`GetBuildLogs` não tem cursor), e um build de verdade passa de mil
  linhas. A fatia acontece aqui: o tráfego caro é o desta ponte para o agente, não o
  da ponte para o daemon na mesma sessão. `after` é o índice da última linha já
  vista — a tabela do daemon só recebe *append* e é ordenada por timestamp, então o
  índice é um cursor estável. `build_log_lines` extrai o texto de cada linha, na
  ordem de gravação.
- `POST /agent/rpc` — qualquer `Command` do protocolo, sem tradução. É a válvula de
  escape que mantém as rotas de conveniência honestas: elas existem para os
  caminhos frequentes, não para virarem a única porta. Tudo o que a GUI faz, um
  agente faz por aqui. O passthrough encaminha o comando cru e devolve a `Response`
  *verbatim*.
- `GET /agent/ingress` — a tabela de rotas viva do proxy reverso. Responde à
  pergunta de um domínio que devolve 502: existe rota para ele, e para qual
  `ip:porta` ela aponta? Um `backends` vazio, ou apontando para a porta errada, é a
  resposta.
- `POST /agent/ingress/reconcile` — recalcula as rotas a partir dos containers que
  existem de fato, sem redeployar, e devolve a tabela já corrigida. O corpo é
  opcional (`{"service_id":"svc_…"}`); corpo vazio é válido e reconcilia tudo.
- `GET /agent/servers` — os servidores já usados nesta máquina (ver 4.10).
- `POST /agent/services/<id>/archive` — sobe um zip local para o serviço. Recebe o
  **caminho** do arquivo, não os bytes: quem chama está na mesma máquina (a ponte é
  loopback), e mandar dezenas de MB em base64 por HTTP para a ponte remontar seria
  custo puro. O corpo é `{"path": "/caminho/app.zip"}`.

**Controle da janela (ver 4.9).**
- `POST /agent/connect` — entra na sessão **pela própria tela de login**. Era o
  último ponto cego de verdade: sem isso a ponte só servia depois que um humano
  tivesse clicado *Connect*, e um agente numa máquina sem ninguém na frente ficava
  preso no 503. O `token` é opcional: omitido, a ponte busca o salvo para aquela
  URL (`servers.rs`), de modo que o segredo nunca precisa atravessar a rede.
- `POST /agent/disconnect` — sai da sessão. Não espera: `disconnect()` na Luau é
  síncrono e não tem como falhar, e a consequência (a sessão sumindo) fica visível
  em `GET /agent/ui`.
- `GET /agent/ui` — o que a janela está mostrando agora.
- `POST /agent/ui/action` — dispara qualquer ação da UI pelo nome. É a
  **chave-mestra**: todo botão, aba e formulário da GUI é uma função Luau global
  (`views/scripts/handlers/*.luau`), e este endpoint chama qualquer uma pelo mesmo
  caminho de um clique. Cobre as ~154 ações existentes e as futuras sem uma lista
  aqui, que envelheceria na primeira tela nova. Com `value` o efeito é o de um
  `onChange` de campo; sem `value`, o de um clique de botão — a mesma distinção que
  os templates fazem, então a ação recebe exatamente o que receberia da UI. A
  resposta é **202**, não 200: a ação foi **entregue** ao motor e o efeito dela é
  assíncrono (várias fazem RPC); prometer "deu certo" ali seria mentira.
- `POST /agent/ui/context` — escreve chaves no contexto da janela. É o par de
  baixo nível do `ui/action`: preenche campo de formulário, marca seleção, muda de
  aba; útil quando a ação que se quer disparar espera algo já escrito no contexto.
  Número e booleano viram texto, porque o contexto do motor é sempre chave→string
  e recusar por tipo seria pedantismo inútil.

**Moldando as respostas do daemon.** O objetivo é devolver ao agente o que ele
precisa, não o que o daemon tem.

- `outcome_ok` resolve o desfecho de um deploy: `true` = no ar, `false` = falhou,
  `null` = ainda não decidiu. Só `Live` e `Failed` decidem. `Stopped` e `Pruning`
  são terminais **sem serem desfecho**: o primeiro é o serviço derrubado de
  propósito, o segundo é um deployment antigo que outro mais novo substituiu.
  Chamar qualquer um dos dois de "falha" seria mentira.
- `failure_reason` tira a causa da falha do `states_log`, que é onde o daemon a
  grava: a transição que **entrou** em `RollingBack` carrega a mensagem do step que
  quebrou (o texto do `docker build`, o healthcheck que não passou…). Mensagens de
  outras transições são ignoradas de propósito — `Pruning` traz "superseded by newer
  deployment", que não é erro nenhum.
- `compact_summary`/`compact_deployment` reduzem `DeploymentSummary`/`Deployment`
  ao que interessa a quem só quer saber como acabou.
- `service_index` achata o snapshot no índice que um agente precisa para agir: id,
  nome, projeto, status e de onde a imagem vem. `status_label` transforma o
  `ServiceStatus` (externally-tagged, só a variante `Error` tem campo) em
  `"Running"` ou `"Error: <causa>"`; depois da correção do log de deploy essa causa
  é o motivo real da falha, não mais a string fixa "deploy failed". `source_label`
  achata o `ServiceSource` no que identifica a origem, sem arrastar o
  `compose.content` inteiro (dezenas de KB) para dentro de uma listagem — e a
  credencial de um repositório git nunca vaza para uma listagem.

**Parâmetros da query.** `num_param` e `str_param` não fazem *percent-decoding*:
nenhum parâmetro numérico precisa, e os campos de texto livre (nome de serviço)
vão no corpo, justamente para não depender disso. Os únicos usos textuais são
listas de nomes de chave (`keys=screen,view`) e flags (`all=1`).

### 4.9 Controlando a própria janela (`ui.rs`)

A ponte de `routes.rs` encaminha `Command`s ao daemon remoto, e isso cobre tudo o
que é **dado**. Sobrava o que é **janela**: entrar na sessão, sair dela, navegar
entre telas, abrir uma janela-filha, marcar um serviço como selecionado. Nada disso
é um `Command` — mora na camada Luau, e só era disparado por um evento do loop do
iced.

O canal `external` do glacier-ui (0.58.6+) fecha a lacuna: a thread do servidor
injeta no motor da janela principal o **mesmo** tipo de mensagem que um clique
produz. Como o vocabulário é o dos templates, toda ação declarada na UI já é
alcançável — as 154 de hoje e as que vierem, sem lista para manter em dia. O par de
leitura é o espelho do contexto em `session.rs`: **escrever é pelo canal, ler é
pelo espelho**.

- **`connect`.** Preenche o formulário de login e aciona o botão *Connect*,
  exatamente como um usuário faria, e espera o desfecho. Preencher e clicar (em vez
  de só escrever a sessão na ponte) é deliberado: assim a GUI **acompanha**. O
  `connect()` da Luau valida com um `DaemonStatus`, abre o SSE, carrega as
  configurações do daemon, troca para a tela `shell` e salva o servidor na lista de
  conhecidos; uma sessão escrita só do lado da ponte teria o agente operando um
  servidor que a janela do usuário nem sabe que existe. Limpa-se o erro anterior
  antes, para não confundir uma falha velha com esta. O motivo de uma recusa vem de
  `error` (falha de transporte/401) ou de `erro_url` (URL malformada) — o
  `connect()` escreve ali e volta sem conectar. `TIMEOUT_CONNECT` (30 s) é o quanto
  se espera: ele faz um `DaemonStatus` de validação contra o daemon remoto, então o
  teto é de rede, não de UI. `POLL` (100 ms) é de quanto em quanto tempo se
  reconsulta o espelho.
- **`disconnect`.** O `disconnect()` da Luau fecha o SSE, apaga o contexto inteiro e
  volta para a tela de login; a ponte perde a sessão junto, por construção.
- **`state`.** O estado da janela que interessa a quem a dirige de fora. É
  **curado**, não o contexto cru: o contexto tem ~120 chaves, várias com o JSON
  inteiro de uma tela (todos os serviços, todas as imagens Docker), e devolver tudo
  por padrão faria a resposta custar mais que a informação. Para as demais há o
  parâmetro `keys`. `screen` é a janela toda (`login` | `shell`); `view` é a seção
  da sidebar.
- **`keys` e `all_keys`.** Chaves avulsas do contexto, para o que o resumo curado
  não cobre; `all_keys` despeja todas, só sob pedido explícito (`?all=1`), com os
  segredos redigidos. Uma chave pedida e inexistente volta com `null`: isso diz
  "perguntei e não tem"; omiti-la deixaria o chamador sem saber se errou o nome.
- **`REDIGIDAS`** são as chaves que **nunca** saem pela API: `api_token` (o bearer do
  daemon remoto — o desenho inteiro da ponte é o agente operar sem nunca vê-lo) e
  `token` (o campo do formulário de login, que carrega o mesmo segredo enquanto o
  usuário digita). O resumo curado nunca carrega o bearer do daemon.

### 4.10 Os servidores conhecidos (`servers.rs`)

A camada Luau salva todo login bem-sucedido no `storage` do glacier-ui — um JSON no
data dir do usuário (`handlers/connection.luau`, `remember_server`). É de lá que o
formulário de login nasce preenchido. Para a API de agente isso resolve um problema
concreto: **conectar sem precisar do token**. O agente pede a URL, a ponte encontra o
token salvo e preenche o formulário — o segredo nunca atravessa a rede em nenhum
sentido, nem na ida (o agente não o manda) nem na volta (a listagem só diz se
existe).

- `list` lê a lista salva. Fica vazia quando o arquivo não existe (nenhum login
  ainda), está corrompido ou mudou de formato — nunca é erro fatal: a consequência é
  só o agente ter de informar o token, que é o caminho normal mesmo.
- `token_for` compara a URL de forma tolerante à barra final — a mesma normalização
  que a sessão faz — para `https://x.dev/` e `https://x.dev` não virarem servidores
  diferentes.
- `as_json` é a listagem que sai pela API: URL e se há token guardado, **nunca o
  token**.

### 4.11 O índice de ações (`actions.rs`)

`POST /agent/ui/action` dispara qualquer ação da GUI pelo nome. Mas uma chave-mestra
sem chaveiro só serve a quem já sabe os nomes, e saber os nomes exigia ter o
repositório aberto (`grep "^function " views/scripts/handlers/*.luau`) — o que
deixaria a rota mais poderosa da ponte fora do alcance de um agente que só tem a
máquina do usuário e o arquivo de handoff.

Este módulo devolve a lista **em runtime**, lida da mesma árvore de scripts que o
motor executa: do disco em debug, da árvore embutida no binário em release — nunca
de uma lista escrita à mão, que envelheceria na primeira tela nova.

- **O que conta como ação:** uma função global do Luau, escrita na **coluna 1**
  (`function nome(...)`), que é exatamente o que os templates referenciam em
  `on_click`/`onChange`/`on_submit`. `local function` (auxiliar do módulo), métodos
  (`function M:algo`) e um `function` indentado (dentro de outro bloco) ficam de
  fora, e o teste correspondente existe porque anunciar auxiliares daria ao agente
  nomes que respondem 202 e não fazem nada.
- **Debug × release.** Em debug os assets são lidos do disco pelo motor (com
  hot-reload) e o diretório corrente já é a base dos assets
  (`assets::locate_and_chdir`), então a varredura segue o mesmo caminho. Em release
  não há árvore no disco: vem do binário (`embedded::luau_sources`).
- A lista sai **ordenada por nome**: é para ser lida e procurada, não para preservar
  a ordem de declaração de cada arquivo. `Acao.origem` é o arquivo relativo a
  `views/scripts/`, ex.: `handlers/services.luau`.

### 4.12 O catálogo de descoberta (`catalog.rs`)

`GET /agent/schema` é o documento de descoberta. Sem ele, montar a primeira chamada
exige ler `src/protocol.rs` do rustploy-shared e `models.rs` e deduzir a codificação
serde na mão — viável para quem tem o repositório aberto, inviável para um agente
diante de um daemon remoto. É o atrito mais caro relatado em
`docs/plano-erro-de-deploy-invisivel.md` (2.1).

**O catálogo é curado, não gerado.** As rotas desta API estão descritas por inteiro;
a lista de `Command` cobre o que aparece em runbook, não as ~90 variantes do enum. A
fonte da verdade continua sendo `protocol.rs`, e o passthrough (`POST /agent/rpc`)
aceita qualquer comando, esteja ele listado ou não — inclusive os adicionados depois
deste arquivo.

Por ser escrito à mão, um `json!` malformado só apareceria em runtime; os testes
garantem que o catálogo ao menos existe e cita cada rota que o roteador realmente
serve, e que cada exemplo de comando é JSON de verdade — copiar um exemplo quebrado
é pior do que não ter exemplo.

---

## 5. Os testes e o que cada um trava

### 5.1 Testes da API de agente

São testes unitários pequenos, cada um ligado a uma decisão de desenho:

- **`resolve_addr`** — `::1` também é loopback; e o que importa de verdade: pedir
  *bind* público **não** abre a ponte para a rede, cai no padrão de loopback.
- **`session`** — repetir o mesmo contexto não pode contar como mudança (o tick do
  SSE dispara um dispatch a cada 2 s; senão o handoff seria reescrito em disco o
  tempo todo); logout apaga o contexto inteiro e a sessão cai junto (impede o agente
  de continuar operando um servidor do qual o usuário acabou de sair); trocar de
  servidor na GUI troca o alvo do agente sem ele saber.
- **`ui`** — o token do daemon é o segredo que a ponte existe para **não** expor:
  nem por chave avulsa, nem no despejo completo.
- **`client`** — `Response::Ok` vira a string nua `"Ok"`, não um objeto: o caso que
  quebra cliente ingênuo.
- **`routes` (unitários)** — o desfecho: só `Live` e `Failed` decidem, e um
  deployment substituído por outro mais novo (`Pruning`) não é falha; e a
  **regressão que o módulo inteiro serve**: a causa da falha sai do `states_log` e
  não se deixa confundir pela mensagem de "superseded".
- **`actions`** — auxiliares de módulo e métodos não são dispatcháveis.

**O teste ponta a ponta da ponte** (`routes::tests`) é o que separa "compila" de
"funciona". Ele monta um daemon rustploy **de mentira** de um lado, a API de agente
no meio e um cliente HTTP cru do outro (hyper direto sobre TCP, sem TLS — tudo é
loopback), e exercita o roteamento, o gate de token, o gate de sessão e — o
principal — o `POST /agent/deploys` com `wait`.

- O daemon de mentira responde o subconjunto do protocolo que as rotas usam. Uma
  variante unitária chega como string nua e a com campos como objeto de uma chave,
  igualzinho ao daemon de verdade. `HISTORY_HITS` conta quantas vezes ele já
  respondeu um `DeployHistory`: o deploy só "termina" na **segunda** consulta, para
  o teste passar mesmo pelo caminho de espera em vez de acertar terminal de primeira
  (e a asserção `>= 2` prova que passou por ele — o primeiro `DeployHistory` ainda
  estava em `BuildingImage`).
- O canal `external` dos testes não tem motor do outro lado: as mensagens caem num
  receptor que ninguém drena, o que é exatamente o certo aqui — os testes
  exercitam o HTTP e a conversa com o daemon, não o efeito na janela.
- Com o token certo, o que barra agora é a falta de sessão — o que prova que a
  requisição passou do gate de token.
- **O caso do plano, ponta a ponta:** dispara o deploy, espera, e a resposta já traz
  `ok=false` com a causa que o Docker deu, sem o agente precisar saber que ela mora
  no `states_log`. O serviço é pedido por **nome**, não por id (o daemon de mentira
  resolve via `Snapshot`), e `log_tail` traz só o fim, com o cursor dizendo onde
  continuar.
- O passthrough encaminha o comando cru e devolve a `Response` *verbatim*;
  `Response::Err` vira 400 com código e mensagem; daemon inalcançável (porta
  fechada de propósito) é **502**, não 500 — a distinção diz ao agente se adianta
  repetir. Credencial de repositório não vaza para uma listagem de serviços.

### 5.2 Os testes de `fmt` em Luau (`tests/fmt_*.rs`)

Rodam módulos Luau de formatação no motor de verdade, com uma **fixture** — uma tela
mínima que carrega o módulo e exibe o resultado. A fixture mora fora da árvore de
scripts do app (para não virar script do app), então o `require("fmt/…")` dela
precisa de uma raiz extra, adicionada por variável de ambiente dentro de um bloco
`unsafe`.

- **`fmt_service_detail`** (`compose_host` e `internal_url`) existe desde o rename
  de serviço: o hostname interno de um serviço Compose é a **chave do YAML**, que
  não muda quando o serviço é renomeado, e o card "Internal URL" da aba Connection
  depende disso. O mesmo cálculo existe em JS (`webui/fmt.js::composeHost`), coberto
  pelo teste `renomear_servico_na_aba_general` do daemon; aqui é a metade Luau. Num
  Compose o nome do serviço (`meu_banco`) não aparece — vale a chave do YAML; numa
  Application é `rp_<nome>`, e sem `db_kind` a GUI põe `http://` (a webui, hoje, não
  põe esquema nenhum — divergência anterior ao rename, não mexida aqui).
- **`fmt_time`** existe desde que o arquivo deixou de fazer a aritmética de fuso à
  mão e passou a chamar o global `date` da glacier-ui 0.73. A conversão UTC → hora
  local é o tipo de coisa que quebra em silêncio — um timestamp errado por três
  horas ainda parece um timestamp —, então vale um teste próprio. Toda asserção é
  **independente do fuso** da máquina que roda. A que carrega o peso é a primeira: o
  mesmo instante escrito como `…Z` e como `…-03:00` tem de renderizar igual, seja
  qual for o fuso local. As demais: fração de segundo é aceita e descartada;
  a conversão realmente aconteceu (o horário exibido é o UTC deslocado pelo offset
  local, a menos que a máquina esteja em UTC); o prefixo de data e hora é o mesmo nas
  duas formas; ausente ou malformado vira `""`, que é o que os templates esperam; sem
  `finished_at` conta até agora — o valor varia, o formato não. O offset local é
  perguntado ao sistema com `date +%z` (a mesma fonte que o `localtime` do Luau
  consulta), para o teste não precisar de crate de data só para conferir uma
  subtração; `hora_deslocada` soma o offset descartando a virada de dia (só as
  horas importam).

### 5.3 A validação *headless* das telas (`tests/templates_render.rs`)

Todo template parseia, toda tela/aba avalia e monta uma árvore de elementos `iced`
sem erro. Pega KDL malformado e propriedade `.gss` desconhecida — que derrubaria
uma folha de estilo inteira — sem precisar de display. `boot` sobe o motor do jeito
que o `main.rs` faria, mas da raiz do workspace para os caminhos de template
resolverem; o `app.gvb` já linka o `app.gss` (`<link rel="stylesheet">`, global
desde o glacier-ui 0.23), então `register_component` o pega sem um
`load_stylesheet` à parte.

**Janelas à parte.** "Novo projeto", "Novo job", "Logs" e o wizard "Novo serviço"
são, cada uma, um motor isolado aberto por `open_window`; não passam pelo `app.gvb`,
então cada teste as registra e renderiza por conta própria, **semeando** a conexão
(e projetos/serviços já buscados) como `open_window({ data = … })` faria. O init do
script real tenta o catálogo, mas o *fetch* suspende sem executor — por isso os
dados que os passos esperam são semeados à mão. Chaves como `njob_time` ("HH:MM" do
`<timeedit>`) e a coleção do `<radiogroup>` de dia da semana são semeadas pelo
`init()` da janela real; o teste faz o papel dele.

**Onda 1 da reforma** (glacier-ui 0.102+): o campo NOME de "Novo projeto" usa a
validação declarada no `<form>`. Na árvore avaliada, o `form_control` `np_name` deve
carregar `rules` com `required` e ter o `on_validation_error` do `<form>` propagado
(`form_error_action`) — é o que garante que um envio vazio roteie para o
`np_apontar` em vez do `submit_project`.

**O teste que passa por todas as telas** (`all_screens_and_service_tabs_render`)
percorre: as views do shell; o Deploy Engine com a fila "NA FILA" (itens
arrastáveis, estado pausado, botão de retomar); o Ingress com a tabela de portas TCP
de host (separada das rotas de domínio); as **cinco sub-abas** do Docker (o laço de
views só renderiza a padrão, `containers`; cada sub-aba tem painel escopado por
`docker_tab`, antes nunca exercitado) e, no Registry, também o ramo "repo
selecionado" (lista de tags); Schedules; o projeto aberto (grade de serviços e a aba
de variáveis de ambiente de projeto, com um nome de variável absurdamente longo para
exercitar o truncamento de `key_display` sem quebrar o `key` completo usado por
delete/reorder/`.env`); a aba Variáveis no modo "usar secret" e a lista de secrets
vazia; Settings (Git com os dois métodos, Web Server — cuja URL pública é derivada
pelo daemon e exibida só-leitura —, Infra as Code com os ramos de variáveis
faltando e de relatório aplicado, e Manutenção com as três recorrências, cada uma
mostrando campos diferentes, o toggle geral e os seis sub-toggles); e as abas do
detalhe de serviço (editor de env, painel de build log, sub-aba Gitea, os estados de
webhook — com URL emitida, sem token por nunca ter sido deployado, e serviço Compose
sem webhook — e as sub-abas Git/Zip do provider e o editor de Compose).

**Contratos travados por testes próprios:**

- **A sidebar é uma `<drawer>`** (Onda 2 da reforma,
  `docs/plano-reforma-gui-glacier-0.102.md`), não mais um trilho de ícones
  colapsável por `@media`. O teste trava três coisas: (1) o `<drawer>` (um
  `<Reveal axis="x">` após o eval) reflete `{menu}` no seu `open` — `"true"` abre,
  vazio fecha; (2) o gatilho ☰ da topbar dispara `drawer::toggle:menu`, a ação que o
  builtin `Drawer` consome de qualquer lugar da tela; (3) abaixo de 900 px os
  rótulos dos `NavItem` **não** são forçados a `hidden` por um `@media` — era o bug
  antigo (o trilho sumia o rótulo; agora a gaveta inteira fecha pelo ☰ e, aberta,
  cabe em 264 px). O teste usa uma largura estreita, a que reproduziu o bug de layout
  original.
- **Ações do serviço por largura.** As ações Deploy/Reload/Rebuild/Stop têm duas
  fileiras que se alternam: acima de 1080 px vale a de texto; abaixo, a compacta
  (ícone + tooltip) — senão os quatro rótulos por extenso não cabem e o título de
  30 px transborda por baixo deles ("Deploy por cima do nome"). Ambas existem sempre
  no AST; o que muda é qual está `hidden`. O rótulo de um botão é `Button { text }`,
  não um nó `Text` filho; as quatro ações são as únicas a usar esses textos, então não
  há colisão com os ícones da sidebar (que são nós `<text>`, não botões).
- **Avaliação escopada** (glacier 0.38+): só a tela ativa é construída, não todo
  template registrado. Importa mais aqui que na média dos apps: o `app.gvb` importa a
  árvore inteira de views, e avaliar um template inlina recursivamente tudo o que ele
  usa — então a versão antiga reconstruía a UI completa uma vez **por template
  importado**, a cada tecla digitada e a cada linha de log vinda do SSE. O teste
  trava o ganho: registrar o `app.gvb` e ativá-lo deve deixar exatamente **uma**
  árvore avaliada (as views importadas ficam registradas, mas só a tela ativa é
  avaliada; as demais são inlinadas dentro dela).
- **Logout zera a RAM da sessão.** Nada do daemon anterior pode continuar no contexto
  (nomes de projeto, linhas de log, o próprio `api_token`). Foi um bug real: o
  `disconnect` antigo limpava só quatro chaves à mão. Hoje ele apaga o `ctx` inteiro
  e deixa o `init()` semear os defaults; o teste dispara a ação de verdade
  (`UiClick`, o mesmo caminho do botão Disconnect) com um estado de sessão
  conectada "do trivial ao sensível" e inspeciona o contexto — que deve voltar ao
  estado de boot, não ao da sessão.
- **O item "Projects" não apaga nas sub-telas.** Regressão: ele perdia o fundo azul
  ao entrar num projeto ou serviço, porque o `nav_item.gvb` comparava `{view}` contra
  um `target` de **uma** view só (`equals`) e `project_services`/`service` não são
  `"projects"`. A correção usa `one_of` (glacier-ui 0.57.8): `target="projects
  project_services service"` casa com qualquer das três. `nav_row_on` é a classe do
  fundo azul, mas o widget `<button>` lê a propriedade `color:` do GSS para o fundo
  (`background:` é ignorada em botões), então o campo que importa é o `color` de
  `node.kind`, não o `node.background` genérico (esse é para containers/rows). O
  `on_click` chega **namespaceado** pelo componente que o hospeda (`namespace_action`,
  em `eval.rs` do glacier-ui): mesmo com o valor vindo de uma prop
  (`action="nav_projects"` em `shell.gvb`), o botão vive dentro do template do
  `NavItem`, então o dispatch final é `NavItem::nav_projects`.
- **Janela, título e tamanho** (glacier-ui 0.117). A janela **principal** é do
  `app(...)` (tamanho, mínimo, moldura, ícone); o título é da `screen` (acompanha a
  navegação); e o tamanho de cada janela **filha** vai na chamada
  `open_window{ component = "…", size = "…" }` dos handlers, porque a `screen` é só
  conteúdo. O teste garante que nada disso sumiu no caminho — um atributo apagado por
  engano não quebra render nenhum, só faz a janela nascer com o padrão do iced. A
  janela de logs é a exceção proposital: o título é dinâmico ("Logs — nginx",
  "Build — abc123") e vem de quem a abre.
- **Os ajustes do daemon no `app(...)`** (glacier-ui 0.119): fontes, fonte padrão,
  `antialiasing`, período dos toasts e `application_id`. Um atributo apagado por
  engano não quebra render nenhum — o app só passa a abrir sem a fonte e com MSAA
  ligado, em silêncio.
- **Todo `.gvb` abre com a casca certa:** `app` no manifesto, `screen` nas telas
  abertas em outra janela e `component` no resto. O teste precisa existir porque o
  glacier-ui aceita a forma sem cabeçalho (declarações soltas na raiz) por
  compatibilidade: nada no build reclamaria de um arquivo que voltasse a ela, e o que
  se perde é silencioso — numa tela, título e tamanho caem no padrão; num componente,
  some a fronteira entre declaração e layout. É **textual** de propósito (um
  `component` não declara nada por desenho, então só o texto diz em que forma o
  arquivo está) e **varre o diretório** em vez de listar arquivos: o alvo é o `.gvb`
  que ainda não foi escrito. `comentarios_fora` remove `//` e `/* … */` para que "a
  primeira tag" seja a primeira de verdade (todo template abre com um comentário de
  cabeçalho). `views/` mistura manifesto, telas e views internas (`component`); só
  `views/components/` é homogêneo — nada ali é tela. Uma guarda impede o teste de
  passar vazio (um caminho errado tornaria tudo um *no-op*), com comparação frouxa
  de propósito: acrescentar um `.gvb` não deve obrigar a editar o teste.
- **As grades de cards passam o item inteiro** ao componente via `spread="{c}"`
  (glacier-ui 0.62). Isso troca um atributo por campo por um só — e move a checagem
  do contrato para o **dado**: um campo que o `fmt/dashboard.luau` não emitir vira
  `MissingProp` e derruba a tela inteira, não um `{placeholder}` vazio como antes. O
  caso perigoso é o **filler** (o card vazio que completa a fileira): ele nasce de
  um único `FILLER` compartilhado pelas duas grades, e em Lua um campo `= nil`
  simplesmente não existe — por isso ele carrega a união dos dois contratos como
  string vazia, e é isso que o teste tranca. Ele fixa `data_loading = "false"`
  porque o `connection.luau` semeia `"true"` no `init` e o `<scrollable>` da grade
  fica escondido atrás disso — sem a correção o `for-each` nunca roda e o teste
  passaria sem ter avaliado um card sequer. A fileira de teste é um card real mais
  um filler, exatamente a forma que `M.project_rows` produz com 1 projeto numa grade
  de 2 colunas.

---

## 6. Os templates `.gvb` por dentro

Os templates descrevem a interface; o comportamento mora em Luau (`views/scripts/`).
Esta seção reúne o que antes estava nos comentários dos `.gvb`, agrupado por assunto.
A estrutura de arquivos (um roteador fino por tela, um arquivo por view ou aba) e as
regras de divisão estão no `AGENTS.md`, em "Dividir um template grande em arquivos".

### 6.1 Regras que valem para todos os templates

**Um só script, um só contexto.** Toda a lógica de rede e de estado (login, navegação,
busca, stream SSE e ações) vive em Luau, no script que o `app.gvb` carrega
(`scripts/app.luau`, sucessor de `app/root.rs` + `app/net/*`). É o único script ativo.
Como o contexto do glacier é **global**, os templates importados (login, shell, home,
service) só têm markup, e os handlers deles resolvem para as funções desse script.
`require("net/api")` e `require("fmt")` resolvem em `scripts/`, relativo ao diretório do
script. As janelas auxiliares são a exceção: cada uma tem o próprio script e o próprio
motor.

**Janelas isoladas para o que é caro.** O glacier reavalia **todos** os templates
registrados a cada reavaliação. Na janela principal (shell + home + service + wizard, com
dezenas de `for-each`) isso é caro, e sob um stream de logs verborrágico satura a UI,
mesmo coalescido a 30 fps. Por isso os logs (runtime e build) abrem em janela própria:
lá o motor só tem um template minúsculo, cada reavaliação é trivial e o log rola liso
independente da taxa de chegada. O mesmo vale para a aba Logs do serviço, que é só um
*launcher* (ver [6.5](#65-o-detalhe-do-serviço)), e para o build log de um deployment
(`dep_logs` → `open_window`): renderizar milhares de linhas por reavaliação travava a
principal.

**A condição vai na chamada, não na raiz do componente.** Num componente extraído, o `if`
do nó raiz não é aplicado: o conteúdo apareceria sempre. Por isso as abas se escrevem
`ServiceLogsTab(if = @tab, equals = logs)` e as abas de projeto
`ProjectEnvTab(if = @proj_loading, not_equals = true)`, com o `if` no ponto de uso. O
mesmo raciocínio vale para o `LoadingRow` (ver [6.7](#67-os-componentes)).

**Vários filhos condicionais pedem `if @x { … }`, não `if=` como atributo.** O atributo
`if=` num elemento condiciona **só aquele elemento**. Um bloco com vários filhos
(o editor `.env`, o modo *secret*, os blocos de cada view) usa o bloco `if`/`<template>`.
No editor `.env`, por exemplo, o atributo só esconderia o `Text` e deixaria o
`TextArea` e os botões sempre visíveis.

**`scrollable` só renderiza o primeiro filho** (`NodeType::Scrollable` usa
`node.children.first()`, em `widget.rs` do glacier-ui). Por isso a lista e o editor `.env`
vivem dentro de **uma única** `column`, nunca como irmãos diretos do `scrollable`. Foi
também o que corrigiu os botões Salvar/Cancelar do editor, que antes eram irmãos fixos
depois de um `scrollable` com `height: fill` e podiam ficar cortados em janelas baixas.

**Listas vazias são `fallback`.** Cada lista tem um componente `Sem…` que o `fallback` do
`for-each` (e o `foreach_fallback` do `<template>`) desenha no lugar dela. Eles moram no
arquivo que os usa.

**Janelas sem `background: var(--bg)`.** As telas das janelas auxiliares (e o login) não
repetem o fundo no CSS: `var(--bg)` é a cor do tema, já pintada na janela inteira, e
repeti-la era uma camada redobrada em cada pixel (ver `PRIMITIVAS.md`, "O que custa num
quadro").

**Ícone + tooltip em vez de rótulo por extenso** onde a coluna é estreita. As linhas de
job (Schedules), de repositório (Registry) e de deployment (aba do serviço) trocaram
"Rodar agora", "Ver logs", "Pausar", "Build log ↗" e "Remover" por ícones com tooltip: os
rótulos quebravam em duas linhas e estouravam a coluna quando a janela estreitava, e uma
linha de 360 px pensada para rótulos por extenso empurrava o botão de remover para fora
da largura visível (sem scroll horizontal).

**Validação declarada no `<form>`** (glacier-ui 0.102+). As regras moram no campo
(`rules=`); o motor valida ao enviar e roteia `on_submit` (tudo certo) ou
`on_validation_error` (algo falhou). O `<button type="submit">` dispara sem `on_click`, e
o `.np_input:invalid` (em `app.gss`) acende sozinho. `form` não aninha: um formulário
próprio tem de ficar **fora** de outro.

**Entradas numéricas são widgets, não texto livre.** O `<spinbox>` e o `<timeedit>`
validam por construção; ver "Healthcheck" e "Manutenção" abaixo para o que deu errado
antes.

**Estilo e responsividade.** O estilo inline fica no `<style>` de cada arquivo; o que é
compartilhado e responsivo (as regras de `@media`) vive em `app.gss`, não nos
templates: cruzar arquivo com o inline deixaria a precedência ambígua. A cor de um estado
vem da camada GSS, nunca de hex vindos do Rust.

### 6.2 O manifesto (`views/app.gvb`)

A raiz do arquivo é o `app(...)` e as telas — a janela principal e as cinco auxiliares —
são filhas dele (glacier-ui 0.117+).

- **`id`** nomeia o diretório de dados (`~/.local/share/rustploy`, onde moram o `storage`
  do Luau — o login lembrado — e a geometria da janela) e é a chave da **instância
  única**. Com a bandeja declarada, fechar a janela recolhe o app em vez de encerrá-lo, e
  uma segunda execução foca a primeira.
- **`size`, `min_size`, `icon`, `decorations`** são da janela **principal**. O ícone as
  filhas herdam; o tamanho de cada uma vai no `open_window("tela", { size = … })` dos
  handlers.
- **Fonte e daemon.** A fonte padrão vale para todas as janelas (declarada no próprio
  `app(...)`); o `application_id` do Linux casa a janela com o `rustploy-gui.desktop`.
  O **MSAA x4** padrão do iced custa caro num fallback 100% por software (sem GPU
  compatível: o `wgpu` recusa adapters não-Vulkan-compliant e cai para a CPU), e telas de
  formulário e de lista não perdem legibilidade sem ele — por isso o `antialiasing` é
  declarado desligado.
- **Janela borderless.** Com `decorations = false`, uma moldura de 6 px de *handles* de
  resize envolve o conteúdo. Cada handle define o cursor de hover e inicia um resize
  interativo ao pressionar (`window:resize:<dir>`), tratado no runtime contra o id da
  janela em cache. O glacier não tem overlay/z-stack, então a moldura é montada como
  linha de cima / faixa do meio (bordas esquerda e direita + corpo) / linha de baixo.
- **Titlebar custom.** `titlebar_drag` (`width: fill`) é a alça de arraste e empurra os
  controles para a borda direita; as ações `on_press`/`on_click` `window:*` são tratadas
  no runtime contra o id da janela.
- **As janelas auxiliares** (`log`, `new_job`, `new_service`, `new_project`,
  `new_registry_token`): cada uma é um motor isolado que abre **só** a tela pedida
  (`open_window("log", …)`), com o próprio script — o `init` delas não roda na principal.
  Os tamanhos estão nos handlers.

### 6.3 O shell (`views/shell.gvb` e `views/shell/`)

O shell é a casca do app conectado: sidebar, topbar e as views de projeto (Deployments,
Projects, serviços de um projeto, detalhe de serviço); delega as telas globais ao
`home.gvb`.

- **A sidebar é uma `<drawer>`** (glacier-ui 0.92+, Onda 2 da reforma,
  `docs/plano-reforma-gui-glacier-0.102.md`). Largura, padding e spacing vêm das props do
  `<drawer>` no markup; o CSS só dá a cor (o painel carrega `drawer-panel` + `sidebar`). A
  gaveta **empurra** o conteúdo (não cobre) e não desenha gatilho: o ☰ mora na topbar e
  `drawer::toggle:menu` funciona de qualquer lugar. O `init()` (`connection.luau`) semeia
  `menu = "true"` para começar aberta.
- **Responsivo** (glacier-ui 0.9.0+): em janela estreita a sidebar-gaveta **fecha** pelo ☰
  (o motor anima a largura 264→0), em vez do antigo trilho de ícones. Sobra só o aperto da
  própria topbar; abaixo de 560 px somem a busca e o status do daemon (baixa prioridade)
  para o ☰, o *Stop All* e o *Disconnect* não serem cortados.
- **`app:` no ☰.** O prefixo `app:` tira o prefixo de dono (`Shell::…`) que o motor poria
  numa ação escrita dentro de um `<component>`; sem ele a ação não chegaria ao builtin
  `drawer`. Sai `drawer::toggle:menu`, que o dispatch roteia para o `<drawer>` (o alias
  minúsculo é um componente registrado).
- **Detalhe de serviço e o wizard.** O wizard "Novo serviço" saiu do shell
  (`view = new_service`): agora abre numa janela à parte (`new_service_window.gvb`),
  disparada por `open_new_service_window`.
- **Projects.** Criar projeto abre uma janela à parte (`new_project_form.gvb`, motor
  Glacier próprio); ao concluir, ela envia um `broadcast("project_created")` que o
  `on_broadcast` (`handlers/projects.luau`) recebe para atualizar a grade. Ver
  `open_new_project_window`.
- **Projeto aberto (`project_services.gvb`).** Barra superior com *voltar* à esquerda e as
  ações do projeto empurradas para a extremidade direita (`hspacer` = `width: fill`); em
  modo de edição as ações somem (o form tem Salvar/Cancelar). A grade de serviços usa
  `virtualize` = a altura de **uma** fileira de cartões: só as fileiras visíveis são
  montadas e as de fora viram um vão do tamanho exato (glacier-ui 0.77, ver
  `PRIMITIVAS.md`). O valor é a altura do card; o `spacing: 10` da `.grid` o motor soma
  sozinho. Errar desalinha a barra de rolagem, não quebra.
- **Aba Variáveis (`project_env.gvb`).** No modo *secret* o campo valor passa a receber o
  **nome** de um secret do projeto (a referência, não o conteúdo), que o daemon decifra no
  deploy. Os comentários (`# …`) do `.env` são arrastáveis como as variáveis (ao soltar,
  reancoram na variável seguinte da nova ordem), mas sem delete — removem-se editando o
  `.env`. O editor `.env` é um bloco condicional com vários filhos.
- **Aba Secrets.** É *write-only*: o daemon só devolve os nomes (o valor é cifrado com a
  chave mestre do servidor), então não há coluna de valor nem edição — sobrescrever é salvar
  de novo com o mesmo nome. Ver `handlers/secrets.luau` e `docs/secrets.md`.

### 6.4 As telas globais (`views/home.gvb` e `views/home/`)

Cada tela é uma seção por valor de `view`: Monitoring, Ingress, Deploy Engine, Docker (e
Registry), Settings, Schedules e Suporte.

- **Monitoring.** Bloco com vários filhos condicionais: precisa de bloco `if`/`<template>`,
  não do atributo `if=`.
- **Deploy Engine.** KPIs + deploys em andamento + histórico das últimas 24 h. Tudo vem do
  `Command::DeployEngineStatus` (ver os `eng_*`); sem backend novo. A fila é **global** (um
  deploy por vez): o primeiro é o próximo a rodar. Arrasta-se pela alça (⋮) para reordenar,
  ↑ fura a fila, ✕ cancela, e pausar/retomar interrompe o worker de puxar o próximo (o que já
  está rodando segue). Tudo em `handlers/deploy_queue.luau`. São três abas (`eng_tab`: fila, executando, histórico; handler `eng_tab` em `handlers/nav.luau`),
  cada uma num arquivo de `views/home/deploy_engine/`. Separadas, cada lista tem a tela toda:
  quando eram três seções empilhadas, uma fila grande empurrava as outras para fora da janela.
- **Docker.** Sub-abas Containers / Images / Volumes / Networks / Registry. As três do meio
  listam **todo** o host Docker (não só os recursos geridos pelo Rustploy; ver
  `docker_inventory` no daemon), com indicação de uso e botão de limpar as que estão sem uso.
  - *Containers:* o container nasce de um `Service`, então a ligação com projeto/serviço é
    direta. A lista mostra todos do host (rodando + parados); remover só é oferecido nos
    **parados** (o Docker recusa `rm` de um rodando sem `force`).
  - *Images:* a lista já vem ordenada por tag (`docker_images_json`); o checkbox "Somente em
    uso" só esconde as linhas sem uso, sem *round-trip*.
  - *Volumes:* o Rustploy só usa *bind mounts*, então os volumes nomeados aqui são sempre
    externos a ele (criados à mão ou por `VOLUME` da imagem).
  - *Registry:* repositórios/tags do registry OCI embutido (Fase 1: só push/pull via docker
    CLI; sem auth ainda). Leitura + delete (metadados) + GC (libera do disco blobs/manifests
    órfãos). As tags de um repositório são buscadas **sob demanda**, ao clicar "Ver tags" —
    não vêm no snapshot periódico, diferente das outras sub-abas. `registry_repos` chega
    **filtrado** pela busca (`fmt.registry_repos(snap.registry_repos, term)` em
    `stream.luau`), enquanto o `registry_repos_count` é da lista crua; por isso a mensagem de
    "Faça `docker push`…" usa o count (trocar pelo `empty` de `registry_repos`, como nos
    outros pares lista/count, a faria aparecer quando a busca só não achou nada, não quando o
    registry está genuinamente vazio), e o `fallback` distingue "registry vazio" de "busca sem
    resultado".
- **CSS compartilhado das colunas de ação.** `align-x` só afeta como um container de
  linha/coluna posiciona seus **filhos**; não alinha o texto de um elemento dentro da própria
  caixa (isso é `text-align`). Como a classe `.col_act` é reaproveitada no texto do cabeçalho e
  no container dos botões, sem `text-align` o rótulo "AÇÃO" ficava colado à esquerda enquanto
  os botões (`align-x: end`) ficavam colados à direita. `.col_act_2` é a linha de repositório
  do Registry (2 ícones: ver tags/remover, com tooltip), `.col_act_4` a de job em Schedules (4
  controles: rodar/logs/pausar-ativar/remover) e `.col_act_5` a mesma com um controle a mais
  (editar).
- **Ingress.** Os estados vazios das listas usam o `fallback`. As portas TCP de host são
  exposição direta de porta, fora do proxy HTTP por domínio: um serviço pode ter as duas, só
  uma, ou nenhuma.
- **Settings → Git.** OAuth: o Luau não abre o navegador; guarda a URL em `gp_oauth_url` e o
  built-in `open:<chave>` do glacier abre no navegador padrão.
- **Settings → Infra as Code.** O manifesto é um `.zip` com exatamente `rustploy.yml`
  (projetos/serviços; variáveis de ambiente sempre como `${VAR}`) + `rustploy.vars.toml` (os
  valores reais, aninhados por escopo). Exportar/importar usam os diálogos nativos do SO, e o
  import rejeita um zip que tenha qualquer outra coisa. Ver `iac_export`/`iac_import` em
  `handlers/settings.luau` e a ponte do zip na [seção 3](#3-a-ponte-do-zip-do-infra-as-code).
- **Settings → Manutenção.** Limpeza automática de recursos Docker sem uso (ver
  `docs/plano-limpeza-automatica-docker.md`): as mesmas funções dos botões manuais da aba
  Docker, disparadas por agendamento em vez de clique.
  - O **dia da semana** eram sete `<TabButton>` escritos à mão mais o handler `dc_weekday` só
    para gravar a escolha. O `<radiogroup>` (glacier-ui 0.66) grava a chave sozinho, no update
    dele em Rust, então o handler foi embora junto. As opções vêm de `weekdays`, semeada em
    `handlers/connection.luau` a partir de `fmt.WEEKDAYS_JSON`; a aparência agora é de radio
    buttons redondos, não da fileira de pílulas.
  - O **horário** era um par de campos de texto livre ("HORA (0-23)" e "MINUTO (0-59)"), e a
    faixa no próprio rótulo era a confissão de que nada impedia digitar 99: o handler fazia
    `tonumber(...) or 0` e agendava a limpeza para a meia-noite sem avisar ninguém. O
    `<timeedit>` (glacier-ui 0.68) é um campo só, editado por seções (clique na hora, setas ▴▾
    mexem nela), onde não dá para digitar e portanto não dá para digitar errado. A chave
    `dc_time` é `"HH:MM"`; `fmt.hm_join`/`fmt.hm_split` fazem a ponte com o `{hour, minute}`
    que o daemon espera — o contrato HTTP não mudou.

### 6.5 O detalhe do serviço (`views/service.gvb` e `views/service/`)

O cabeçalho tem as ações (deploy, stop, reload), e as abas são General (fonte), Connection,
Domains, Environment, Deployments, Logs e Advanced (mais Databases, Migrar e Healthcheck
conforme o serviço).

- **Status numa sub-linha.** Status + timer ficam numa **sub-linha** abaixo do nome, nunca na
  mesma linha do título. Antes o badge ficava inline e, quando o nome quebrava em duas linhas,
  o "Running" era desenhado por cima da segunda: um elemento de texto do iced não corta ao
  ultrapassar a caixa `fill`, e o badge (posicionado logo após a caixa estreita) caía sobre o
  texto vazado. Descê-lo elimina qualquer disputa horizontal com o nome.
- **Timer de deploy.** O "1s, 2s, 3s…" só aparece enquanto um deploy iniciado por este painel
  (Deploy/Rebuild) está em andamento. É incrementado uma vez por segundo pela subscription de
  poll (`sec_tick`, em `net::poll_stream`) e some quando o deploy termina; o desfecho e o
  tempo total aparecem então em `svc_action_msg`, logo abaixo.
- **Ações responsivas.** As ações compactas (ícones) ficam **empilhadas** abaixo do título e
  só valem até 1240 px; ficam dentro da coluna do título de propósito: quando aperta, a
  fileira de rótulos à direita some (`@media`) e `header_titles` passa a ocupar a largura toda,
  então os ícones descem para cá — título e ações nunca dividem a mesma linha em janela
  estreita, e por isso nada sobrepõe o nome. A fileira de rótulos por extenso fica à **direita**
  do título, só acima de 1240 px; abaixo disso ela some (`@media` em `app.gss`) e entram os
  ícones. O `.svc_actions_full`/`.svc_actions_compact` e o swap por `@media` vivem em
  `app.gss`, junto das outras regras responsivas.
- **O nome é o elemento flexível da linha do título** (`.svc_title { width: fill }`): ele
  absorve a folga e quebra dentro da coluna quando aperta. Sem isso, o botão de voltar, o nome
  e o badge são todos `shrink` (largura natural) e, quando a soma passa da largura da coluna, o
  iced **não** encolhe — transborda para a direita e o nome/badge invadem os botões de ação (o
  "Deploy/▶ por cima do nome").
- **Abas com scroll horizontal.** São 8 abas e, em janela estreita, as últimas
  ("Healthcheck"/"Logs"/"Advanced") saíam da tela sem como alcançá-las. A viewport
  (`.tabs_scroll`) é `width: fill`; a fileira interna (`.tabs_main`) é `width: shrink` (largura
  natural), então quando as abas não cabem ela transborda a viewport e a barra de rolagem
  aparece.
- **Painel lateral.** Mostra o status. O log ao vivo saiu dali: era um `for-each` sempre
  renderizado que a reavaliação processava a cada tick; agora é janela.
- **CSS.** `.btn_export`/`.btn_export_on`/`.env_editor` vivem em `app.gss` (compartilhados com o
  shell). `.dep_actions` são 2 botões-ícone (ver build log / remover) com o rótulo no tooltip;
  o padding era `7 15`, dimensionado para "Build log ↗" e "Remover" por extenso, que estouravam
  a coluna em janela estreita.
- **General.** Enquanto o fetch do detalhe (spec + listas conta/repo/branch do Gitea) não
  completa, mostra-se um loading — os `Select` só aparecem depois, já populados, em vez de
  piscarem vazios. Renomear é um **form próprio**, fora do form `general` (form não aninha); o
  nome é só de exibição para Compose (stack e volumes ficam gravados), e em Application o alias
  de rede acompanha o nome no próximo deploy — o aviso abaixo do campo diz qual dos dois vale. A
  aba "Gitea/GitHub" vale para qualquer conta conectada em Settings → Git; o `target`/`action`
  seguem `gitea` por ser a chave de estado (`prov_tab`), não o nome do provedor. O `placeholder`
  do editor Compose é um `l"""…"""` (glacier-ui 0.119+): um texto em que a quebra de linha é
  conteúdo. `"…"` não interpreta `\n` e só aceitaria a quebra literal, com as linhas de
  continuação coladas na margem; `"""` dobra as linhas em espaços. O `l"""` (de *linhas*, não de
  *raw*) mantém as quebras, tira o recuo comum e continua interpolando `@nome`; o mesmo vale para
  o placeholder do compose em `new_job_window.gvb`.
- **Environment.** Valem as regras de `scrollable` e do editor `.env` de [6.1](#61-regras-que-valem-para-todos-os-templates).
  Os comentários (`# …`) do `.env` são arrastáveis como as variáveis (ao soltar, reancoram na
  seguinte), mas sem delete; a classe da linha muda para `kv_row_drag` no item agarrado
  (`{e.__dragging}` vem do glacier-ui durante o arrasto).
- **Deployments.** A URL do webhook e os botões ficam em **linhas separadas**: a URL é longa
  (~100 caracteres) e, com `width: fill`, empurraria os botões para fora do painel. Ela é exibida
  **truncada** (`svc_webhook_url_short`), porque inteira estoura o card em janelas estreitas; o
  valor completo vai no tooltip e no clipboard. As ações da linha são ícone + tooltip (ver
  [6.1](#61-regras-que-valem-para-todos-os-templates)), e o build log abre em janela isolada.
- **Domains.** Lista de rotas HTTP (domínio → porta de container, TLS por rota), mais o form de
  adição e a porta TCP crua do host.
- **Advanced.** O teto de 20 réplicas é arbitrário mas deliberado: um número acima disso num
  single-node é quase sempre engano de digitação, e o widget não deixa mais chegar lá. O piso de
  1 substitui o `if r < 1 then r = 1` do `adv_save`, que fica como rede redundante. A **fila de
  pré-deploy** é editável com efeito imediato (como Domains, não passa pelo Save do form acima):
  cada item roda em **ordem** antes do deploy, e a primeira falha para a fila inteira.
- **Healthcheck.** O *expected status* era um `<input>` de texto livre com uma linha de erro
  abaixo, `<text if="{erro_f_hc_status}" …>`. Só que `erro_f_hc_status` **nunca foi escrita por
  ninguém** (nem Luau nem Rust): a validação que ela anunciava não existia, e o handler engolia
  lixo em silêncio (`tonumber(...) or 200`). Quem valida agora é o próprio widget, que satura em
  mínimo/máximo; o mesmo vale para os outros cinco campos numéricos da tela, e as linhas
  `erro_f_hc_*` saíram junto. A faixa dos quatro números do health check sai do que o daemon
  aceita: intervalo/timeout/start em segundos (1 h de teto é folgado para qualquer check
  razoável) e *retries* na faixa do Docker.
- **Logs.** A aba é só o *launcher*: os logs de runtime vivem numa janela isolada (motor leve),
  não inline, porque renderizar o stream aqui reavaliaria a árvore inteira da janela principal
  por linha e a travaria. A condição de visibilidade vai na **chamada** (ver 6.1).

### 6.6 As janelas auxiliares

Cada uma é um motor Glacier **isolado** e abre só a própria tela. O tema e o `app.gss` são
declarações globais do `app` (`app.gvb`), que cada janela carrega. Todas são *borderless*
(`decorations = false`, como a principal): a titlebar é custom e as ações `window:*`
(`drag`/`minimize`/`close`) são tratadas no runtime contra o id da janela; as de diálogo não têm
*maximize*.

**O que elas têm em comum.** O app principal as abre com `open_window` e **semeia** a conexão
(`api_url`/`api_token`) e o que já tem à mão via `open_window({ data = … })`. Nada é buscado ali
dentro: um `fetch` rodado no `init()` é descartado pelo motor (só ações despachadas chegam ao
executor), a mesma razão de `new_service_window.luau`. A `screen` é só conteúdo — o tamanho vai
no `open_window{ size = … }`.

- **Logs (`log_window.gvb`).** Janela de **logs ao vivo** (runtime ou build), aberta por
  `handlers/services.luau` (`open_logs_window`/`open_build_logs_window`). É genérica: o script
  decide o tipo pelos dados semeados — `api_url`/`api_token`, `lw_title`, `lw_stream_url`
  (endpoint SSE dedicado) e `lw_seed` (histórico inicial); ver `scripts/log_window.luau`. O motivo
  da janela está em [6.1](#61-regras-que-valem-para-todos-os-templates). Não tem `title` no
  cabeçalho de propósito: o título é dinâmico ("Logs — nginx", "Build — abc123", "Job — …") e
  quem o sabe é quem a abre, no `open_window{ title = … }`; o tamanho (900×560) vai no
  `open_window{ size = … }`. O corpo é um `<textarea readonly>` (`text_editor` do iced): texto
  **selecionável** e copiável (arrastar + Ctrl+C), mas não editável (`readonly` ignora
  digitação, apagar e colar; seleção e scroll seguem funcionando). Cada linha nova é
  **appendada** no fim via `append_textarea` (o motor insere sem recriar o buffer, preservando o
  scroll). O botão ↓ rola até o fundo (`textarea_end:`) sem precisar arrastar a roda. O
  `textarea` do glacier-ui desenha a própria barra de rolagem (arraste o *thumb*, clique na
  trilha) e rola também por roda, teclado e pelos botões ↑/↓.
- **Novo job (`new_job_window.gvb`).** Aberta por `handlers/jobs.luau` (`open_new_job_window`), que
  semeia a conexão + os catálogos de projetos/serviços já buscados pela janela principal. Passos:
  escolher projeto → escolher serviço gatilho (rede + env vars de base) → formulário (nome,
  compose, `main_service`, recorrência). Ao concluir emite `broadcast("job_created")` e fecha.
  - *Passo 2:* o serviço gatilho é opcional — só traz env vars de base; a rede Docker já vem do
    projeto escolhido no passo 1.
  - *Passo 3:* o formulário também é o **único** passo em modo edição (`open_edit_job_window`,
    sem passos 1/2: projeto e serviço gatilho não são editáveis via `JobUpdate`).
  - *Aba Git:* o mesmo picker conta→repo→branch da aba Gitea do serviço; o repo escolhido
    precisa já ter um `docker-compose.yml` no caminho informado — o job clona e roda esse
    arquivo a cada execução, em vez do colado acima.
  - *Env vars:* as próprias do job têm a **maior precedência** na resolução (por cima de projeto +
    serviço gatilho); formato `.env` colado, igual ao editor de projeto/serviço, parseado em
    `njob_create`.
  - *Recorrência diária:* os pares HORA/MINUTO de texto livre viraram um `<timeedit>` só (chave
    `njob_time`, `"HH:MM"`) — a mesma troca e o mesmo motivo da limpeza automática (ver 6.4).
- **Novo projeto (`new_project_form.gvb`).** Aberta por `handlers/projects.luau`
  (`open_new_project_window`). Ao concluir, o script (`scripts/new_project_window.luau`) emite
  `broadcast("project_created")` e chama `close_window()`. A validação é declarada no `<form>` (ver
  6.1).
- **Novo token do registry (`new_registry_token_window.gvb`).** Aberta por
  `handlers/registry.luau` (`registry_open_token_window`), que semeia a conexão + o host do
  registry. Fluxo: formulário (nome + escopo pull/push) → `RegistryTokenCreate` → o segredo
  aparece em texto **uma vez**, com botão copiar. A janela **não** fecha sozinha (diferente da de
  job), porque o usuário precisa copiar antes de perder o valor. O
  `broadcast("registry_token_created")` dispara na hora da criação (não só ao fechar), para a
  lista da janela principal atualizar mesmo se o usuário nunca clicar em "Fechar".
- **Novo serviço (`new_service_window.gvb` + `new_service.gvb`).** A janela é aberta por
  `handlers/wizard.luau` (`open_new_service_window`), que semeia a conexão + o projeto-alvo, e
  reaproveita o corpo do wizard (`new_service.gvb`, importado como `<NewServiceWizard/>`); a
  lógica vem de `handlers/wizard.luau`, carregada pelo script de entrada. Ao criar, o wizard emite
  `broadcast("service_created")` e chama `close_window()`. O wizard espelha o fluxo do antigo
  remote-client (Application / Database / Compose / Template): tipo → formulário por tipo; o passo
  corrente vive em `{ns_step}` e os campos são chaves de contexto `ns_*` (os handlers `ns_*`). O
  status do wizard mostra um spinner enquanto o RPC de criação está no ar (`{ns_busy}`), e o
  texto acompanha `{ns_msg}` ("criando…" / "erro: …").

### 6.7 Os componentes

Os componentes de `views/components/` são pequenos e sem estado próprio; o que mudam vem por
props.

- **`badge`** — variante da célula de estado (mesmo ponto + rótulo, com o espaçamento e o estilo
  de crachá, `badge_lbl`). Usada no card de serviço e no cabeçalho/aside do detalhe do serviço.
- **`loading_row`** — linha "Carregando dados…" com spinner. A **condição** de exibição fica no
  chamador (`if cond="{flag}" equals="true" { LoadingRow }`), não aqui dentro: um componente
  instanciado direto (fora de `for-each`) tem a prop resolvida **uma vez** e não re-avalia quando
  o flag muda — um `if` interno à prop ficava preso em `"true"` e o spinner nunca sumia. O `if`
  inline do chamador é re-avaliado ao vivo (mesmo padrão do `if` que esconde/mostra a grid).
  `note` sobrescreve o texto padrão quando fornecido (prop ausente → vazio) e é a única prop,
  opcional; o `default = ""` reproduz exatamente o comportamento antigo, só que agora declarado. O
  indicador é o `<spinner>` do motor (glacier-ui 0.66+): um anel girando de verdade, não o glifo
  `⟳` estático de antes; o diâmetro sai do `width`/`height` do nó (o `size:` do GSS é corpo de
  fonte e não vale aqui) e a cor cai no `color` da classe.
- **`nav_item`** — item de navegação da sidebar: ícone + rótulo. Fica "ligado" (pílula azul)
  quando a view atual (`{view}`) casa com `target` via **`one_of`** (glacier-ui 0.57.8), não
  `equals`: `target` pode ser mais de uma view separada por espaço (ex.: `"projects
  project_services service"`), para o item continuar aceso nas sub-telas dele; um `target` de uma
  view só funciona igual (`one_of` com um token é comparação de igualdade). Antes da 0.57.8 isso
  não dava para fazer sem inventar gramática de expressão, e o item "Projects" apagava assim que
  se entrava num projeto. Histórico: era um botão-texto puro (`Button` com o rótulo em `text`),
  mas até a 0.57.5 o botão não suportava filhos, então não dava para pôr ícone + texto lado a
  lado; tinha virado uma `row` com `on_press` (o mesmo mecanismo de clique dos handles de
  resize/drag — qualquer nó com `on_press`/cursor vira um `mouse_area`), hack removido na 0.57.6
  (`<Button>` com filhos: um filho vira o conteúdo direto, mais de um vira uma `Row` implícita
  respeitando `spacing`/`align-y` do próprio nó). O `tooltip="{label}"` (glacier-ui 0.37.5)
  mostra o rótulo completo ao pairar o mouse; o *wrap* acontece depois do `mouse_area` em
  `widget.rs`, então o hover funciona na linha inteira, não só no ícone. A prop `view` **não**
  entra em `props`: ela vem do contexto global, não de quem instancia o item, e declarar só o
  que é prop é o que mantém a leitura do contexto funcionando. Não há `@media` de colapso: a
  sidebar virou `<drawer>` (ver 6.3); em janela estreita a gaveta fecha pelo ☰ e, aberta, tem
  sempre 264 px e o rótulo cabe.
- **`picker_row`** — linha de escolha do wizard "Novo serviço": título + subtítulo à esquerda e
  um botão de ação à direita, usada nos passos de tipo, de banco e de template.
- **`project_card` e `service_card`** — são templates **fragment** com dois nós de topo (o *slot*
  vazio e o card): o glacier-ui (0.4.12+) embrulha múltiplas raízes num `Fragment` e aplica os
  filhos no pai, então o par `if`/`else` vira dois irmãos do grid, sem nó *wrapper*. Todas as
  props são obrigatórias, inclusive no modo `filler` (o card vazio que completa a fileira): quem
  chama passa o conjunto inteiro e o próprio template decide o que renderizar pelo `{filler}`. A
  descrição é sempre renderizada (mesmo vazia) para reservar a linha, mantendo os cards da
  fileira mais próximos em altura mesmo quando só um tem descrição. O `service_card` é o análogo do
  `project_card` na aba "Serviços" de um projeto, e o crachá de estado reaproveita o `rp-badge`.
  As regras `.card_ctr_id`/`.card_ctr_extra` (cor `--text-3`) ficaram desativadas.
- **`stat_card`** — tile de KPI do cabeçalho (STATUS/UPTIME/SERVICES/CPU/…). Com `accent = "1"` o
  número usa o realce verde (`stat_num_g`); sem `accent`, o neutro (`stat_num`). A prop ausente
  vira string vazia, então `!= "1"` → neutro; por isso `accent` é opcional com `default = ""`.
- **`state_cell`** — a célula de estado das tabelas: o ponto colorido "●" + o rótulo, ambos na
  mesma cor. Usada em Deployments, Docker (containers/images/volumes/networks) e na lista de
  deployments do serviço. A cor vem da camada GSS: `kind` é um token semântico
  (`ok`/`bad`/`info`/`warn`/`muted`) e a classe `state_<kind>` define a cor (ver `.state_*` em
  `app.gss`), de modo que a paleta fica centralizada no estilo. A largura vem de `.col_state`
  (`app.gss`), junto com a coluna ESTADO do `thead` — inclusive os ajustes de `@media`
  (170/130/110); antes era 170 fixo aqui e a célula desalinhava do cabeçalho em janela estreita.
- **`tab_button`** — botão de aba genérico: "ligado" (`tab_on`) quando o valor atual da aba
  (`{current}`, passado pelo chamador, ex.: `"{docker_tab}"`) é igual ao `target` desta aba;
  caso contrário neutro (`tab`). O `equals` é interpolado, então compara os dois valores
  dinâmicos.
- **`template_row`** — linha do catálogo de templates de aplicação: logo à esquerda (vetor ou
  raster conforme `logo_kind`), nome + descrição e o botão "Escolher" à direita. Os logos vêm de
  `assets/blueprint-logos/<id>/<arquivo>`, pelo `{logo}` data-driven do catálogo do daemon (ver a
  [seção 2](#2-onde-estão-os-assets)). A
  caixa do logo é **quadrada, fixa e centralizada**: os logos têm proporções diferentes (quadrado,
  largo, estreito), então reserva-se sempre o mesmo espaço e centraliza-se o logo dentro dele, o
  que mantém a coluna de texto alinhada. A origem da imagem vem no atributo `src` (interpolado do
  `{logo}`): o parser lê o *source* de `<svg>`/`<image>` só de atributo, nunca do conteúdo entre as
  tags. A descrição só é renderizada quando existe — uma linha vazia empurraria o nome para cima e
  o desalinharia do logo (`align-y: center` da linha).
