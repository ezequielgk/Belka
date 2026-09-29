#!/bin/sh
# Construye el indice packages.tsv consultando la API de GitHub Releases

set -e

META_FILE="meta/apps.list"
OUTPUT_FILE="packages.tsv"

# Crear o vaciar el archivo packages.tsv en la raiz
> "$OUTPUT_FILE"

# Agregar cabecera inicial (opcional, pero buena practica)
printf '# nombre\tversion\turl\tsha256\tdescripcion\texec\tcategoria\tterminal\n' > "$OUTPUT_FILE"

github_api() {
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl -sL "$1"
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

    api_url="https://api.github.com/repos/$repo/releases/latest"
    
    # 1. Extraer version y limpiar la "v" inicial usando jq
    version=$(github_api "$api_url" | jq -r 'if .tag_name != null then .tag_name | sub("^v"; "") else empty end')
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        printf 'Error: No se pudo obtener la version de %s\n' "$repo" >&2
        continue
    fi

    # 2. Extraer la URL de descarga que coincida con el patron del asset usando regex
    if [ "$pattern" = "TARBALL" ]; then
        dl_url=$(github_api "$api_url" | jq -r '.tarball_url')
    else
        dl_url=$(github_api "$api_url" | jq -r --arg pat "$pattern" 'if .assets != null then .assets[] | select(.name != null and (.name | test($pat; "i"))) | .browser_download_url else empty end' | head -n 1)
    fi

    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        printf 'Error: No se encontro asset con el patron "%s" para %s\n' "$pattern" "$repo" >&2
        continue
    fi

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
