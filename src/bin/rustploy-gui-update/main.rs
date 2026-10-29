//! `rustploy-gui-update` — o helper root que instala o `.deb` **assinado** do app desktop.
//!
//! O app roda como o usuário e não pode instalar um pacote. Quando a pessoa clica em
//! "Atualizar app", ele baixa o `.deb` e a `.minisig` para o próprio cache e roda, via `pkexec`
//! (o diálogo de senha nativo do sistema):
//!
//! ```text
//! pkexec /usr/libexec/rustploy-gui-update install <deb> <minisig>
//! ```
//!
//! Diferente do helper do daemon, **não fica residente**: existe só durante o `pkexec`, e nada
//! roda como root entre uma atualização e outra. A superfície é a mesma, mínima:
//!
//! - **não abre conexão de rede** (quem baixa é o app);
//! - só instala o pacote `rustploy-gui`, só se assinado pela chave do projeto (embutida) e nunca
//!   uma versão que não seja mais nova que a instalada;
//! - só lê arquivos direto do diretório de cache **do usuário que chamou** (`PKEXEC_UID`, resolvido
//!   na tabela de usuários; o `HOME` do ambiente não é confiável) e copia para um diretório só do
//!   root antes de conferir;
//! - nenhum argumento chega a um shell.
//!
//! Saída: uma linha JSON com o resultado em `stdout` e código `0` se instalou, `1` se recusou ou
//! falhou (a causa em `stderr`), `2` se foi chamado errado.

//!
//! **No Windows** o mesmo binário é outro programa, sem privilégio nenhum: troca a pasta do app
//! portátil pelo zip assinado da release e reabre o app (`portable.rs`).

// Sem janela de console no Windows: o app o roda em segundo plano.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(unix)]
mod helper;
// Compilado também nos testes do Linux: a troca da pasta é só `std::fs` e dá para testar aqui.
#[cfg(any(windows, test))]
#[cfg_attr(not(windows), allow(dead_code))]
mod portable;

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    helper::run()
}

#[cfg(windows)]
fn main() -> std::process::ExitCode {
    portable::run()
}
