#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Chasm installer
#   ./install.sh            — installs to ~/.local/bin  (default)
#   ./install.sh /usr/local — installs to /usr/local/bin
# ---------------------------------------------------------------------------

PREFIX="${1:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building chasm (ReleaseFast)..."
cd "$SCRIPT_DIR"
zig build -Doptimize=ReleaseFast

echo "Installing to $BIN_DIR..."
mkdir -p "$BIN_DIR"
cp zig-out/bin/chasm     "$BIN_DIR/chasm"
cp zig-out/bin/chasm-lsp "$BIN_DIR/chasm-lsp"
chmod +x "$BIN_DIR/chasm" "$BIN_DIR/chasm-lsp"

echo ""
echo "Installed:"
echo "  $BIN_DIR/chasm"
echo "  $BIN_DIR/chasm-lsp"

# Check if BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "  NOTE: $BIN_DIR is not in your PATH."
    echo ""

    SHELL_NAME="$(basename "${SHELL:-bash}")"
    case "$SHELL_NAME" in
        zsh)  RC="$HOME/.zshrc" ;;
        fish) RC="$HOME/.config/fish/config.fish" ;;
        *)    RC="$HOME/.bashrc" ;;
    esac

    echo "  Add it by running:"
    echo ""
    if [[ "$SHELL_NAME" == "fish" ]]; then
        echo "    echo 'fish_add_path $BIN_DIR' >> $RC"
    else
        echo "    echo 'export PATH=\"\$PATH:$BIN_DIR\"' >> $RC"
    fi
    echo "    source $RC"
    echo ""
    echo "  Or for this session only:"
    echo "    export PATH=\"\$PATH:$BIN_DIR\""
fi

echo ""

# ---- Editor extensions -----------------------------------------------------
EXT_SRC="$SCRIPT_DIR/editors/vscode"
EXT_NAME="chasm.chasm-language-0.1.0"

install_extension() {
    local ext_dir="$1"
    local reg="$2"
    if [[ ! -d "$ext_dir" ]]; then return; fi

    mkdir -p "$ext_dir/$EXT_NAME/syntaxes"
    cp "$EXT_SRC/package.json"                          "$ext_dir/$EXT_NAME/package.json"
    cp "$EXT_SRC/language-configuration.json"           "$ext_dir/$EXT_NAME/language-configuration.json"
    cp "$EXT_SRC/syntaxes/chasm.tmLanguage.json"        "$ext_dir/$EXT_NAME/syntaxes/chasm.tmLanguage.json"
    [[ -f "$EXT_SRC/icon.png" ]] && cp "$EXT_SRC/icon.png" "$ext_dir/$EXT_NAME/icon.png"

    # Update registry
    python3 - "$ext_dir/$EXT_NAME" "$reg" <<'PYEOF'
import json, sys, os
ext_path, reg_path = sys.argv[1], sys.argv[2]
if not os.path.exists(reg_path):
    exts = []
else:
    with open(reg_path) as f:
        exts = json.load(f)
exts = [e for e in exts if "chasm" not in str(e.get("identifier",{}).get("id",""))]
exts.append({"identifier":{"id":"chasm.chasm-language"},"version":"0.1.0",
    "location":{"$mid":1,"fsPath":ext_path,"external":f"file://{ext_path}","path":ext_path,"scheme":"file"},
    "relativeLocation":"chasm.chasm-language-0.1.0",
    "metadata":{"isApplicationScoped":False,"isMachineScoped":False,"isBuiltin":False,"installedTimestamp":1773781707291}})
with open(reg_path,"w") as f:
    json.dump(exts,f,indent=2)
PYEOF
    echo "  Extension installed → $ext_dir/$EXT_NAME"
}

install_extension "$HOME/.cursor/extensions"  "$HOME/.cursor/extensions/extensions.json"
install_extension "$HOME/.vscode/extensions"  "$HOME/.vscode/extensions/extensions.json"

echo ""
echo "Done!  Try: chasm --version"
echo "Restart Cursor / VS Code to activate the Chasm extension."
