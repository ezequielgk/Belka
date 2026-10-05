#!/bin/sh
# belka — runner de tests minimalista (POSIX sh, sin dependencias).
# Cubre: instalacion, checksum, conflictos, rollback, remove, update,
# verify, dry-run, list/search/info (JSON), TUI fallback, resolucion de
# fuente (local/URL/nombre), sync, TTL del cache y modo offline.

BELKA_BIN=$(CDPATH= cd "$(dirname "$0")/../bin" && pwd)/belka
[ -f "$BELKA_BIN" ] || { echo "no se encuentra $BELKA_BIN" >&2; exit 2; }

TESTS_RUN=0
TESTS_FAIL=0
SBOXES=''

t_run() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" > /dev/null 2>&1; then
        printf 'ok   - %s\n' "$1"
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf 'FAIL - %s\n' "$1"
    fi
}

t_eq() {
    # t_eq ACTUAL ESPERADO
    if [ "$1" != "$2" ]; then
        printf '       esperado: [%s]\n       obtenido: [%s]\n' "$2" "$1" >&2
        return 1
    fi
    return 0
}

t_cleanup() {
    for _t_d in $SBOXES; do
        rm -rf "$_t_d"
    done
}
trap t_cleanup 0

t_sandbox() {
    _t_d=$(mktemp -d "${TMPDIR:-/tmp}/mtt.XXXXXX" 2>/dev/null) ||
        _t_d="${TMPDIR:-/tmp}/mtt.$$.$TESTS_RUN"
    if [ ! -d "$_t_d" ]; then
        mkdir -p "$_t_d"
        chmod 700 "$_t_d"
    fi
    SBOXES="$SBOXES $_t_d"
    mkdir -p "$_t_d/home" "$_t_d/xcache" "$_t_d/pkgs" "$_t_d/tmp"
    printf '%s\n' "$_t_d"
}

t_tm() {
    # t_tm [args...] — corre belka aislado. T_ENV="VAR=val ..." inyecta env.
    env -i PATH="$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/xcache" \
        TMPDIR="$T/tmp" ${T_ENV:-} sh "$BELKA_BIN" "$@"
}

t_sha() {
    sha256sum "$1" | awk '{print $1}'
}

# Construye $T/pkgs/$1.tar.gz con raiz unica $2 y archivos "ruta:contenido".
t_mkpkg() {
    _t_out=$1
    _t_root=$2
    shift 2
    _t_src=$T/src/$_t_root
    rm -rf "$T/src"
    mkdir -p "$_t_src"
    for _t_spec do
        _t_path=${_t_spec%%:*}
        _t_content=${_t_spec#*:}
        mkdir -p "$_t_src/$(dirname "$_t_path")"
        printf '%s\n' "$_t_content" > "$_t_src/$_t_path"
        case "$_t_path" in
            bin/*) chmod +x "$_t_src/$_t_path" ;;
        esac
    done
    ( cd "$T/src" && tar -czf "$T/pkgs/$_t_out.tar.gz" "$_t_root" )
}

t_new_index() {
    printf '# belka index v1 (TSV)\n'
}

t_index_add() {
    # t_index_add INDICE NOMBRE VERSION TAR DESC
    _t_idx=$1 _t_n=$2 _t_v=$3 _t_tar=$4 _t_d=$5
    _t_sha=$(t_sha "$_t_tar")
    _t_url="file://$T/pkgs/$(basename "$_t_tar")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_t_n" "$_t_v" "$_t_url" "$_t_sha" "$_t_d" >> "$_t_idx"
}

# --------------------------------------------------------------------------
# 1) Instalacion y verificacion basicas
# --------------------------------------------------------------------------

test_install_ok() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 \
        bin/hello:'#!/bin/sh echo hola-1.0.0' share/doc/demo/readme:'doc 1.0.0'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo app'
    t_tm --index "$T/index.tsv" install demo || return 1

    t_eq "$(cat "$T/home/.local/belka/bin/hello")" '#!/bin/sh echo hola-1.0.0' || return 1
    t_eq "$(cat "$T/home/.local/share/doc/demo/readme")" 'doc 1.0.0' || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/demo/manifest")" 1.0.0 || return 1
    grep -q '^bin/hello$' "$T/home/.local/share/belka/demo/files" || return 1
    grep -q '^name=demo$' "$T/home/.local/share/belka/demo/manifest" || return 1
}

test_install_bad_checksum() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola'
    t_new_index > "$T/index.tsv"
    printf 'demo\t1.0.0\tfile://%s\t%s\tDemo\n' \
        "$T/pkgs/demo-1.0.0.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000" \
        >> "$T/index.tsv"
    t_tm --index "$T/index.tsv" install demo && return 1
    t_eq "$?" 3 || return 1
    [ ! -d "$T/home/.local/share/belka/demo" ] || return 1
    [ ! -e "$T/home/.local/belka/bin/hello" ] || return 1
}

test_install_conflict() {
    T=$(t_sandbox)
    mkdir -p "$T/home/.local/bin"
    printf 'archivo ajeno\n' > "$T/home/.local/belka/bin/hello"
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola demo'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'

    t_tm --index "$T/index.tsv" install demo && return 1
    t_eq "$?" 5 || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/hello")" 'archivo ajeno' || return 1

    # con --force se sobrescribe
    t_tm --index "$T/index.tsv" install -f demo || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/hello")" 'hola demo' || return 1

    # reinstalar sin --force -> conflicto (ya gestionado)
    t_tm --index "$T/index.tsv" install demo && return 1
    t_eq "$?" 5 || return 1
}

test_install_rollback() {
    T=$(t_sandbox)
    # aaa.txt se copia primero (orden LC_ALL=C); lib/zzz.txt choca con un
    # directorio preexistente: fallo a mitad de copia -> rollback.
    t_mkpkg rb-1.0.0 rb-1.0.0 \
        aaa.txt:'contenido aaa' lib/zzz.txt:'contenido zzz'
    # 'lib' como ARCHIVO bloquea el mkdir -p del dirname -> fallo a mitad
    # de la copia (aaa.txt ya copiado) -> rollback
    mkdir -p "$T/home/.local"
    printf 'bloqueo\n' > "$T/home/.local/lib"
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" rb 1.0.0 "$T/pkgs/rb-1.0.0.tar.gz" 'Rollback test'

    t_tm --index "$T/index.tsv" install -f rb && return 1
    t_eq "$?" 4 || return 1
    [ ! -e "$T/home/.local/aaa.txt" ] || return 1
    [ -f "$T/home/.local/lib" ] || return 1
    [ ! -e "$T/home/.local/lib/zzz.txt" ] || return 1
    [ ! -d "$T/home/.local/share/belka/rb" ] || return 1
}

test_remove_ok() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola' share/demo/data.txt:'dato'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    t_tm --index "$T/index.tsv" install demo || return 1

    t_tm remove -f demo || return 1
    [ ! -e "$T/home/.local/belka/bin/hello" ] || return 1
    [ ! -e "$T/home/.local/share/demo/data.txt" ] || return 1
    [ ! -d "$T/home/.local/share/belka/demo" ] || return 1
    t_tm remove -f demo && return 1
    t_eq "$?" 1 || return 1
}

test_update_and_rollback() {
    T=$(t_sandbox)
    t_mkpkg foo-1.0.0 foo-1.0.0 bin/foo:'version-1.0.0'
    t_mkpkg foo-2.0.0 foo-2.0.0 bin/foo:'version-2.0.0'
    t_new_index > "$T/index-v1.tsv"
    t_index_add "$T/index-v1.tsv" foo 1.0.0 "$T/pkgs/foo-1.0.0.tar.gz" 'Foo'
    t_new_index > "$T/index-v2.tsv"
    t_index_add "$T/index-v2.tsv" foo 2.0.0 "$T/pkgs/foo-2.0.0.tar.gz" 'Foo'

    t_tm --index "$T/index-v1.tsv" install foo || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/foo")" 'version-1.0.0' || return 1

    t_tm --index "$T/index-v2.tsv" update foo || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/foo")" 'version-2.0.0' || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/foo/manifest")" 2.0.0 || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/foo/manifest.bak")" 1.0.0 || return 1

    t_tm --index "$T/index-v2.tsv" update foo || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/foo")" 'version-2.0.0' || return 1

    t_tm rollback foo || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/foo")" 'version-1.0.0' || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/foo/manifest")" 1.0.0 || return 1
}

test_update_all_summary() {
    T=$(t_sandbox)
    t_mkpkg a-1.0.0 a-1.0.0 bin/a:'a-1'
    t_mkpkg b-1.0.0 b-1.0.0 bin/b:'b-1'
    t_new_index > "$T/i1.tsv"
    t_index_add "$T/i1.tsv" a 1.0.0 "$T/pkgs/a-1.0.0.tar.gz" 'A'
    t_index_add "$T/i1.tsv" b 1.0.0 "$T/pkgs/b-1.0.0.tar.gz" 'B'
    t_tm --index "$T/i1.tsv" install a || return 1
    t_tm --index "$T/i1.tsv" install b || return 1

    t_mkpkg a-2.0.0 a-2.0.0 bin/a:'a-2'
    t_new_index > "$T/i2.tsv"
    t_index_add "$T/i2.tsv" a 2.0.0 "$T/pkgs/a-2.0.0.tar.gz" 'A'
    t_index_add "$T/i2.tsv" b 1.0.0 "$T/pkgs/b-1.0.0.tar.gz" 'B'

    # el resumen va a stderr por diseño
    _t_out=$(t_tm --index "$T/i2.tsv" update --all 2>&1) || return 1
    printf '%s\n' "$_t_out" | grep -q 'actualizados=1' || return 1
    printf '%s\n' "$_t_out" | grep -q 'al_dia=1' || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/a")" 'a-2' || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/b")" 'b-1' || return 1
}

test_verify() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    t_tm --index "$T/index.tsv" install demo || return 1

    t_tm verify demo || return 1
    rm "$T/home/.local/belka/bin/hello"
    t_tm verify demo && return 1
    t_eq "$?" 3 || return 1
}

test_dry_run() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    t_tm --index "$T/index.tsv" install --dry-run demo || return 1
    [ ! -e "$T/home/.local/belka/bin/hello" ] || return 1
    [ ! -d "$T/home/.local/share/belka/demo" ] || return 1
}

test_list_search_info() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Aplicacion de demostracion'
    t_index_add "$T/index.tsv" other 3.1.4 "$T/pkgs/demo-1.0.0.tar.gz" 'Otra cosa'
    t_tm --index "$T/index.tsv" install demo || return 1

    _t_out=$(t_tm list) || return 1
    printf '%s\n' "$_t_out" | grep -q 'demo' || return 1

    _t_out=$(t_tm list --json) || return 1
    printf '%s\n' "$_t_out" | grep -q '"name":"demo"' || return 1

    _t_out=$(t_tm --index "$T/index.tsv" search demo) || return 1
    printf '%s\n' "$_t_out" | grep -q 'demo' || return 1

    _t_out=$(t_tm --index "$T/index.tsv" search zzz-no-existe) || return 1
    [ -z "$_t_out" ] || return 1

    _t_out=$(t_tm --index "$T/index.tsv" info demo) || return 1
    printf '%s\n' "$_t_out" | grep -q '1.0.0' || return 1

    t_tm --index "$T/index.tsv" info no-existe && return 1
    t_eq "$?" 1 || return 1
}

test_local_file_install() {
    T=$(t_sandbox)
    t_mkpkg localapp-0.1 localapp-0.1 bin/localapp:'local-0.1'
    t_tm install "$T/pkgs/localapp-0.1.tar.gz" || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/localapp")" 'local-0.1' || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/localapp-0.1/manifest")" local || return 1
}

test_tui_fallback() {
    T=$(t_sandbox)
    if command -v fzf >/dev/null 2>&1; then
        printf '       (fzf instalado; se omite test del fallback)\n' >&2
        return 0
    fi
    t_tm </dev/null || return 1
    printf '0\n' | t_tm >/dev/null 2>&1 || return 1
}

test_cli_errors() {
    T=$(t_sandbox)
    t_tm badcmd && return 1
    t_eq "$?" 1 || return 1
    t_tm --help >/dev/null 2>&1 || return 1
    t_tm --version >/dev/null 2>&1 || return 1
    # install sin indice configurado -> rc 1 (el URL default contiene <user>)
    t_tm install algo && return 1
    t_eq "$?" 1 || return 1
}

# --------------------------------------------------------------------------
# 2) Sistema de indice: resolucion de fuente, sync, TTL, offline
# --------------------------------------------------------------------------

test_source_resolution_url() {
    T=$(t_sandbox)
    t_mkpkg web-1.0.0 web-1.0.0 bin/web:'web-1'
    # URL directa (file://): sin indice, sin nombre en el indice
    t_tm install "file://$T/pkgs/web-1.0.0.tar.gz" || return 1
    t_eq "$(cat "$T/home/.local/belka/bin/web")" 'web-1' || return 1
    t_eq "$(awk -F= '/^version=/ {print $2}' "$T/home/.local/share/belka/web-1.0.0/manifest")" direct || return 1
    # el nombre se deriva del basename del URL
    [ -f "$T/home/.local/share/belka/web-1.0.0/manifest" ] || return 1
}

test_sync() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/demo:'v1'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'

    # sync desde URL file:// crea el cache
    t_tm --index "file://$T/index.tsv" sync || return 1
    _t_cache=$T/xcache/belka/index/packages.tsv
    [ -f "$_t_cache" ] || return 1
    grep -q 'demo' "$_t_cache" || return 1

    # fuente local: sync es no-op exitoso
    t_tm --index "$T/index.tsv" sync || return 1

    # cambio la fuente y re-sync: el cache se actualiza
    t_mkpkg demo-2.0.0 demo-2.0.0 bin/demo:'v2'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 2.0.0 "$T/pkgs/demo-2.0.0.tar.gz" 'Demo'
    t_tm --index "file://$T/index.tsv" sync || return 1
    grep -q '2.0.0' "$_t_cache" || return 1

    # sync sin indice configurado -> rc 1
    t_tm sync && return 1
    t_eq "$?" 1 || return 1
}

test_ttl_and_offline() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/demo:'v1'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    t_tm --index "file://$T/index.tsv" sync || return 1
    _t_cache=$T/xcache/belka/index/packages.tsv

    # la fuente pasa a 2.0.0; el cache fresco (TTL 24h) sigue sirviendo 1.0.0
    t_mkpkg demo-2.0.0 demo-2.0.0 bin/demo:'v2'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 2.0.0 "$T/pkgs/demo-2.0.0.tar.gz" 'Demo'
    _t_out=$(t_tm --index "file://$T/index.tsv" search demo 2>&1) || return 1
    printf '%s\n' "$_t_out" | grep -q '1.0.0' || return 1
    printf '%s\n' "$_t_out" | grep -q '2.0.0' && return 1

    # TTL=0 -> refresco automatico: ahora se ve 2.0.0
    _t_out=$(T_ENV="BELKA_INDEX_TTL=0" t_tm --index "file://$T/index.tsv" search demo 2>&1) || return 1
    printf '%s\n' "$_t_out" | grep -q '2.0.0' || return 1

    # fuente vuelve a 1.0.0 + TTL=0 + --offline: se sirve el cache (2.0.0)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/demo:'v1'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    _t_out=$(T_ENV="BELKA_INDEX_TTL=0" t_tm --offline --index "file://$T/index.tsv" search demo 2>&1) || return 1
    printf '%s\n' "$_t_out" | grep -q '2.0.0' || return 1

    # offline sin cache -> rc 2 (misma familia de error de descarga)
    T=$(t_sandbox)
    t_tm --offline --index "file://$T/no-existe.tsv" search demo && return 1
    t_eq "$?" 2 || return 1
}

test_list_available_marker() {
    T=$(t_sandbox)
    t_mkpkg demo-1.0.0 demo-1.0.0 bin/hello:'hola'
    t_mkpkg demo-2.0.0 demo-2.0.0 bin/hello:'hola-2'
    t_new_index > "$T/index.tsv"
    t_index_add "$T/index.tsv" demo 1.0.0 "$T/pkgs/demo-1.0.0.tar.gz" 'Demo'
    t_index_add "$T/index.tsv" other 9.9.9 "$T/pkgs/demo-2.0.0.tar.gz" 'Otra'
    t_tm --index "$T/index.tsv" install demo || return 1

    # columna "disponible": demo esta en el indice, other no esta instalado
    _t_out=$(t_tm --index "$T/index.tsv" list) || return 1
    _t_line=$(printf '%s\n' "$_t_out" | grep '^demo')
    t_eq "$(printf '%s\n' "$_t_line" | awk '{print $2}')" 1.0.0 || return 1
    t_eq "$(printf '%s\n' "$_t_line" | awk '{print $3}')" 1.0.0 || return 1

    # en JSON aparece available_version
    _t_out=$(t_tm --index "$T/index.tsv" list --json) || return 1
    printf '%s\n' "$_t_out" | grep -q '"available_version":"1.0.0"' || return 1
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

for _t in \
    test_install_ok \
    test_install_bad_checksum \
    test_install_conflict \
    test_install_rollback \
    test_remove_ok \
    test_update_and_rollback \
    test_update_all_summary \
    test_verify \
    test_dry_run \
    test_list_search_info \
    test_local_file_install \
    test_tui_fallback \
    test_cli_errors \
    test_source_resolution_url \
    test_sync \
    test_ttl_and_offline \
    test_list_available_marker
do
    t_run "$_t"
done

printf '\n%d tests, %d fallos\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
