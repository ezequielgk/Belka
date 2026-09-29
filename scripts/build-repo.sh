#!/bin/sh
# Construye el indice packages.tsv consultando la API de GitHub Releases

set -e

OUTPUT_FILE=${MOSS_OUTPUT_FILE:-"packages.tsv"}
TMP_DIR="/tmp/moss_build_$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

SELECTED_APPS=""
if [ $# -gt 0 ]; then
    if [ "$1" = "ALL" ] || [ "$1" = "--rebuild" ]; then
        SELECTED_APPS="ALL"
    else
        SELECTED_APPS=" "
        for arg in "$@"; do SELECTED_APPS="$SELECTED_APPS$arg "; done
    fi
elif [ "$INTERACTIVE" -eq 1 ]; then
    printf '¿Indexar todas las aplicaciones? (reconstrucción total) [S/n]: ' >&2
    read -r ans </dev/tty
    case "$ans" in
        [nN]*)
            _i=1
            printf '\nAplicaciones disponibles:\n' >&2
            for f in meta/tar.list meta/appimages.list; do
                [ -f "$f" ] || continue
                while read -r name _; do
                    case "$name" in \#*|"") continue ;; esac
                    printf ' %d) %s\n' "$_i" "$name" >&2
                    eval "_app_${_i}=\$name"
                    _i=$((_i + 1))
                done < "$f"
            done
            printf '\nIntroduce los números a indexar (separados por espacio): ' >&2
            read -r nums </dev/tty
            for n in $nums; do
                eval "app_name=\$_app_${n}"
                SELECTED_APPS="$SELECTED_APPS$app_name "
            done
            ;;
        *) SELECTED_APPS="ALL" ;;
    esac
else
    SELECTED_APPS="ALL"
fi

if [ "$SELECTED_APPS" = "ALL" ]; then
    STAGING_FILE="$TMP_DIR/packages.tsv.tmp"
    > "$STAGING_FILE"
    printf '# nombre\tversion\turl\tsha256\tdescripcion\texec\tcategoria\tterminal\ttipo\n' > "$STAGING_FILE"
else
    if [ ! -f "$OUTPUT_FILE" ]; then
        printf '# nombre\tversion\turl\tsha256\tdescripcion\texec\tcategoria\tterminal\ttipo\n' > "$OUTPUT_FILE"
    fi
fi

# Obtiene la información del último release desde la API correspondiente
repo_fetch_latest_release() {
    _repo_url="$1"
    _pattern="$2"
    _version=""
    _dl_url=""
    case "$_repo_url" in
        *codeberg.org*)
            _repo_path=$(printf '%s\n' "$_repo_url" | sed -n 's|.*codeberg\.org/\([^/]\+/[^/]\+\).*|\1|p')
            _api="https://codeberg.org/api/v1/repos/${_repo_path}/releases/latest"
            _resp=$(curl -sL --max-time 10 --retry 3 "$_api")
            _version=$(printf '%s\n' "$_resp" | jq -r 'if .tag_name != null then .tag_name | sub("^v"; "") else empty end')
            if [ "$_pattern" = "TARBALL" ]; then
                _dl_url=$(printf '%s\n' "$_resp" | jq -r '.tarball_url')
            else
                _dl_url=$(printf '%s\n' "$_resp" | jq -r --arg pat "$_pattern" 'if .assets != null then .assets[] | select(.name != null and (.name | test($pat; "i"))) | .browser_download_url else empty end' | head -n 1)
            fi
            ;;
        *gitlab.com*)
            _repo_path=$(printf '%s\n' "$_repo_url" | sed -n 's|.*gitlab\.com/\(.*\)|\1|p')
            _url_enc=$(printf '%s\n' "$_repo_path" | sed 's|/|%2F|g')
            _api="https://gitlab.com/api/v4/projects/${_url_enc}/releases/permalink/latest"
            _resp=$(curl -sL --max-time 10 --retry 3 "$_api")
            _version=$(printf '%s\n' "$_resp" | jq -r 'if .tag_name != null then .tag_name | sub("^v"; "") else empty end')
            if [ "$_pattern" = "TARBALL" ]; then
                _dl_url=$(printf '%s\n' "$_resp" | jq -r '.assets.sources[] | select(.format == "tar.gz") | .url' | head -n 1)
                [ -z "$_dl_url" ] || [ "$_dl_url" = "null" ] && _dl_url="https://gitlab.com/${_repo_path}/-/archive/${_version}/${_repo_path##*/}-${_version}.tar.gz"
            else
                _dl_url=$(printf '%s\n' "$_resp" | jq -r --arg pat "$_pattern" 'if .assets.links != null then .assets.links[] | select(.name != null and (.name | test($pat; "i"))) | .url else empty end' | head -n 1)
            fi
            ;;
        *)
            _repo_path=$(printf '%s\n' "$_repo_url" | sed 's|.*github\.com/||')
            _api="https://api.github.com/repos/${_repo_path}/releases/latest"
            if [ -n "$GITHUB_TOKEN" ]; then
                _resp=$(curl -sL --max-time 10 --retry 3 -H "Authorization: Bearer $GITHUB_TOKEN" "$_api")
            else
                _resp=$(curl -sL --max-time 10 --retry 3 "$_api")
            fi
            _version=$(printf '%s\n' "$_resp" | jq -r 'if .tag_name != null then .tag_name | sub("^v"; "") else empty end')
            if [ "$_pattern" = "TARBALL" ]; then
                _dl_url=$(printf '%s\n' "$_resp" | jq -r '.tarball_url')
            else
                _dl_url=$(printf '%s\n' "$_resp" | jq -r --arg pat "$_pattern" 'if .assets != null then .assets[] | select(.name != null and (.name | test($pat; "i"))) | .browser_download_url else empty end' | head -n 1)
            fi
            ;;
    esac
    if [ -n "$_version" ] && [ -n "$_dl_url" ] && [ "$_version" != "null" ] && [ "$_dl_url" != "null" ]; then
        printf '%s\t%s\n' "$_version" "$_dl_url"
    fi
}

# Actualiza o inserta un paquete de forma segura en el índice local
update_atomic_index() {
    _pkg_name="$1"
    _pkg_line="$2"
    _target_file="$3"
    _tmp_idx="$TMP_DIR/atomic_index.tmp"
    if grep -q "^${_pkg_name}$(printf '\t')" "$_target_file"; then
        awk -F'\t' -v pkg="$_pkg_name" -v newline="$_pkg_line" '
            $1 == pkg { print newline; next }
            { print }
        ' "$_target_file" > "$_tmp_idx"
        mv "$_tmp_idx" "$_target_file"
    else
        printf '%s\n' "$_pkg_line" >> "$_target_file"
    fi
}

# Procesa y registra cada aplicación desde los archivos .list
process_meta_file() {
    _pm_file=$1
    _pm_type=$2
    [ -f "$_pm_file" ] || return 0
    while IFS="$(printf '\t')" read -r name repo pattern desc exec_bin _app_cat _app_term; do
        case "$name" in \#*|"") continue ;; esac
        [ -z "$_app_cat" ] || [ "$_app_cat" = "-" ] && _app_cat="Utility"
        [ -z "$_app_term" ] || [ "$_app_term" = "-" ] && _app_term="N"
        if [ "$SELECTED_APPS" != "ALL" ]; then
            case "$SELECTED_APPS" in
                *" $name "*) ;;
                *) continue ;;
            esac
        fi
        printf 'Procesando %s (%s)...\n' "$name" "$repo" >&2
        sleep 1
        _release_data=$(repo_fetch_latest_release "$repo" "$pattern")
        if [ -z "$_release_data" ]; then
            printf 'Error: No se pudo obtener la version o el asset de %s\n' "$repo" >&2
            continue
        fi
        version=$(printf '%s\n' "$_release_data" | awk -F'\t' '{print $1}')
        dl_url=$(printf '%s\n' "$_release_data" | awk -F'\t' '{print $2}')
        printf '  -> Descargando %s para calcular sha256...\n' "$dl_url" >&2
        tmp_file="$TMP_DIR/asset_$name"
        if ! curl -sL "$dl_url" -o "$tmp_file"; then
            printf 'Error al descargar %s\n' "$dl_url" >&2
            rm -f "$tmp_file"
            continue
        fi
        hash=$(sha256sum "$tmp_file" | awk '{print $1}')
        rm -f "$tmp_file"
        new_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$version" "$dl_url" "$hash" "$desc" "$exec_bin" "$_app_cat" "$_app_term" "$_pm_type")
        if [ "$SELECTED_APPS" = "ALL" ]; then
            printf '%s\n' "$new_line" >> "$STAGING_FILE"
        else
            update_atomic_index "$name" "$new_line" "$OUTPUT_FILE"
        fi
        printf '  -> Listo: %s v%s\n' "$name" "$version" >&2
    done < "$_pm_file"
}

BUILD_TAR=${BUILD_TAR:-1}
BUILD_APPIMAGE=${BUILD_APPIMAGE:-1}

[ "$BUILD_TAR" -eq 1 ] && process_meta_file "meta/tar.list" "tar"
[ "$BUILD_APPIMAGE" -eq 1 ] && process_meta_file "meta/appimages.list" "appimage"

if [ "$SELECTED_APPS" = "ALL" ]; then
    mv "$STAGING_FILE" "$OUTPUT_FILE"
fi

printf '\nGeneracion completada: %s\n' "$OUTPUT_FILE" >&2
