#!/bin/sh
set -e

echo "Limpiando instalaciones y cachés anteriores..."
rm -rf ~/.local/belka ~/.local/share/belka ~/.cache/belka ~/.config/belka
rm -f ~/.local/bin/belka

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/ezequielgk/Belka/releases/latest/download/belka-linux-amd64.tar.gz"
curl -sL "$URL" | tar -xz -C "$TMP_DIR"
chmod +x "$TMP_DIR/belka"

BELKA_VER=$("$TMP_DIR/belka" -V | awk '{print $2}')
echo "Instalando Belka (v${BELKA_VER}) de forma limpia..."

# Sincronizamos silenciosamente para bajar el último índice
"$TMP_DIR/belka" -q update || true

# Instalamos usando el nombre para que verifique el SHA256 contra packages.tsv
if ! "$TMP_DIR/belka" install -q -f belka; then
    echo "Error durante la instalación."
    exit 1
fi

BELKA_BIN_DIR="$HOME/.local/belka/bin"

setup_path() {
    local rc_file="$1"
    if [ -f "$rc_file" ] && ! grep -q "$BELKA_BIN_DIR" "$rc_file"; then
        echo "" >> "$rc_file"
        echo "# Belka Package Manager" >> "$rc_file"
        echo "export PATH=\"$BELKA_BIN_DIR:\$PATH\"" >> "$rc_file"
        echo "Añadido $BELKA_BIN_DIR a $rc_file"
    fi
}

setup_fish_path() {
    local fish_config="$HOME/.config/fish/config.fish"
    if command -v fish >/dev/null 2>&1; then
        mkdir -p "$HOME/.config/fish"
        if [ ! -f "$fish_config" ] || ! grep -q "$BELKA_BIN_DIR" "$fish_config"; then
            echo "" >> "$fish_config"
            echo "# Belka Package Manager" >> "$fish_config"
            echo "set -gx PATH \"$BELKA_BIN_DIR\" \$PATH" >> "$fish_config"
            echo "Añadido $BELKA_BIN_DIR a $fish_config"
        fi
    fi
}

echo "Configurando variables de entorno..."
setup_path "$HOME/.bashrc"
setup_path "$HOME/.zshrc"
setup_fish_path

echo "¡Belka se ha instalado con éxito!"
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
