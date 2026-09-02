#!/usr/bin/env bash
# scree installer, downloads scree.sh into ~/.local/bin and makes it executable.
# Usage: curl -fsSL https://raw.githubusercontent.com/vishwaksena-dingari/scree/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/vishwaksena-dingari/scree/main/scree.sh"
DEST_DIR="${HOME}/.local/bin"
DEST="${DEST_DIR}/scree"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "scree is macOS-only. Aborting." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
echo "Downloading scree → $DEST"
curl -fsSL "$REPO_RAW" -o "$DEST"
chmod +x "$DEST"

echo "✅ Installed. Make sure ~/.local/bin is on your PATH, then run:"
echo "     scree --report      # see what's eating your disk (deletes nothing)"
echo "     scree               # preview the safe cleanup"
echo "     scree --apply       # actually reclaim space"
echo "     scree --uninstall   # remove scree's logs + script (keeps your ignore list; --purge removes that too)"
