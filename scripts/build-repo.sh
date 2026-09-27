#!/bin/sh
# Construye el indice packages.tsv consultando la API de GitHub Releases

set -e

META_FILE="meta/apps.list"
OUTPUT_FILE="packages.tsv"

# Crear o vaciar el archivo packages.tsv en la raiz
> "$OUTPUT_FILE"

# Agregar cabecera inicial (opcional, pero buena practica)
printf '# nombre\tversion\turl\tsha256\tdescripcion\n' > "$OUTPUT_FILE"

# Configurar el separador interno de campos (IFS) para usar estrictamente Tabulaciones
IFS="$(printf '\t')"

while read -r name repo pattern desc; do
    # Ignorar lineas vacias y comentarios
    case "$name" in
        \#*|"") continue ;;
    esac

    printf 'Procesando %s (%s)...\n' "$name" "$repo" >&2

    api_url="https://api.github.com/repos/$repo/releases/latest"
    
    # 1. Extraer version y limpiar la "v" inicial usando jq
    version=$(curl -sL "$api_url" | jq -r '.tag_name | sub("^v"; "")')
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        printf 'Error: No se pudo obtener la version de %s\n' "$repo" >&2
        continue
    fi

    # 2. Extraer la URL de descarga que coincida con el patron del asset
    dl_url=$(curl -sL "$api_url" | jq -r --arg pat "$pattern" '.assets[] | select(.name | contains($pat)) | .browser_download_url' | head -n 1)

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
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$dl_url" "$hash" "$desc" >> "$OUTPUT_FILE"
    
    printf '  -> Listo: %s v%s\n' "$name" "$version" >&2

done < "$META_FILE"

printf '\nGeneracion completada: %s\n' "$OUTPUT_FILE" >&2
