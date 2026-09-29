#!/bin/sh
set -e

echo "Limpiando instalaciones y cachés anteriores..."
rm -rf ~/.local/moss ~/.local/share/moss ~/.cache/moss ~/.config/moss
rm -f ~/.local/bin/moss

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/ezequielgk/Moss/releases/latest/download/moss-linux-amd64.tar.gz"
curl -sL "$URL" | tar -xz -C "$TMP_DIR"

MOSS_VER=$("$TMP_DIR/moss" -V | awk '{print $2}')
echo "Instalando Moss (v${MOSS_VER}) de forma limpia..."

# Sincronizamos silenciosamente para bajar el último índice
"$TMP_DIR/moss" -q update || true

# Instalamos usando el nombre para que verifique el SHA256 contra packages.tsv
if ! "$TMP_DIR/moss" install -q -f moss; then
    echo "Error durante la instalación."
    exit 1
fi

MOSS_BIN_DIR="$HOME/.local/moss/bin"

setup_path() {
    local rc_file="$1"
    if [ -f "$rc_file" ] && ! grep -q "$MOSS_BIN_DIR" "$rc_file"; then
        echo "" >> "$rc_file"
        echo "# Moss Package Manager" >> "$rc_file"
        echo "export PATH=\"$MOSS_BIN_DIR:\$PATH\"" >> "$rc_file"
        echo "Añadido $MOSS_BIN_DIR a $rc_file"
    fi
}

setup_fish_path() {
    local fish_config="$HOME/.config/fish/config.fish"
    if command -v fish >/dev/null 2>&1; then
        mkdir -p "$HOME/.config/fish"
        if [ ! -f "$fish_config" ] || ! grep -q "$MOSS_BIN_DIR" "$fish_config"; then
            echo "" >> "$fish_config"
            echo "# Moss Package Manager" >> "$fish_config"
            echo "set -gx PATH \"$MOSS_BIN_DIR\" \$PATH" >> "$fish_config"
            echo "Añadido $MOSS_BIN_DIR a $fish_config"
        fi
    fi
}

echo "Configurando variables de entorno..."
setup_path "$HOME/.bashrc"
setup_path "$HOME/.zshrc"
setup_fish_path

echo "¡Moss se ha instalado con éxito!"
echo ""
echo "Por favor, reinicia tu terminal o ejecuta:"
if command -v fish >/dev/null 2>&1 && [ "$(basename "$SHELL")" = "fish" ]; then
    echo "    source ~/.config/fish/config.fish"
elif [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    echo "    source ~/.zshrc"
else
    echo "    source ~/.bashrc"
fi
echo ""
