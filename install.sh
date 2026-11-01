#!/bin/bash
# Install vpn-split. Copies four scripts and creates a config directory —
# nothing else touches the system until you create a profile.
#
#   ./install.sh                 into ~/.local/bin
#   PREFIX=/usr/local ./install.sh   system-wide (needs sudo)
#
# Uninstall: vpn-split disable <name> for each profile, then delete the four
# scripts and ~/.config/vpn-split.

set -eu

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
SRC="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname -s)" = "Darwin" ] || { echo "This tool is macOS-only." >&2; exit 1; }

mkdir -p "$BIN" "$HOME/.config/vpn-split"

install -m 0755 "$SRC/bin/vpn-split" "$BIN/vpn-split"
for s in vpn-guard.sh vpn-discover.sh vpn-status.sh; do
  install -m 0755 "$SRC/scripts/$s" "$BIN/$s"
done

echo "Installed into $BIN:"
echo "  vpn-split  vpn-guard.sh  vpn-discover.sh  vpn-status.sh"
echo "Profiles live in ~/.config/vpn-split/"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    echo
    echo "$BIN is not on your PATH. Add it:"
    echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && exec zsh"
    ;;
esac

cat <<'EOF'

Next:
  1. Connect the VPN you want to split (its interface cannot be identified
     while it is down).
  2. vpn-split add
  3. vpn-split status

If a VPN refuses to connect, vpn-split doctor tells you which of the three
usual causes you are looking at instead of leaving you to guess.
EOF
