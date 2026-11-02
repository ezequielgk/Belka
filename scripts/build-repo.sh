#!/bin/sh
# build-repo.sh - Construye el indice packages.tsv consultando las APIs de
# releases de GitHub, GitLab y Codeberg.
#
# Entradas: meta/tar.list y meta/appimages.list (7 columnas: nombre, repo,
# patron_asset, descripcion, exec, categoria, terminal).
# Salida: $BELKA_OUTPUT_FILE (por defecto packages.tsv), 9 columnas:
#   nombre, version, url, sha256, descripcion, exec, categoria, terminal, tipo
#
# Uso:
#   build-repo.sh                        # reconstruccion total (modo ALL)
#   build-repo.sh ALL | --rebuild        # reconstruccion total explicita
#   build-repo.sh --force                # ignora la cache de sha256
#   build-repo.sh app1 [app2 ...]        # indexa apps puntuales
#   build-repo.sh -h | --help
#
# Entorno:
#   BELKA_OUTPUT_FILE  archivo de salida (default packages.tsv)
#   BUILD_TAR=0        no reconstruye los .tar (conserva entradas previas en modo ALL)
#   BUILD_APPIMAGE=0   no reconstruye los .AppImage (igual que arriba)
#   BELKA_FORCE=1      equivalente a --force
#   BELKA_STRICT=1     terminar con exit 1 si hubo errores
#   GITHUB_TOKEN       token, se pasa a curl por stdin (no aparece en ps)
#
# Patrones de asset soportados: regex del nombre del asset, "TARBALL"
# y "TEMPLATE|url|version_fallback".

set -eu
export LC_ALL=C

OUTPUT_FILE=${BELKA_OUTPUT_FILE:-packages.tsv}
FORCE=${BELKA_FORCE:-0}
STRICT=${BELKA_STRICT:-0}
BUILD_TAR=${BUILD_TAR:-1}
BUILD_APPIMAGE=${BUILD_APPIMAGE:-1}
API_TIMEOUT=${BELKA_API_TIMEOUT:-30}
DL_TIMEOUT=${BELKA_DL_TIMEOUT:-900}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

check_flag() {
    # $1 = nombre de la variable, $2 = valor
    case "$2" in
        0|1) ;;
        *) printf '%s invalido: %s (use 0 o 1)\n' "$1" "$2" >&2; exit 2 ;;
    esac
}
check_flag BELKA_FORCE "$FORCE"
check_flag BELKA_STRICT "$STRICT"
check_flag BUILD_TAR "$BUILD_TAR"
check_flag BUILD_APPIMAGE "$BUILD_APPIMAGE"

for _cmd in curl jq awk sha256sum mktemp sed cut stat; do
    command -v "$_cmd" >/dev/null 2>&1 || {
        printf 'Falta el comando requerido: %s\n' "$_cmd" >&2
        exit 3
    }
done

# ---------- archivos temporales y traps ----------
# Bug 7: mktemp -d en lugar de /tmp/belka_build_$$, y el staging se crea
# junto al indice de salida para que el mv final sea atomico.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/belka_build.XXXXXX")
STAGING_FILE=""
ATOMIC_TMP=""

cleanup() {
    rm -rf "$TMP_DIR"
    # Bug 1: EXIT limpia; INT/TERM/HUP solo terminan (sus traps hacen exit y
    # disparan este trap EXIT).
    if [ -n "$STAGING_FILE" ] && [ -f "$STAGING_FILE" ]; then rm -f "$STAGING_FILE"; fi
    if [ -n "$ATOMIC_TMP" ] && [ -f "$ATOMIC_TMP" ]; then rm -f "$ATOMIC_TMP"; fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

usage() {
    printf 'Uso: %s [ALL | --rebuild] [--force]\n' "$0"
    printf '     %s app1 [app2 ...]\n' "$0"
    printf 'Options: -h, --help   mostrar esta ayuda\n'
    printf '         --force       re-descarga y recalcula sha256 aunque haya cache\n'
    printf '         ALL/--rebuild reconstruccion total del indice\n'
    printf 'Entorno: BELKA_OUTPUT_FILE, BUILD_TAR, BUILD_APPIMAGE, BELKA_FORCE, BELKA_STRICT, GITHUB_TOKEN\n'
}

OUT_DIR=$(dirname -- "$OUTPUT_FILE")
if [ ! -d "$OUT_DIR" ]; then
    mkdir -p "$OUT_DIR"
fi

PENDING_FILE=""
FAILED_FILE="$TMP_DIR/failed_apps"
: > "$FAILED_FILE"
_ok=0
_reused=0
_preserved=0

# ---------- seleccion de apps ----------
REBUILD_ALL=0
SELECTED_APPS=""
INTERACTIVE=0
if [ -t 0 ]; then INTERACTIVE=1; fi

if [ $# -gt 0 ]; then
    for _arg in "$@"; do
        case "$_arg" in
            ALL) REBUILD_ALL=1 ;;
            --rebuild) REBUILD_ALL=1 ;;
            --force|-f) FORCE=1 ;;
            -h|--help) usage; exit 0 ;;
            --) ;;
            -*) printf 'Opcion desconocida: %s\n' "$_arg" >&2; usage >&2; exit 2 ;;
            *) SELECTED_APPS="$SELECTED_APPS$_arg " ;;
        esac
    done
    if [ "$REBUILD_ALL" -eq 1 ] && [ -n "$SELECTED_APPS" ]; then
        printf 'ALL/--rebuild no acepta nombres de aplicaciones\n' >&2
        exit 2
    fi
    if [ "$REBUILD_ALL" -eq 0 ] && [ -z "$SELECTED_APPS" ]; then
        printf 'No se especificaron aplicaciones\n' >&2
        usage >&2
        exit 2
    fi
    SELECTED_APPS=" $SELECTED_APPS"
elif [ "$INTERACTIVE" -eq 1 ]; then
    printf '¿Indexar todas las aplicaciones? (reconstruccion total) [S/n]: ' >&2
    read -r _ans </dev/tty
    case "$_ans" in
        [nN]*)
            _i=1
            printf '\nAplicaciones disponibles:\n' >&2
            for _f in meta/tar.list meta/appimages.list; do
                [ -f "$_f" ] || continue
                while IFS="$(printf '\t')" read -r _nm _; do
                    case "$_nm" in \#*|"") continue ;; esac
                    printf ' %d) %s\n' "$_i" "$_nm" >&2
                    eval "_app_$_i=\$_nm"
                    _i=$((_i + 1))
                done < "$_f"
            done
            printf '\nIntroduce los numeros a indexar (separados por espacio): ' >&2
            read -r _nums </dev/tty
            SELECTED_APPS=" "
            # Bug 5: cada numero debe ser solo digitos antes del eval.
            for _n in $_nums; do
                case "$_n" in
                    ''|*[!0-9]*)
                        printf 'Numero invalido, se ignora: %s\n' "$_n" >&2
                        continue
                        ;;
                esac
                eval "_sel=\${_app_${_n}:-}"
                if [ -n "$_sel" ]; then
                    SELECTED_APPS="$SELECTED_APPS$_sel "
                else
                    printf 'Fuera de rango, se ignora: %s\n' "$_n" >&2
                fi
            done
            if [ -z "$(printf '%s' "$SELECTED_APPS" | tr -d ' ')" ]; then
                printf 'No se selecciono ninguna aplicacion\n' >&2
                exit 2
            fi
            ;;
        *) REBUILD_ALL=1 ;;
    esac
else
    REBUILD_ALL=1
fi

if [ "$REBUILD_ALL" -eq 0 ]; then
    PENDING_FILE="$TMP_DIR/pending_apps"
    : > "$PENDING_FILE"
    for _a in $SELECTED_APPS; do
        awk -v a="$_a" '$0 == a { e = 1 } END { exit e ? 0 : 1 }' "$PENDING_FILE" 2>/dev/null ||
            printf '%s\n' "$_a" >> "$PENDING_FILE"
    done
fi

# ---------- helpers de formato ----------
print_header() {
    printf '# nombre\tversion\turl\tsha256\tdescripcion\texec\tcategoria\tterminal\ttipo\n'
}

# Bug 6: exclusion por palabra completa, unificada en un solo regex.
# Excluye windows/win32/win64/darwin/macos/mac/osx/apple, arm (aarch64, arm64,
# armv*, armhf, armel), i386/i686/386/ia32, riscv*, mips*, s390x, ppc*,
# freebsd/openbsd/netbsd y android. "x86_64" NO esta excluido.
EXCLUDE_RE='(^|[^A-Za-z0-9])(windows|win32|win64|darwin|macos|mac|osx|apple|aarch64|armv[0-9A-Za-z]*|arm64|armhf|armel|arm|i386|i686|386|ia32|riscv[0-9A-Za-z]*|mips[0-9A-Za-z]*|s390x|ppc[0-9A-Za-z]*|freebsd|openbsd|netbsd|android)([^A-Za-z0-9]|$)'

jq_safe() {
    # Bug 3: wrapper de jq que nunca falla (output vacio si hay error).
    jq "$@" 2>/dev/null || :
}

version_is_mutable() {
    _mv_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$_mv_lower" in
        *latest*|*nightly*|*continuous*|*rolling*|*edge*|*dev*|*master*|*main*|*stable*|*canary*|*snapshot*|*tip*) return 0 ;;
    esac
    return 1
}

# Caché de sha256: busca en el indice anterior una entrada con la misma
# (nombre, tipo); devuelve "version<TAB>url<TAB>sha256" si hay hash usable.
cache_lookup() {
    [ -f "$OUTPUT_FILE" ] || return 0
    awk -F'\t' -v n="$1" -v t="$2" '
        NF > 3 && $1 == n && $9 == t && $4 ~ /^[0-9a-f]{64}$/ {
            printf "%s\t%s\t%s\n", $2, $3, $4
            exit
        }' "$OUTPUT_FILE"
}

# Linea completa previa (para conservarla si la app falla en modo ALL).
prev_line_lookup() {
    [ -f "$OUTPUT_FILE" ] || return 0
    awk -F'\t' -v n="$1" -v t="$2" '
        NF > 3 && $1 == n && $9 == t { print; exit }' "$OUTPUT_FILE"
}

# Conserva en el staging las entradas anteriores de un tipo deshabilitado.
preserve_old_entries() {
    [ -f "$OUTPUT_FILE" ] || return 0
    _n=$(awk -F'\t' -v t="$1" 'NF > 3 && $9 == t { c++ } END { print c + 0 }' "$OUTPUT_FILE")
    _preserved=$((_preserved + _n))
    awk -F'\t' -v t="$1" 'NF > 3 && $9 == t { print }' "$OUTPUT_FILE" >> "$STAGING_FILE"
}

# ---------- API ----------
# Llamada HTTP a la API del repo. Con fallo no killa el script (Bug 3):
# devuelve vacio y registra el campo .message si lo hay (rate limit, etc.).
curl_api() {
    _ca_url=$1
    _ca_body="$TMP_DIR/api_body"
    _ca_code=""
    _ca_hdr=""
    : > "$_ca_body"
    case "$_ca_url" in
        https://api.github.com/*)
            if [ -n "$GITHUB_TOKEN" ]; then
                _ca_hdr=$(printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN")
            fi
            ;;
    esac
    if [ -n "$_ca_hdr" ]; then
        # Bug 8: el token va por stdin (curl -H @-), no en la linea de comandos.
        _ca_code=$(printf '%s\n' "$_ca_hdr" | curl -sS --max-time "$API_TIMEOUT" --retry 3 -H @- -o "$_ca_body" -w '%{http_code}' "$_ca_url" 2>/dev/null) || _ca_code=""
    else
        _ca_code=$(curl -sS --max-time "$API_TIMEOUT" --retry 3 -o "$_ca_body" -w '%{http_code}' "$_ca_url" 2>/dev/null) || _ca_code=""
    fi
    if [ "$_ca_code" = "200" ] && [ -s "$_ca_body" ]; then
        cat "$_ca_body"
        return 0
    fi
    if [ -s "$_ca_body" ]; then
        _ca_msg=$(jq_safe -r '.message // empty' "$_ca_body")
        if [ -n "$_ca_msg" ]; then
            printf 'Aviso de la API (%s): %s\n' "$_ca_url" "$_ca_msg" >&2
        fi
    fi
    return 1
}

# Seleccion de assets con exclusion por palabra completa (Bug 6).
assets_github() {
    # $1 = cuerpo JSON, $2 = patron -> browser_download_url del primer asset valido
    printf '%s\n' "$1" | jq_safe -r --arg pat "$2" --arg excl "$EXCLUDE_RE" '
        if .assets != null then
            .assets[]
            | select(.name != null
                and (.name | test($pat; "i"))
                and ((.name | test($excl; "i")) | not))
            | .browser_download_url
            | select(. != null and . != "")
        else empty end' | head -n 1
}

assets_gitlab() {
    # Bug 11: de .assets.links[] usar (.direct_asset_url // .url)
    printf '%s\n' "$1" | jq_safe -r --arg pat "$2" --arg excl "$EXCLUDE_RE" '
        if .assets != null and .assets.links != null then
            .assets.links[]
            | select(.name != null
                and (.name | test($pat; "i"))
                and ((.name | test($excl; "i")) | not))
            | (.direct_asset_url // .url)
            | select(. != null and . != "")
        else empty end' | head -n 1
}

repo_fetch_latest_release() {
    # $1 = repo (owner/name, URL de github/gitlab/codeberg o external/*)
    # $2 = patron (regex | TARBALL | INREPO | TEMPLATE|url|fallback)
    # Imprime "<version>\t<url>" o nada si no se pudo resolver.
    _rf_repo=$1
    _rf_pattern=$2
    _rf_resp=""
    _rf_tag=""
    _rf_version=""
    _rf_dl=""

    # Bug 10: TEMPLATE con repo external/... no consulta ninguna API.
    case "$_rf_pattern" in
        "TEMPLATE|"*)
            case "$_rf_repo" in
                external/*)
                    _rf_tpl_url=$(printf '%s\n' "$_rf_pattern" | cut -d'|' -f2)
                    _rf_tpl_fb=$(printf '%s\n' "$_rf_pattern" | cut -d'|' -f3)
                    if [ -n "$_rf_tpl_fb" ] && [ -n "$_rf_tpl_url" ]; then
                        _rf_dl=$(printf '%s' "$_rf_tpl_url" | sed "s|@VERSION@|$_rf_tpl_fb|g")
                        printf '%s\t%s\n' "$_rf_tpl_fb" "$_rf_dl"
                    fi
                    return 0
                    ;;
            esac
            ;;
    esac

    case "$_rf_repo" in
        *codeberg.org*)
            _rf_path=$(printf '%s\n' "$_rf_repo" | sed -n 's|.*codeberg\.org/\([^/]\+/[^/]\+\).*|\1|p')
            [ -n "$_rf_path" ] || return 0
            _rf_resp=$(curl_api "https://codeberg.org/api/v1/repos/$_rf_path/releases/latest" || :)
            _rf_tag=$(printf '%s\n' "$_rf_resp" | jq_safe -r '.tag_name // empty')
            _rf_version=$(printf '%s\n' "$_rf_tag" | sed 's/^v//')
            case "$_rf_pattern" in
                TARBALL)
                    _rf_dl=$(printf '%s\n' "$_rf_resp" | jq_safe -r '.tarball_url // empty')
                    ;;
                *)
                    _rf_dl=$(assets_github "$_rf_resp" "$_rf_pattern")
                    ;;
            esac
            ;;
        *gitlab.com*)
            _rf_path=$(printf '%s\n' "$_rf_repo" | sed -n 's|.*gitlab\.com/\(.*\)|\1|p')
            [ -n "$_rf_path" ] || return 0
            _rf_enc=$(printf '%s\n' "$_rf_path" | sed 's|/|%2F|g')
            _rf_resp=$(curl_api "https://gitlab.com/api/v4/projects/$_rf_enc/releases/permalink/latest" || :)
            _rf_tag=$(printf '%s\n' "$_rf_resp" | jq_safe -r '.tag_name // empty')
            _rf_version=$(printf '%s\n' "$_rf_tag" | sed 's/^v//')
            case "$_rf_pattern" in
                TARBALL)
                    _rf_dl=$(printf '%s\n' "$_rf_resp" | jq_safe -r '
                        if .assets != null and .assets.sources != null then
                            .assets.sources[] | select(.format == "tar.gz") | .url
                        else empty end' | head -n 1)
                    # Bug 11: fallback con el nombre de tag original (conserva la "v")
                    if [ -z "$_rf_dl" ] && [ -n "$_rf_tag" ]; then
                        _rf_dl=$(printf 'https://gitlab.com/%s/-/archive/%s/%s-%s.tar.gz' \
                            "$_rf_path" "$_rf_tag" "${_rf_path##*/}" "$_rf_tag")
                    fi
                    ;;
                *)
                    _rf_dl=$(assets_gitlab "$_rf_resp" "$_rf_pattern")
                    ;;
            esac
            ;;
        *)
            _rf_path=$(printf '%s\n' "$_rf_repo" | sed 's|.*github\.com/||')
            [ -n "$_rf_path" ] || return 0
            case "$_rf_pattern" in
                INREPO*)
                    # Bug 9: INREPO no consulta releases/latest, solo repo + commits.
                    _rf_info=$(curl_api "https://api.github.com/repos/$_rf_path" || :)
                    _rf_branch=$(printf '%s\n' "$_rf_info" | jq_safe -r '.default_branch // empty')
                    if [ -z "$_rf_branch" ]; then _rf_branch="master"; fi
                    _rf_commit=$(curl_api "https://api.github.com/repos/$_rf_path/commits/$_rf_branch" || :)
                    _rf_version=$(printf '%s\n' "$_rf_commit" | jq_safe -r '
                        if type == "array" then .[0].sha[0:7]
                        elif .sha != null then .sha[0:7]
                        else empty end' | head -n 1)
                    if [ -z "$_rf_version" ]; then _rf_version="latest"; fi
                    _rf_dl=$(printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz' "$_rf_path" "$_rf_branch")
                    ;;
                *)
                    _rf_resp=$(curl_api "https://api.github.com/repos/$_rf_path/releases/latest" || :)
                    _rf_tag=$(printf '%s\n' "$_rf_resp" | jq_safe -r '.tag_name // empty')
                    _rf_version=$(printf '%s\n' "$_rf_tag" | sed 's/^v//')
                    if [ -n "$_rf_version" ]; then
                        case "$_rf_pattern" in
                            TARBALL)
                                _rf_dl=$(printf '%s\n' "$_rf_resp" | jq_safe -r '.tarball_url // empty')
                                ;;
                            *)
                                _rf_dl=$(assets_github "$_rf_resp" "$_rf_pattern")
                                ;;
                        esac
                    fi
                    ;;
            esac
            ;;
    esac

    # Bug 10: con repo real, TEMPLATE usa la version del tag; el fallback
    # solo se aplica si la API fallo.
    case "$_rf_pattern" in
        "TEMPLATE|"*)
            _rf_tpl_url=$(printf '%s\n' "$_rf_pattern" | cut -d'|' -f2)
            _rf_tpl_fb=$(printf '%s\n' "$_rf_pattern" | cut -d'|' -f3)
            if [ -z "$_rf_version" ]; then
                _rf_version=$_rf_tpl_fb
            fi
            if [ -n "$_rf_version" ]; then
                _rf_dl=$(printf '%s' "$_rf_tpl_url" | sed "s|@VERSION@|$_rf_version|g")
            fi
            ;;
    esac

    if [ -n "$_rf_version" ] && [ -n "$_rf_dl" ] && [ "$_rf_version" != "null" ] && [ "$_rf_dl" != "null" ]; then
        printf '%s\t%s\n' "$_rf_version" "$_rf_dl"
    fi
}

# Actualiza (o inserta) una linea en el indice sin corromperlo.
# Bug 4: la linea nueva viaja por ENVIRON; con awk -v las barras invertidas
# de la descripcion se interpretarian como escapes.
update_atomic_index() {
    # $1 = nombre, $2 = linea completa, $3 = archivo destino, $4 = tipo
    _ua_target=$3
    ATOMIC_TMP=$(mktemp "$OUT_DIR/.belka_index.tmp.XXXXXX")
    # conserva los permisos del indice original
    _ua_mode="644"
    _ua_prev=$(stat -c '%a' "$_ua_target" 2>/dev/null || :)
    if [ -n "$_ua_prev" ]; then _ua_mode=$_ua_prev; fi
    chmod "$_ua_mode" "$ATOMIC_TMP" 2>/dev/null || :
    PKG_LINE=$2 PKG_NAME=$1 PKG_TYPE=$4 awk '
        BEGIN { FS = "\t"; OFS = "\t" }
        $1 == ENVIRON["PKG_NAME"] && $9 == ENVIRON["PKG_TYPE"] {
            found = 1
            print ENVIRON["PKG_LINE"]
            next
        }
        { print }
        END { if (!found) print ENVIRON["PKG_LINE"] }
    ' "$_ua_target" > "$ATOMIC_TMP"
    mv "$ATOMIC_TMP" "$_ua_target"
    ATOMIC_TMP=""
}

record_failure() {
    # $1 = nombre, $2 = motivo
    _errors=$((_errors + 1))
    printf '%s\n' "$1" >> "$FAILED_FILE"
    printf 'Error: %s: %s\n' "$1" "$2" >&2
}

# Si la app falla en modo ALL, conserva su entrada anterior en el staging.
carry_old_line() {
    # $1 = nombre, $2 = tipo
    if [ "$REBUILD_ALL" -eq 1 ]; then
        _prev=$(prev_line_lookup "$1" "$2")
        if [ -n "$_prev" ]; then
            printf '%s\n' "$_prev" >> "$STAGING_FILE"
            printf '  -> Se conserva la entrada anterior de %s\n' "$1" >&2
        fi
    fi
}

# Marca la app como vista en las listas (para avisar las inexistentes).
pending_remove() {
    [ -n "$PENDING_FILE" ] || return 0
    awk -v rm="$1" '$0 != rm { print }' "$PENDING_FILE" > "$PENDING_FILE.new"
    mv "$PENDING_FILE.new" "$PENDING_FILE"
}

# ---------- procesamiento ----------
process_meta_file() {
    # $1 = archivo .list, $2 = tipo ("tar" | "appimage")
    _pm_file=$1
    _pm_type=$2
    [ -f "$_pm_file" ] || return 0
    while IFS="$(printf '\t')" read -r name repo pattern desc exec_bin app_cat app_term; do
        case "$name" in \#*|"") continue ;; esac
        if [ -z "$app_cat" ] || [ "$app_cat" = "-" ]; then app_cat="Utility"; fi
        if [ -z "$app_term" ] || [ "$app_term" = "-" ]; then app_term="N"; fi

        if [ "$REBUILD_ALL" -ne 1 ]; then
            case "$SELECTED_APPS" in
                *" $name "*) ;;
                *) continue ;;
            esac
        fi
        pending_remove "$name"

        printf 'Procesando %s (%s)...\n' "$name" "$repo" >&2
        _release_data=$(repo_fetch_latest_release "$repo" "$pattern")
        if [ -z "$_release_data" ]; then
            record_failure "$name" "no se pudo obtener la version o el asset de $repo"
            carry_old_line "$name" "$_pm_type"
            continue
        fi
        IFS="$(printf '\t')" read -r version dl_url <<_RLF
$_release_data
_RLF
        if [ -z "$version" ] || [ -z "$dl_url" ]; then
            record_failure "$name" "datos incompletos del release"
            carry_old_line "$name" "$_pm_type"
            continue
        fi

        # Caché de sha256: misma (nombre, tipo) con igual version y url.
        file_hash=""
        _c_ver=""
        _c_url=""
        _c_sha=""
        if [ "$FORCE" != "1" ]; then
            _mutable=0
            if version_is_mutable "$version"; then _mutable=1; fi
            if [ "$_mutable" -eq 0 ]; then
                _cache=$(cache_lookup "$name" "$_pm_type")
                if [ -n "$_cache" ]; then
                    IFS="$(printf '\t')" read -r _c_ver _c_url _c_sha <<_CLF
$_cache
_CLF
                    if [ "$_c_ver" = "$version" ] && [ "$_c_url" = "$dl_url" ] && [ -n "$_c_sha" ]; then
                        file_hash=$_c_sha
                        _reused=$((_reused + 1))
                        printf '  -> Reutilizado de la cache: %s v%s\n' "$name" "$version" >&2
                    fi
                fi
            fi
        fi

        if [ -z "$file_hash" ]; then
            printf '  -> Descargando %s\n' "$dl_url" >&2
            tmp_file="$TMP_DIR/asset_$name"
            # Bug 2: curl -fsSL con timeout largo y retries; los archivos
            # vacios se rechazan (antes un 404 terminaba hasheado).
            if curl -fsSL --max-time "$DL_TIMEOUT" --retry 3 -o "$tmp_file" "$dl_url"; then
                if [ -s "$tmp_file" ]; then
                    file_hash=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print $1}')
                    if [ -z "$file_hash" ]; then
                        record_failure "$name" "no se pudo calcular el sha256 de $dl_url"
                    fi
                else
                    record_failure "$name" "la descarga dio un archivo vacio ($dl_url)"
                fi
            else
                record_failure "$name" "no se pudo descargar $dl_url"
            fi
            rm -f "$tmp_file"
            if [ -z "$file_hash" ]; then
                carry_old_line "$name" "$_pm_type"
                continue
            fi
            _ok=$((_ok + 1))
        fi

        new_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$name" "$version" "$dl_url" "$file_hash" "$desc" "$exec_bin" "$app_cat" "$app_term" "$_pm_type")
        if [ "$REBUILD_ALL" -eq 1 ]; then
            printf '%s\n' "$new_line" >> "$STAGING_FILE"
        else
            update_atomic_index "$name" "$new_line" "$OUTPUT_FILE" "$_pm_type"
        fi
        printf '  -> Listo: %s v%s\n' "$name" "$version" >&2
    done < "$_pm_file"
}

_errors=0

if [ "$REBUILD_ALL" -eq 1 ]; then
    STAGING_FILE=$(mktemp "$OUT_DIR/.packages.tsv.staging.XXXXXX")
    print_header > "$STAGING_FILE"
fi

if [ "$REBUILD_ALL" -eq 1 ]; then
    # Con un tipo deshabilitado se conservan sus entradas anteriores.
    if [ "$BUILD_TAR" -eq 0 ]; then
        preserve_old_entries tar
    fi
    if [ "$BUILD_TAR" -eq 1 ]; then
        process_meta_file "meta/tar.list" "tar"
    fi
    if [ "$BUILD_APPIMAGE" -eq 0 ]; then
        preserve_old_entries appimage
    fi
    if [ "$BUILD_APPIMAGE" -eq 1 ]; then
        process_meta_file "meta/appimages.list" "appimage"
    fi
else
    if [ ! -f "$OUTPUT_FILE" ]; then
        print_header > "$OUTPUT_FILE"
    fi
    if [ "$BUILD_TAR" -eq 1 ]; then
        process_meta_file "meta/tar.list" "tar"
    fi
    if [ "$BUILD_APPIMAGE" -eq 1 ]; then
        process_meta_file "meta/appimages.list" "appimage"
    fi
fi

# Apps pedidas por argumento que no existen en las listas.
if [ -n "$PENDING_FILE" ] && [ -s "$PENDING_FILE" ]; then
    while IFS= read -r _miss; do
        [ -n "$_miss" ] || continue
        printf 'Aviso: la aplicacion "%s" no existe en meta/tar.list ni en meta/appimages.list\n' "$_miss" >&2
    done < "$PENDING_FILE"
fi

# ---------- finalizacion del modo ALL ----------
if [ "$REBUILD_ALL" -eq 1 ]; then
    _data_lines=$(awk '$0 !~ /^#/ && $0 != "" { n++ } END { print n + 0 }' "$STAGING_FILE")
    if [ "$_data_lines" -eq 0 ]; then
        # No se obtuvo ninguna entrada: no se pisa el indice existente.
        printf 'No se obtuvo ninguna entrada; se conserva el indice existente.\n' >&2
        rm -f "$STAGING_FILE"
        STAGING_FILE=""
        printf '\nResumen: ok=%d reutilizados=%d conservadas=%d errores=%d\n' "$_ok" "$_reused" "$_preserved" "$_errors" >&2
        while IFS= read -r _fn; do
            [ -n "$_fn" ] || continue
            printf 'Fallo: %s\n' "$_fn" >&2
        done < "$FAILED_FILE"
        exit 1
    fi
    # Permisos equivalentes a los del archivo previo (si existia).
    _mode="644"
    if [ -f "$OUTPUT_FILE" ]; then
        _prev_mode=$(stat -c '%a' "$OUTPUT_FILE" 2>/dev/null || :)
        if [ -n "$_prev_mode" ]; then _mode=$_prev_mode; fi
    fi
    chmod "$_mode" "$STAGING_FILE" 2>/dev/null || :
    mv "$STAGING_FILE" "$OUTPUT_FILE"
    STAGING_FILE=""
fi

# ---------- resumen ----------
printf '\nResumen: ok=%d reutilizados=%d conservadas=%d errores=%d\n' "$_ok" "$_reused" "$_preserved" "$_errors" >&2
if [ -s "$FAILED_FILE" ]; then
    while IFS= read -r _fn; do
        [ -n "$_fn" ] || continue
        printf 'Fallo: %s\n' "$_fn" >&2
    done < "$FAILED_FILE"
fi

if [ "$STRICT" -eq 1 ] && [ "$_errors" -gt 0 ]; then
    exit 1
fi

printf '\nGeneracion completada: %s\n' "$OUTPUT_FILE" >&2
