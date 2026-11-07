#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 <amd64|x86_64|arm64|aarch64>" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

case $1 in
    amd64|x86_64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) usage ;;
esac

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
out_dir="$repo_dir/zig-out/bundle/linux"
version=$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' "$repo_dir/build.zig.zon" | head -1)
[[ -n $version ]] || {
    echo "could not read the version from build.zig.zon" >&2
    exit 1
}

package="kocr-$version"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
root="$stage/$package"

install -Dm755 "$repo_dir/zig-out/bin/kocr-gui" "$root/bin/kocr-gui"
install -Dm755 "$script_dir/setup.sh" "$root/setup.sh"
install -Dm644 "$script_dir/kocr-gui.desktop" "$root/share/applications/kocr-gui.desktop"
for size in 16 32 128 256 512; do
    install -Dm644 "$repo_dir/src/gui/icons/linux/$size.png" \
        "$root/share/icons/hicolor/${size}x${size}/apps/kocr.png"
done
install -Dm644 "$repo_dir/README.md" "$root/README.md"
install -Dm644 "$repo_dir/LICENSE" "$root/LICENSE"

mkdir -p "$out_dir"
archive="kocr-$version-linux-$arch.tar.gz"
tar -C "$stage" -czf "$out_dir/$archive" "$package"
( cd "$out_dir" && sha256sum "$archive" > "$archive.sha256" )
echo "$out_dir/$archive"
