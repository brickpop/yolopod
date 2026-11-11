#!/usr/bin/env bash
# Installs the pclaude and pcodex launchers into ~/.local/bin, their shared files into
# ~/.local/share/yolopod, and builds the image they share.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${HOME}/.local/bin"
share="${XDG_DATA_HOME:-$HOME/.local/share}/yolopod"

command -v podman >/dev/null || { echo "podman is not installed — see the README" >&2; exit 1; }

mkdir -p "$bin" "$share"
install -m 0644 "$src/Containerfile" "$share/Containerfile"
install -m 0644 "$src/lib.sh" "$share/lib.sh"
install -m 0755 "$src/pclaude" "$bin/pclaude"
install -m 0755 "$src/pcodex" "$bin/pcodex"
echo "installed: $bin/pclaude"
echo "installed: $bin/pcodex"
echo "installed: $share/Containerfile"
echo "installed: $share/lib.sh"

# Either launcher builds the same image; pin it to what was just installed.
PCLAUDE_HOME="$share" "$bin/pclaude" --pclaude-build "$@"

case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    echo
    echo "NOTE: $bin is not on your PATH. Add it:"
    echo "  bash/zsh:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
    echo "  fish:      fish_add_path ~/.local/bin"
    ;;
esac

echo
echo "Done. Run 'pclaude' or 'pcodex' inside any project directory."
