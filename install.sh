#!/usr/bin/env bash
# dehoard installer, downloads dehoard.sh into ~/.local/bin and makes it executable.
# Usage: curl -fsSL https://raw.githubusercontent.com/vishwaksena-dingari/dehoard/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/vishwaksena-dingari/dehoard/main/dehoard.sh"
DEST_DIR="${HOME}/.local/bin"
DEST="${DEST_DIR}/dehoard"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "dehoard is macOS-only. Aborting." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
echo "Downloading dehoard → $DEST"
curl -fsSL "$REPO_RAW" -o "$DEST"
chmod +x "$DEST"

echo "✅ Installed. Make sure ~/.local/bin is on your PATH, then run:"
echo "     dehoard --report      # see what's eating your disk (deletes nothing)"
echo "     dehoard               # preview the safe cleanup"
echo "     dehoard --apply       # actually reclaim space"
