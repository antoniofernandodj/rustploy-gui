# Plano: layout para celular (< 560px)

**Status:** proposta, nada implementado ainda.
**Escopo:** a casca (`views/shell.component.gv`) e as telas mais usadas no celular:
Deployments, Deploy Engine e Projeto → Serviços. O resto segue os mesmos padrões
depois.

---

## 1. O que está ruim hoje (capturas no celular, ~400px lógicos)

### 1.1 Casca
- **O trilho de ícones da sidebar fica sempre visível** e come ~15% da largura
  (~60px de 400). No celular ninguém usa ao mesmo tempo o trilho e o conteúdo; os
  ícones sem rótulo (`◔ ◫ ↦ ◉ ◧ ⌥ ◊`) também não dizem nada a quem não decorou.
- **O ☰ abre a mesma gaveta que já está meio aberta.** Dois caminhos para a mesma
  coisa, e o botão ocupa espaço na topbar.
- **"Parar tudo" fica na topbar, em vermelho, em toda tela.** É a ação mais
  destrutiva do app e está a um polegar de distância, sempre, ao lado de
  "Desconectar". No celular isso é convite a toque acidental.
- **A topbar tem 3 elementos grandes e nenhuma informação** (não diz em que tela
  você está nem qual daemon está conectado: `topbar__status` some em < 1100px).

### 1.2 Deployments
- **Título e botão brigam na mesma linha.** "Deployments" e "Limpar parados/falhos"
  se sobrepõem, e o subtítulo quebra palavra por palavra ("Status em / tempo real
  dos / serviços do / cluster."). Causa: o `row(class = page-head)` não empilha, e
  o `@media (max-width: 860)` que troca o botão pela versão `✕` está medindo a
  largura da janela de um jeito que no navegador do celular não pega (ou o
  zoom/escala deixa a largura lógica > 860).
- **Tabela de 4 colunas em 340px úteis:** o nome do projeto vira `Chiquit…` em
  *todas* as linhas (informação repetida e inútil), a duração vira `191m …`, e a
  coluna "Início" some.
- **Não dá para agrupar nem filtrar:** os 4 serviços LIVE ficam misturados com 11
  linhas de BUILDING antigas. (Esses BUILDING de 191m/203m/3850m parecem
  deployments órfãos no daemon — ver §6.)

### 1.3 Deploy Engine
- Funciona, mas as abas "Fila (0) / Executando (0) / Histórico 24h (7)" ocupam
  duas linhas cada e o painel "Na fila (0)" repete o que a aba já diz. Os 5
  StatCards que dariam o resumo estão escondidos (`page-head__stats--hide-xl`).

### 1.4 Projeto → Serviços
- **A barra de ações transborda:** "‹ Projetos", "Reordenar serviços", "Deploy" e o
  verde "Novo serviço" cortado na borda direita (só aparece uma lasca verde).
- **"Remover projeto"** (vermelho) fica nessa mesma barra quando permitido.
- **O card de serviço é alto demais:** ~560px para mostrar nome, 2 badges, nome e
  id do container, CPU, MEM, "Abrir" e 3 botões. Cabe **1,3 serviço por tela**;
  um projeto de 6 serviços pede 5 rolagens.
- **O botão ✕ (remover serviço) é o maior e mais chamativo do card**, vermelho
  cheio, no meio da fileira. O mais destrutivo virou o mais fácil de tocar.
- Nome/id do container (`rp_5as15m7h_worker`, `0f02739011bf`) são detalhe técnico
  que raramente importa no celular, e cada um tem sua linha + botão de copiar.

---

## 2. Princípios da proposta

1. **No celular o app é de consulta + ações pontuais.** Ver o que está de pé, o que
   falhou, ler log, dar deploy/restart. Edição pesada (variáveis, secrets, jobs,
   novo serviço) continua possível, mas não precisa estar na primeira tela.
2. **Uma coluna, rolagem vertical só.** Nada de tabela larga; nada de linha com
   mais de 2 botões.
3. **Ação destrutiva nunca em destaque.** Vermelho cheio só dentro de um menu `⋯`
   ou de uma confirmação, nunca como botão primário de card/topbar.
4. **Navegação pelo polegar:** as telas principais embaixo, as secundárias numa
   folha "Mais".
5. **Sem mudar o daemon nem a lógica Luau** além de formatar dados para a nova
   forma. É trabalho de `.gv` + GSS + `format/*.luau`.

Breakpoint alvo: **`max-width: 560`** (o mesmo de `format/util.luau` e
`app.gss`). Entre 560 e 900 continua o layout atual de tablet.

---

## 3. Nova casca no celular

```
┌──────────────────────────────────┐
│ Deployments          ● prod  ⋯   │  ← topbar: título da tela, daemon, menu
├──────────────────────────────────┤
│                                  │
│          (conteúdo)              │
│                                  │
├──────────────────────────────────┤
│  ●      ▶      ⚡      ◧      ≡   │  ← barra inferior fixa
│ Ativos Deploys Engine Projetos Mais│
└──────────────────────────────────┘
```

### 3.1 Topbar
- **Esquerda:** título da tela atual (`Deployments`, `Chiquitos`, …). Em telas
  "filhas" (projeto, serviço) vira `‹ Projetos` / `‹ Chiquitos` — o botão de
  voltar sai da barra de ações do projeto e vem para cá.
- **Direita:** um ponto de status do daemon (verde/amarelo/vermelho; toque mostra
  `connected_server` e versão) e um `⋯` com **Parar tudo**, **Desconectar** e
  **Idioma**.
- "Parar tudo" no `⋯` continua com a confirmação que já existe; some da topbar.
- A busca (`topbar__search`) já some < 760px; no celular vira um ícone 🔍 dentro
  das telas que têm lista (Deployments, Projetos), não na topbar.

### 3.2 Barra inferior (substitui o trilho)
- 4 destinos fixos + **Mais**: **Ativos** (running), **Deploys** (deployments),
  **Engine** (deploy_engine), **Projetos** (projects/project_services/service).
- Ícone + rótulo curto sempre (o rótulo é o que falta hoje).
- **Mais** abre uma folha de baixo para cima (ou a própria `drawer`, vinda da
  direita/baixo) com: Monitoramento, Agendamentos, Ingress, Runtime, Configurações
  (com o ponto de atualização) e Suporte.
- O `drawer` lateral **não aparece** < 560px (nem trilho nem ☰). Acima disso, nada
  muda.

Implementação: um componente novo `components/bottom_nav.component.gv`, reusando
os mesmos `target`/`action` do `NavItem`, mostrado só por `@media (max-width: 560)`
(e o `drawer` + `topbar__menu` escondidos no mesmo breakpoint). O item "Mais"
destaca quando `@view` está em qualquer uma das telas secundárias.

---

## 4. Telas

### 4.1 Deployments → lista de cartões compactos, agrupada

```
Deployments                    🔍  ✕
[ Todos 15 ] [ Live 4 ] [ Building 11 ] [ Falhos 0 ]   ← chips (filtro)

CHIQUITOS                                   ← cabeçalho de grupo = projeto
┌──────────────────────────────────┐
│ db              ● LIVE        1s │
│ broker          ● LIVE       16s │
│ s3              ● LIVE       10s │
│ cache           ● LIVE       21s │
│ db              ● BUILDING  3h11 │
│ …                                │
└──────────────────────────────────┘
```

- **Projeto vira cabeçalho de grupo**, não coluna. Resolve o `Chiquit…` repetido.
- Linha = **serviço · estado · duração**, 3 colunas que cabem em 340px; toque na
  linha abre o serviço (o mesmo `TableLink`). Tocar no cabeçalho do grupo abre o
  projeto.
- **Chips de estado** no topo filtram (Todos/Live/Building/Falhos), com contagem.
  Substituem também os StatCards de "Status", que hoje somem.
- Duração formatada para caber em 6 caracteres: `21s`, `3m`, `3h11`, `2d16h`
  (hoje `191m …` / `3850m…`). É mudança em `format/time.luau`.
- "Limpar parados/falhos" vira um ícone na linha do título (o `✕` que já existe em
  `page-head__clear--compact`), com confirmação.
- Título sem subtítulo no celular (o subtítulo é decorativo).

Dados: o `deployments` já traz `project`/`project_id`; agrupar é um passo a mais
em `format/dashboard.luau` (gera `deployments_groups = [{project, project_id,
items}]`). A tabela atual continua sendo usada > 560px.

### 4.2 Deploy Engine

```
Deploy Engine
┌────────┬────────┬────────┐
│ Ativos │ OK 24h │Falha 24h│   ← 3 números, uma linha (os 5 StatCards → 3)
│   0    │   7    │   0    │
└────────┴────────┴────────┘
[ Fila 0 ][ Executando 0 ][ Histórico 7 ]    ← abas numa linha só, rótulo curto
```

- Os StatCards voltam no celular como uma faixa de 3 números (sem Total e Uptime).
- Abas com rótulo curto numa linha só ("Histórico" em vez de "Histórico 24h").
- Painel vazio sem título duplicado: só "Nenhum deploy na fila." + "Pausar fila"
  alinhado à direita.
- Itens do histórico: mesmo formato de linha compacta de §4.1
  (serviço · resultado · quando).

### 4.3 Projeto → cabeçalho e abas

```
‹ Projetos                       ⋯     ← topbar
Chiquitos                        ✎
Descrição (opcional)
[ Serviços 6 ][ Vars 38 ][ Secrets 16 ][ Jobs 2 ]   ← rolagem horizontal, ok
```

- A barra de ações (`proj-bar__actions`) sai do cabeçalho. Vai para:
  - **Deploy do projeto:** botão primário fixo no rodapé da aba Serviços
    ("Deploy de todos"), acima da barra inferior;
  - **Novo serviço:** botão `+` no fim da lista de serviços (ou FAB);
  - **Reordenar serviços** e **Remover projeto** (vermelho): no `⋯` da topbar.
- Título/descrição continuam editáveis no lugar, mas o subtítulo vazio
  "Descrição (opcional)" não aparece no celular quando vazio (mostra só no modo
  edição, ao tocar no ✎) — economiza uma linha.
- Abas: "Variáveis" → "Vars" no celular para caberem as 4 sem rolar.

### 4.4 Projeto → card de serviço compacto

De ~560px para ~110px de altura (≈ 5 serviços por tela em vez de 1,3):

```
┌──────────────────────────────────┐
│ worker :80            ● Running  │
│ ◐ quente   CPU 0.0%   MEM 10 MB  │
│                       ■   ⋯      │
└──────────────────────────────────┘
```

- **Linha 1:** nome, porta, estado (badge).
- **Linha 2:** badges secundários (quente/frio, "deploy pendente") e CPU/MEM inline
  em texto pequeno — não precisam de número de 18pt.
- **Linha 3 (ou à direita da 2):** **■ Parar** (ou **▶ Iniciar** se parado) e
  **⋯** com Exportar, Copiar nome do container, Copiar id e **Remover** (vermelho,
  com confirmação).
- **Tocar no card inteiro = Abrir.** Sai o botão "Abrir ›" de largura total.
- Nome e id do container saem do card no celular; continuam no detalhe do serviço
  e no `⋯` (copiar).
- O ✕ vermelho cheio deixa de existir no card.

Implementação: uma variante `service_card--compact` no próprio
`components/service_card.component.gv` (dois blocos alternados por `@media
(max-width: 560)`, como já é feito com `service__actions--full/--compact`). A grade
passa a 1 coluna < 560px (`dashboard.luau` já decide `grid_cols` pela largura).

---

## 5. Padrões reaproveitáveis (para as demais telas depois)

| Padrão | Onde nasce | Onde reaproveitar |
|---|---|---|
| Barra inferior + "Mais" | casca | — |
| Topbar com título/voltar + `⋯` | casca | todas as telas filhas |
| Lista agrupada com chips de filtro | Deployments | Runtime → containers/imagens/volumes, Ingress, Agendamentos |
| Linha compacta de 3 colunas | Deployments | Histórico do Engine, Jobs |
| Card compacto (toque = abrir, ações no `⋯`) | Serviços | Projetos (`project_card`), Ativos (`running_card`) |
| Faixa de 3 números | Deploy Engine | Monitoramento, Ativos |
| Ação destrutiva só no `⋯` + confirmação | todos | regra geral |

---

## 6. Fora do layout, mas visível nas capturas

- **Deployments em BUILDING há 191m, 203m e 3850m** (2,7 dias) junto com os mesmos
  serviços já LIVE. Parece que tentativas antigas nunca recebem estado final no
  daemon (ficam órfãs quando um deploy novo do mesmo serviço sobe). Vale abrir
  issue no `rustploy-daemon`: marcar como `superseded`/`failed` quando um deploy
  mais novo do mesmo serviço fica LIVE, ou quando o daemon reinicia. O
  "Limpar parados/falhos" provavelmente não pega esses porque não estão parados
  nem falhos.

---

## 7. Ordem sugerida de implementação

1. **Casca:** barra inferior, topbar nova, esconder trilho/☰ < 560px, mover
   "Parar tudo"/"Desconectar" para o `⋯`. (Maior ganho, isolado.)
2. **Card de serviço compacto** + grade de 1 coluna.
3. **Deployments em lista agrupada** + formato curto de duração.
4. **Cabeçalho do projeto** (ações para `⋯`/rodapé).
5. **Deploy Engine** (faixa de números, abas curtas).
6. Aplicar os padrões de §5 nas telas restantes.

Cada passo: validar com `tests/tela/render.test.luau` numa janela de 390×844 e
conferir no navegador do celular (o caso das capturas: a largura lógica que o
`@media` recebe ali precisa ser confirmada antes do passo 1, já que o
`page-head__clear--compact` de 860px não entrou em ação nas capturas).

## 8. Perguntas em aberto

- Quais 4 telas vão fixas na barra inferior? A proposta é Ativos, Deploys, Engine,
  Projetos. Se Monitoramento for mais usado que o Engine no celular, troca.
- Novo serviço no celular: FAB `+` ou item no fim da lista?
- Vale esconder Variáveis/Secrets/Jobs no celular (somente leitura) ou manter a
  edição completa?
