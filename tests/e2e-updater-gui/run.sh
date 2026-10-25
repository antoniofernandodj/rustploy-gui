#!/usr/bin/env bash
# Teste de ponta a ponta do helper do app desktop (`rustploy-gui-update`) via `pkexec`, com a política
# do polkit, o dpkg e as permissões de verdade, num contêiner Podman com systemd.
#
# O que roda é o helper REAL (compilado aqui, com uma chave de teste no lugar da de produção, ver
# `trusted_keys()` em src/bin/rustploy-gui-update.rs) e a política REAL de packaging/. O "app" é um
# script. Uma regra de polkit SÓ DE TESTE autoriza o usuário `pessoa` sem senha.
#
#   tests/e2e-updater-gui/run.sh          # roda tudo (poucos minutos)
#   KEEP=1 tests/e2e-updater-gui/run.sh   # deixa o contêiner de pé para investigar
#
# Pré-requisitos: podman, minisign, dpkg-deb e o toolchain do Rust.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUI="$(cd "$HERE/../.." && pwd)"                      # rustploy-gui/
WORK="$(mktemp -d)"
CONTAINER="rustploy-e2e-updater-gui"
IMAGE="localhost/rustploy-e2e-updater-gui:latest"
FAILED=0

cleanup() {
    if [ -z "${KEEP:-}" ]; then podman rm -f "$CONTAINER" >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; FAILED=$((FAILED + 1)); }
check()    { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: esperado [$2], veio [$3]"; fi; }
contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: [$2] não aparece em [$3]" ;; esac; }
sh_in() { podman exec "$CONTAINER" sh -c "$1"; }

say "chaves de teste (descartáveis)"
minisign -G -W -f -p "$WORK/e2e.pub" -s "$WORK/e2e.key" >/dev/null
minisign -G -W -f -p "$WORK/other.pub" -s "$WORK/other.key" >/dev/null
E2E_PUBLIC_KEY="$(sed -n 2p "$WORK/e2e.pub")"

say "compilando o helper com a chave de teste"
( cd "$GUI" && RUSTPLOY_E2E_TRUSTED_KEY="$E2E_PUBLIC_KEY" cargo build --bin rustploy-gui-update ${CARGO_ARGS:-} >/dev/null 2>&1 )
HELPER="$GUI/target/debug/rustploy-gui-update"
[ -x "$HELPER" ] || { echo "helper não compilou"; exit 1; }
pass "helper compilado"

# make_deb <arquivo> <pacote> <versão> <normal|postinst-quebrado> <chave>
make_deb() {
    local out="$1" package="$2" version="$3" mode="$4" key="$5" dir
    dir="$(mktemp -d "$WORK/pkg.XXXXXX")"
    mkdir -p "$dir/DEBIAN" "$dir/usr/bin" "$dir/usr/libexec" "$dir/usr/share/polkit-1/actions"
    printf '#!/bin/sh\n# VERSION=%s\necho app %s\n' "$version" "$version" > "$dir/usr/bin/rustploy-gui"
    cp "$HELPER" "$dir/usr/libexec/rustploy-gui-update"
    chmod 755 "$dir/usr/bin/rustploy-gui" "$dir/usr/libexec/rustploy-gui-update"
    cp "$GUI/packaging/br.com.rustploy.gui-update.policy" "$dir/usr/share/polkit-1/actions/"
    chmod 644 "$dir/usr/share/polkit-1/actions/br.com.rustploy.gui-update.policy"   # o cargo-deb grava 644
    printf '#!/bin/sh\nset -e\n' > "$dir/DEBIAN/postinst"
    [ "$mode" = "postinst-quebrado" ] && printf 'echo "postinst de teste falhando" >&2\nexit 1\n' >> "$dir/DEBIAN/postinst"
    chmod 755 "$dir/DEBIAN/postinst"
    cat > "$dir/DEBIAN/control" <<CONTROL
Package: $package
Version: $version
Architecture: amd64
Maintainer: e2e <e2e@example.invalid>
Description: pacote de mentira do teste de atualização do app
CONTROL
    dpkg-deb --build --root-owner-group "$dir" "$out" >/dev/null
    minisign -S -s "$key" -t "package=$package version=$version arch=amd64" -m "$out" >/dev/null
}

say "montando os pacotes"
mkdir -p "$WORK/debs"
make_deb "$WORK/debs/v1.deb"        rustploy-gui 1.0.0-1 normal "$WORK/e2e.key"
make_deb "$WORK/debs/v2.deb"        rustploy-gui 1.1.0-1 normal "$WORK/e2e.key"
make_deb "$WORK/debs/bad-sig.deb"   rustploy-gui 1.2.0-1 normal "$WORK/other.key"
make_deb "$WORK/debs/daemon.deb"    rustployd    1.3.0-1 normal "$WORK/e2e.key"
make_deb "$WORK/debs/downgrade.deb" rustploy-gui 0.9.0-1 normal "$WORK/e2e.key"
make_deb "$WORK/debs/broken.deb"    rustploy-gui 1.4.0-1 postinst-quebrado "$WORK/e2e.key"
make_deb "$WORK/debs/v5.deb"        rustploy-gui 1.5.0-1 normal "$WORK/e2e.key"
pass "7 pacotes assinados"

say "subindo o contêiner com systemd e polkit"
podman build -q -t "$IMAGE" -f "$HERE/Containerfile" "$HERE" >/dev/null
podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
podman run -d --name "$CONTAINER" --systemd=always "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
    state="$(podman exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in running|degraded) break ;; esac
    sleep 1
done
check "systemd do contêiner subiu" "ok" "$([ "$state" = running ] || [ "$state" = degraded ] && echo ok || echo "$state")"
podman cp "$WORK/debs/v1.deb" "$CONTAINER:/tmp/v1.deb"
sh_in 'dpkg -i /tmp/v1.deb >/tmp/dpkg-v1.log 2>&1 || { cat /tmp/dpkg-v1.log; exit 1; }'

# O polkitd sobe à mão (a unit está mascarada na imagem de teste). Sem ele o pkexec não acha a autoridade.
podman exec -d "$CONTAINER" sh -c '/usr/lib/polkit-1/polkitd --no-debug >/tmp/polkitd.log 2>&1'
sleep 3

installed_version() { sh_in "dpkg-query -W -f='\${Version}' rustploy-gui"; }
binary_marker()     { sh_in "grep -o 'VERSION=[^ ]*' /usr/bin/rustploy-gui"; }

# Entrega o pacote como o app faria (no cache do usuário) e roda o helper por pkexec como `usuário`.
# Devolve "<código de saída>|<stdout+stderr em uma linha>".
run_update() {  # <usuário> <nome> [diretório-do-cache]
    local user="$1" name="$2" dir="${3:-/home/$1/.cache/rustploy-gui/updates}"
    sh_in "rm -rf '$dir'; install -d -o $user -g $user '$dir'"
    podman cp "$WORK/debs/$name.deb" "$CONTAINER:$dir/pkg.deb"
    podman cp "$WORK/debs/$name.deb.minisig" "$CONTAINER:$dir/pkg.deb.minisig"
    sh_in "chown $user:$user '$dir'/*"
    local out code
    out="$(podman exec "$CONTAINER" su -s /bin/sh "$user" -c "pkexec /usr/libexec/rustploy-gui-update install '$dir/pkg.deb' '$dir/pkg.deb.minisig' 2>&1; echo CODE=\$?" || true)"
    code="$(printf '%s' "$out" | grep -o 'CODE=[0-9]*' | tail -1 | cut -d= -f2)"
    printf '%s|%s' "$code" "$(printf '%s' "$out" | grep -v '^CODE=' | tr '\n' ' ')"
}

say "G0. a política do polkit foi instalada e está bem formada"
act="$(sh_in 'pkaction --action-id br.com.rustploy.gui-update --verbose 2>&1' || true)"
contains "a ação existe" "br.com.rustploy.gui-update" "$act"
contains "o programa autorizado é só o helper" "/usr/libexec/rustploy-gui-update" "$act"
contains "o padrão pede a senha de administrador" "auth_admin" "$act"

say "G1. caminho feliz via pkexec: v1 -> v2"
r="$(run_update pessoa v2)"; echo "    ${r:0:200}"
check "saiu com 0" "0" "${r%%|*}"
check "versão instalada" "1.1.0-1" "$(installed_version)"
check "o binário do app foi trocado" "VERSION=1.1.0-1" "$(binary_marker)"
contains "o helper imprime o resultado" '"kind":"installed"' "$r"
check "a cópia de trabalho do root foi apagada" "0" "$(sh_in 'ls /var/lib/rustploy-gui-update/staging 2>/dev/null | wc -l')"
check "o helper não deixa processo residente" "0" "$(sh_in 'pgrep -c -x rustploy-gui-up || true')"

say "G2. assinatura de OUTRA chave é recusada"
r="$(run_update pessoa bad-sig)"; echo "    ${r:0:200}"
check "saiu com 1" "1" "${r%%|*}"
contains "pela assinatura" "assinatura inválida" "$r"
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G3. pacote assinado de OUTRO produto (o daemon) é recusado"
r="$(run_update pessoa daemon)"; echo "    ${r:0:200}"
check "saiu com 1" "1" "${r%%|*}"
contains "pelo nome do pacote" "pacote errado" "$r"

say "G4. downgrade é recusado"
r="$(run_update pessoa downgrade)"
check "saiu com 1" "1" "${r%%|*}"
contains "por não ser mais novo" "downgrade" "$r"
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G5. arquivo fora do cache do usuário é recusado"
sh_in 'install -d -o pessoa -g pessoa /home/pessoa/.cache/rustploy-gui/updates'
podman cp "$WORK/debs/v5.deb" "$CONTAINER:/tmp/fora.deb"; podman cp "$WORK/debs/v5.deb.minisig" "$CONTAINER:/tmp/fora.deb.minisig"
out="$(podman exec "$CONTAINER" su -s /bin/sh pessoa -c "pkexec /usr/libexec/rustploy-gui-update install /tmp/fora.deb /tmp/fora.deb.minisig 2>&1; echo CODE=\$?" || true)"
contains "recusa pelo diretório" "pacote recusado" "$out"
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G6. o cache de OUTRO usuário não vale (o diretório vem do PKEXEC_UID, não do ambiente)"
sh_in 'install -d -o outro -g outro /home/outro/.cache/rustploy-gui/updates'
podman cp "$WORK/debs/v5.deb" "$CONTAINER:/home/outro/.cache/rustploy-gui/updates/pkg.deb"
podman cp "$WORK/debs/v5.deb.minisig" "$CONTAINER:/home/outro/.cache/rustploy-gui/updates/pkg.deb.minisig"
out="$(podman exec "$CONTAINER" su -s /bin/sh pessoa -c "HOME=/home/outro pkexec /usr/libexec/rustploy-gui-update install /home/outro/.cache/rustploy-gui/updates/pkg.deb /home/outro/.cache/rustploy-gui/updates/pkg.deb.minisig 2>&1; echo CODE=\$?" || true)"
contains "recusa mesmo com HOME apontando para o outro" "pacote recusado" "$out"
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G7. link simbólico no lugar do pacote é recusado"
sh_in 'rm -rf /home/pessoa/.cache/rustploy-gui/updates; install -d -o pessoa -g pessoa /home/pessoa/.cache/rustploy-gui/updates'
podman cp "$WORK/debs/v5.deb" "$CONTAINER:/tmp/real.deb"; podman cp "$WORK/debs/v5.deb.minisig" "$CONTAINER:/home/pessoa/.cache/rustploy-gui/updates/pkg.deb.minisig"
sh_in 'ln -s /tmp/real.deb /home/pessoa/.cache/rustploy-gui/updates/pkg.deb; chown -h pessoa:pessoa /home/pessoa/.cache/rustploy-gui/updates/*'
out="$(podman exec "$CONTAINER" su -s /bin/sh pessoa -c "pkexec /usr/libexec/rustploy-gui-update install /home/pessoa/.cache/rustploy-gui/updates/pkg.deb /home/pessoa/.cache/rustploy-gui/updates/pkg.deb.minisig 2>&1; echo CODE=\$?" || true)"
contains "recusa o link" "arquivo regular" "$out"
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G8. usuário SEM autorização no polkit não instala nada"
r="$(run_update intruso v5)"; echo "    ${r:0:200}"
case "${r%%|*}" in 0) fail "o intruso conseguiu instalar" ;; *) pass "pkexec negou (código ${r%%|*})" ;; esac
check "nada mudou" "1.1.0-1" "$(installed_version)"

say "G9. postinst que falha: o binário antigo volta"
r="$(run_update pessoa broken)"; echo "    ${r:0:240}"
check "saiu com 1" "1" "${r%%|*}"
contains "a causa do dpkg está na mensagem" "dpkg falhou" "$r"
check "o binário do app voltou ao anterior" "VERSION=1.1.0-1" "$(binary_marker)"

say "G10. uma instalação boa depois das falhas"
r="$(run_update pessoa v5)"
check "saiu com 0" "0" "${r%%|*}"
check "versão instalada" "1.5.0-1" "$(installed_version)"
check "o binário do app foi trocado" "VERSION=1.5.0-1" "$(binary_marker)"

say "resumo"
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mtodos os cenários passaram\033[0m\n'
else
    printf '\033[31m%s verificação(ões) falharam\033[0m\n' "$FAILED"
    exit 1
fi
