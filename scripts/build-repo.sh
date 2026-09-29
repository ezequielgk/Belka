#!/bin/sh
# Construye el indice packages.tsv consultando la API de GitHub Releases

set -e

META_FILE="meta/apps.list"
OUTPUT_FILE="packages.tsv"

# Crear o vaciar el archivo packages.tsv en la raiz
> "$OUTPUT_FILE"

# Agregar cabecera inicial (opcional, pero buena practica)
printf '# nombre\tversion\turl\tsha256\tdescripcion\texec\tcategoria\tterminal\n' > "$OUTPUT_FILE"

# Resuelve dinámicamente la última versión y URL de descarga desde GitHub, Codeberg o GitLab
# Argumentos:
#   $1 - URL o identificador del repositorio
#   $2 - Patrón de búsqueda del asset (regex) o la palabra clave "TARBALL"
# Retorna:
#   Cadena formateada con la versión y la URL separadas por una tabulación
repo_fetch_latest_release() {
    _repo_url="$1"
    _pattern="$2"
    _version=""
    _dl_url=""
    case "$_repo_url" in
        *codeberg.org*)
            _repo_path=$(printf '%s\n' "$_repo_url" | sed -n 's|.*codeberg\.org/\([^/]\+/[^/]\+\).*|\1|p')
            _api="https://codeberg.org/api/v1/repos/${_repo_path}/releases/latest"
            _resp=$(curl -sL "$_api")
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
            _resp=$(curl -sL "$_api")
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
                _resp=$(curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$_api")
            else
                _resp=$(curl -sL "$_api")
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

# Configurar el separador interno de campos (IFS) para usar estrictamente Tabulaciones
IFS="$(printf '\t')"

while read -r name repo pattern desc exec_bin _app_cat _app_term; do
    # Ignorar lineas vacias y comentarios
    case "$name" in
        \#*|"") continue ;;
    esac

    [ -z "$_app_cat" ] || [ "$_app_cat" = "-" ] && _app_cat="Utility"
    [ -z "$_app_term" ] || [ "$_app_term" = "-" ] && _app_term="N"

    printf 'Procesando %s (%s)...\n' "$name" "$repo" >&2
    
    # Prevenir "Secondary Rate Limit" de GitHub al consultar decenas de paquetes
    sleep 1

    _release_data=$(repo_fetch_latest_release "$repo" "$pattern")
    
    if [ -z "$_release_data" ]; then
        printf 'Error: No se pudo obtener la version o el asset de %s\n' "$repo" >&2
        continue
    fi
    
    version=$(printf '%s\n' "$_release_data" | awk -F'\t' '{print $1}')
    dl_url=$(printf '%s\n' "$_release_data" | awk -F'\t' '{print $2}')

    printf '  -> Descargando %s para calcular sha256...\n' "$dl_url" >&2
    
    tmp_file="/tmp/moss_asset_$name.$$"
    
    # 3. Descargar temporalmente a /tmp y abortar linea si falla
    if ! curl -sL "$dl_url" -o "$tmp_file"; then
        printf 'Error al descargar %s\n' "$dl_url" >&2
        rm -f "$tmp_file"
        continue
    fi

    # 4. Calcular sha256sum
    hash=$(sha256sum "$tmp_file" | awk '{print $1}')
    rm -f "$tmp_file"

    # 5. Agregar la linea procesada a packages.tsv usando tabulaciones
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$dl_url" "$hash" "$desc" "$exec_bin" "$_app_cat" "$_app_term" >> "$OUTPUT_FILE"
    
    printf '  -> Listo: %s v%s\n' "$name" "$version" >&2

done < "$META_FILE"

printf '\nGeneracion completada: %s\n' "$OUTPUT_FILE" >&2
