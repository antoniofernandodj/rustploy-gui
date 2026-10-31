--!strict
-- Definições dos globais que o motor glacier-ui injeta no interpretador Luau
-- em runtime (não existem como arquivo). Consumido só pelo type-checker
-- (luau-lsp): o mlua ignora tipos/anotações em runtime. Carregue com
--   luau-lsp analyze --definitions=views/scripts/glacier.d.luau ...

export type FetchResult = {
    ok: boolean,
    status: number,
    body: string,
    error: string,
}

export type StreamHandle = {
    id: number,
    close: (self: StreamHandle) -> any,
    send: (self: StreamHandle, text: string) -> any,
}

-- Contexto global do motor: chave→valor string (o motor coage tudo p/ string).
declare ctx: { [string]: string }

-- Valor do on_change/on_toggle/ação-com-sufixo (nil quando a ação não traz
-- valor).
declare value: string?

-- Tamanho atual da janela em px lógicos (o que também alimenta @media no GSS).
export type Viewport = {
    width: number,
    height: number,
}
declare function viewport(): Viewport

-- HTTP, ou leitura de arquivo local quando a URL começa com `file://`
-- (glacier-ui 0.49+): devolve o mesmo FetchResult, com o conteúdo no `body`.
-- `opts`: method, headers, body, body_base64, body_file (caminho: o corpo é o conteúdo cru do arquivo), timeout (ms), response ("base64"),
-- `max_redirects` (segue até N redirecionamentos; padrão 0), `max_bytes` (teto do corpo da resposta),
-- `cookies` (false = ignora o jar), `signal` (um `abort_controller()`),
-- `on_progress` (function(p: FetchProgress): envio e recebimento, ver abaixo),
-- `multipart` ({ fields = {…}, files = { { name, path, filename?, content_type? } } }).
-- `phase` é "upload" (corpo do pedido) ou "download" (corpo da resposta); `total` é o
-- tamanho do corpo enviado / o Content-Length da resposta (nil se não houver).
export type FetchProgress = { phase: string, done: number, total: number?, fraction: number? }

declare function fetch(url: string, opts: any?): FetchResult

-- Cancelamento: `fetch(url, { signal = ctl })` termina com `ok = false`,
-- `error = "cancelado"` quando `ctl:abort()` é chamado.
export type AbortController = {
    abort: (self: AbortController) -> (),
    aborted: (self: AbortController) -> boolean,
}
declare function abort_controller(): AbortController

-- Esvazia o jar de cookies (do host dado, ou de todos sem argumento).
declare function clear_cookies(host: string?): ()

-- Baixa um recurso remoto direto para um arquivo local, em bytes crus (sem
-- passar pelo texto/UTF-8 do `fetch`, que corromperia um binário). `body` do
-- retorno vem sempre vazio — o conteúdo foi para `path`, não para a resposta.
-- É o caminho certo para cachear uma imagem remota e exibi-la com
-- `<image source="{path}">`.
declare function download_file(url: string, path: string, opts: any?): FetchResult

-- ── http: cliente HTTP reutilizável sobre `fetch` ─────────────────────────
-- `http(base_url?, opts?)` devolve um objeto com base_url / headers / query /
-- timeout / retries de base, interceptors de requisição e resposta, e error
-- handlers. Todo método de chamada SUSPENDE, como o `fetch` cru.

export type HttpResponse = {
    ok: boolean,
    status: number,
    body: string,
    error: string,
    -- Corpo já decodificado, ou `nil` se não era JSON.
    json: any,
    -- `{ method, url }` da chamada que produziu esta resposta.
    request: { method: string, url: string },
}

export type HttpRequest = {
    method: string,
    path: string,
    headers: { [string]: any },
    query: { [string]: any },
    body: any,
    timeout: number?,
}

export type HttpError = {
    status: number,
    error: string,
    url: string,
    method: string,
    attempt: number,
    body: string,
}

export type HttpOptions = {
    headers: { [string]: any }?,
    query: { [string]: any }?,
    timeout: number?, -- ms, por requisição
    retries: number?, -- tentativas EXTRAS em falha de rede / 429 / 5xx
    retry_on: ((res: HttpResponse) -> boolean)?, -- sobrescreve o critério padrão
    cookies: boolean?, -- false = este cliente ignora o jar de cookies
}

export type HttpRequestSpec = {
    method: string?,
    path: string?,
    url: string?, -- apelido de `path`; uma URL absoluta ignora a base_url
    headers: { [string]: any }?,
    query: { [string]: any }?,
    body: any,
    body_file: string?, -- caminho: o corpo é o conteúdo cru do arquivo (sem base64)
    timeout: number?,
    cookies: boolean?, -- false = esta chamada ignora o jar
    signal: AbortController?, -- cancela a chamada (e ela não é repetida)
    on_progress: ((p: FetchProgress) -> ())?, -- envio/recebimento (~20x/s)
    -- multipart/form-data; o Content-Type (com o boundary) é do motor
    multipart: { fields: { [string]: any }?, files: { { name: string, path: string, filename: string?, content_type: string? } }? }?,
}

export type HttpClient = {
    base_url: string,
    headers: { [string]: any },
    query: { [string]: any },
    timeout: number?,
    retries: number,

    set_cookies: (self: HttpClient, on: boolean) -> HttpClient,
    clear_cookies: (self: HttpClient) -> HttpClient,
    set_base_url: (self: HttpClient, u: string) -> HttpClient,
    set_header: (self: HttpClient, k: string, v: any) -> HttpClient,
    set_headers: (self: HttpClient, t: { [string]: any }) -> HttpClient,
    remove_header: (self: HttpClient, k: string) -> HttpClient,
    set_query: (self: HttpClient, k: string, v: any) -> HttpClient,
    set_timeout: (self: HttpClient, ms: number?) -> HttpClient,
    set_retries: (self: HttpClient, n: number) -> HttpClient,
    set_retry_on: (self: HttpClient, fn: (res: HttpResponse) -> boolean) -> HttpClient,

    on_request: (self: HttpClient, fn: (req: HttpRequest) -> HttpRequest?) -> HttpClient,
    on_response: (self: HttpClient, fn: (res: HttpResponse) -> HttpResponse?) -> HttpClient,
    on_error: (self: HttpClient, fn: (err: HttpError) -> ()) -> HttpClient,

    extend: (self: HttpClient, base_path: string?, opts: HttpOptions?) -> HttpClient,

    request: (self: HttpClient, spec: HttpRequestSpec) -> HttpResponse,
    get: (self: HttpClient, path: string, spec: HttpRequestSpec?) -> HttpResponse,
    delete: (self: HttpClient, path: string, spec: HttpRequestSpec?) -> HttpResponse,
    head: (self: HttpClient, path: string, spec: HttpRequestSpec?) -> HttpResponse,
    options: (self: HttpClient, path: string, spec: HttpRequestSpec?) -> HttpResponse,
    -- O método HTTP QUERY (RFC 10008): seguro e idempotente, com a consulta no corpo.
    query: (self: HttpClient, path: string, body: any, spec: HttpRequestSpec?) -> HttpResponse,
    post: (self: HttpClient, path: string, body: any?, spec: HttpRequestSpec?) -> HttpResponse,
    put: (self: HttpClient, path: string, body: any?, spec: HttpRequestSpec?) -> HttpResponse,
    patch: (self: HttpClient, path: string, body: any?, spec: HttpRequestSpec?) -> HttpResponse,
}

declare function http(base_url: string?, opts: HttpOptions?): HttpClient

-- Timers (glacier-ui 0.62+)
export type Timer = {
    id: number,
    cancel: (self: Timer) -> any,
}

declare function after(ms: number, callback: (() -> ()) | string): Timer
declare function every(ms: number, callback: (() -> ()) | string): Timer
-- Escrita de arquivo local (glacier-ui 0.49+), contraparte do
-- `fetch("file://…")`. Devolve `true` no sucesso, ou `false, mensagem` na
-- falha.
declare function write_file(path: string, contents: string): (boolean, string?)
-- Idem, acrescentando ao fim (glacier-ui 0.49+).
declare function append_file(
    path: string,
    contents: string
): (boolean, string?)
-- Compacta a árvore de `source` (diretório) num `.zip` em `dest` (glacier-ui
-- 0.83+). Síncrono (I/O local). `(true)` no sucesso, `(false, mensagem)` na
-- falha.
declare function zip_dir(source: string, dest: string): (boolean, string?)
-- `.zip` de entradas de TEXTO, sem diretório de staging (glacier-ui 0.123+).
-- `zip_read` entrega todas as entradas; `text` falta em diretório e em
-- conteúdo que não é UTF-8. Quem decide quais nomes aceitar é o chamador.
export type ZipEntry = { name: string, dir: boolean?, text: string? }
declare function zip_write(
    dest: string,
    entries: { ZipEntry }
): (boolean, string?)
declare function zip_read(source: string): {
    ok: boolean,
    entries: { ZipEntry }?,
    error: string?,
}
-- Diálogos nativos do SO (glacier-ui 0.49+). SUSPENDEM a corrotina até o
-- usuário escolher/cancelar; devolvem o caminho escolhido, ou `nil` se
-- cancelou.
-- `opts`: { title?, starting_dir?, default_name?, filters? }.
declare function open_file(opts: any?): string?
declare function save_file(opts: any?): string?
declare function pick_folder(opts: any?): string?

-- Streams de vida longa. NÃO suspendem: registram o stream e devolvem o handle
-- na hora. Cada callback é uma FUNÇÃO (closure e upvalue funcionam) — o motor
-- também aceita o nome de uma função global, como atalho, mas o tipo abaixo
-- guia para a forma boa: o nome obriga o handler a ser global, não fecha sobre
-- nada, e falha em silêncio quando está errado.
export type StreamOptions = {
    headers: { [string]: string }?,
    -- "window" (padrão): vive até a janela fechar. "screen": o motor fecha ao
    -- SAIR da tela dona (depois do `on_leave`), com `on_close`. Abra em
    -- `on_enter`.
    scope: ("screen" | "window")?,
    on_open: (() -> ())?,
    on_message: ((data: string) -> ())?,
    on_error: ((message: string) -> ())?,
    on_close: (() -> ())?,
}
declare function sse(url: string, opts: StreamOptions?): StreamHandle
declare function websocket(url: string, opts: StreamOptions?): StreamHandle
declare function toast(opts: any): ()
-- Notificação nativa do SO (glacier-ui 0.42+): `notify({ title?, body? })` ou
-- `notify("mensagem")`. Diferente de `toast` (efêmero, dentro da janela).
declare function notify(opts: any): ()
-- Copia `text` p/ a área de transferência (glacier-ui 0.126+); não informa
-- sucesso — chame `toast` em seguida.
declare function copy(text: any): ()
declare function confirm(opts: any): boolean

-- Multi-janela (glacier-ui 0.36+/0.37+): abrir janela, mensagear entre janelas
-- e fechar a própria. `on_broadcast(event, payload)` é definido pelo usuário
-- (a janela receptora), não injetado — por isso não é declarado aqui.
declare function open_window(opts: any): ()
declare function broadcast(event: string, payload: any?): ()
declare function close_window(): ()

-- Anexa texto ao fim do <textarea> ligado a `binding` (chave do `value`), de
-- forma incremental (o motor insere no Content sem recriá-lo — preserva
-- scroll).
declare function append_textarea(binding: string, text: string): ()

declare json: {
    decode: (s: string) -> any,
    encode: (v: any) -> string,
    array: <T>(t: { T }) -> { T },
}

-- Persistência local em JSON, análoga ao `localStorage` do browser: sobrevive
-- a um restart do processo (ao contrário do `ctx`, que é só memória). `set`
-- grava qualquer valor JSON-serializável (string, número, booleano, tabela);
-- `get` devolve o valor guardado ou nil; `remove` apaga a chave. No rustploy
-- grava em `~/.local/share/rustploy/.glacier-storage/app.json` (raiz definida
-- no Rust via `GlacierDaemon::storage_dir`, glacier-ui 0.45+).
declare storage: {
    get: (key: string) -> any,
    set: (key: string, value: any) -> (),
    remove: (key: string) -> (),
}

-- Data e hora sobre strings ISO (glacier-ui 0.72+; fuso e epoch na 0.73). Um
-- valor SEM fuso é hora local — é o que `today`/`now` devolvem e o que o
-- `<timeedit>` guarda; um valor COM fuso (`2026-07-06T12:34:56Z`, `...-03:00`,
-- fração de segundo opcional) usa o dele. É esse segundo formato que o daemon
-- manda em todo `started_at`/`created_at`, e `to_local` é o que o traz para a
-- hora de parede da tela. Ver `fmt/time.luau`.
export type DateDelta = {
    years: number?,
    months: number?,
    days: number?,
    hours: number?,
    minutes: number?,
    seconds: number?,
}

declare date: {
    today: () -> string,
    now: (segundos: boolean?) -> string,
    time: (segundos: boolean?) -> string,
    parse: (iso: string) -> { [string]: number }?,
    valid: (iso: string) -> boolean,
    weekday: (iso: string) -> number?,
    date_of: (iso: string) -> string?,
    time_of: (iso: string) -> string?,
    days_in_month: (ano: number, mes: number) -> number,
    compare: (a: string, b: string) -> number?,
    is_before: (a: string, b: string) -> boolean,
    is_after: (a: string, b: string) -> boolean,
    add: (iso: string, delta: DateDelta?) -> string?,
    diff: (a: string, b: string) -> number?,
    diff_seconds: (a: string, b: string) -> number?,
    format: (iso: string, fmt: string) -> string?,
    epoch: (iso: string) -> number?,
    from_epoch: (segundos: number, utc: boolean?) -> string?,
    to_local: (iso: string) -> string?,
    to_utc: (iso: string) -> string?,
}

-- Ponte nativa do "Atualizar app" (src/app/updater.rs, registrada por `GlacierDaemon::lua_extension`).
-- Nenhuma destas funções instala algo sozinha: quem instala é o helper root, via pkexec, e só
-- aceita um pacote assinado pela chave do projeto. Em testes (`glacier test`) o global é nil.
export type AppUpdateInfo = {
    version: string,
    -- "deb", "zip" (Windows, instalado pelo install.ps1) ou "other".
    install_kind: string,
    can_update: boolean,
    -- `std::env::consts::OS`: "linux", "windows"…
    os: string,
}

export type AppUpdatePlan = {
    tag: string,
    latest_version: string,
    html_url: string,
    is_update_available: boolean,
    -- O pacote deste jeito de instalar: o `.deb` ou, no Windows, o zip.
    deb_url: string?,
    deb_name: string?,
    signature_url: string?,
}

declare app_update: {
    info: () -> AppUpdateInfo,
    plan: (release_json: string) -> (AppUpdatePlan?, string?),
    -- Baixa (com progresso), autentica (pkexec) e instala numa thread; volta na hora.
    install_start: (
        deb_url: string,
        signature_url: string,
        deb_name: string
    ) -> (boolean, string?),
    -- `ok`/`message` só aparecem depois do fim; `total`/`percent` só com Content-Length.
    install_status: () -> {
        running: boolean,
        phase: string,
        done: number,
        total: number?,
        percent: number?,
        ok: boolean?,
        message: string?,
    },
    install_cancel: () -> (),
    restart: () -> string?,
    -- Windows: o resultado da troca feita antes desta janela abrir (`nil` se não houve).
    last_result: () -> (boolean?, string?),
}?
