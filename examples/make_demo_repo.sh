#!/bin/sh
# Genera un repositorio local de ejemplo con dos versiones de 'foo' y sus
# indices TSV, para probar install/update/rollback/TUI sin red.
# Uso: sh examples/make_demo_repo.sh [DIR]   (defecto: ./demo-repo)

set -eu

DIR=${1:-./demo-repo}
mkdir -p "$DIR"

mkver() {
    _v=$1
    _d=$DIR/build/foo-$_v
    rm -rf "$DIR/build"
    mkdir -p "$_d/bin" "$_d/share/doc/foo"
    printf '#!/bin/sh\necho foo version %s\n' "$_v" > "$_d/bin/foo"
    chmod +x "$_d/bin/foo"
    printf 'foo %s\n' "$_v" > "$_d/share/doc/foo/README"
    ( cd "$DIR/build" && tar -czf "$DIR/foo-$_v.tar.gz" "foo-$_v" )
    sha=$(sha256sum "$DIR/foo-$_v.tar.gz" | awk '{print $1}')
    printf 'foo\t%s\tfile://%s/foo-%s.tar.gz\t%s\tFoo demo %s\n' \
        "$_v" "$(cd "$DIR" && pwd)" "$_v" "$sha" "$_v"
}

mkver 1.0.0 > "$DIR/index-v1.tsv"
mkver 2.0.0 > "$DIR/index-v2.tsv"
rm -rf "$DIR/build"

cat <<EOF
Listo. Prueba:

  belka --index $DIR/index-v1.tsv install foo
  belka --index $DIR/index-v2.tsv update foo   # 1.0.0 -> 2.0.0
  belka rollback foo                          # vuelve a 1.0.0
  belka --index $DIR/index-v2.tsv tui         # TUI (fzf si existe)
EOF
