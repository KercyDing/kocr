#!/usr/bin/env sh
# Installs the bundled kocr-gui binary, desktop entry, and icons.
#
#   ./setup.sh                    # into ~/.local
#   PREFIX=/usr ./setup.sh        # into /usr (as root)
set -eu

prefix=${PREFIX:-"$HOME/.local"}
data="$prefix/share"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

install -Dm755 "$here/bin/kocr-gui" "$prefix/bin/kocr-gui"
install -Dm644 "$here/share/applications/kocr-gui.desktop" "$data/applications/kocr-gui.desktop"
for size in 16 32 128 256 512; do
    install -Dm644 "$here/share/icons/hicolor/${size}x${size}/apps/kocr.png" \
        "$data/icons/hicolor/${size}x${size}/apps/kocr.png"
done

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$data/applications" >/dev/null 2>&1 || true
fi

echo "installed kocr-gui into $prefix/bin"
