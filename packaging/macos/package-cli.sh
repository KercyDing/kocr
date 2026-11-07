#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 <arch>" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

arch=$1

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
out_dir="$repo_dir/zig-out/bundle/macos"
version=$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' "$repo_dir/build.zig.zon" | head -1)
[[ -n $version ]] || {
    echo "could not read the version from build.zig.zon" >&2
    exit 1
}

package="kocr-cli-$version"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
root="$stage/$package"

mkdir -p "$root/bin"
install -m 0755 "$repo_dir/zig-out/bin/kocr" "$root/bin/kocr"
install -m 0644 "$repo_dir/README.md" "$repo_dir/LICENSE" "$root"

mkdir -p "$out_dir"
archive="kocr-cli-$version-macos-${arch}.tar.gz"
rm -f "$out_dir/$archive" "$out_dir/$archive.sha256"
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$out_dir/$archive" "$package"
( cd "$out_dir" && shasum -a 256 "$archive" > "$archive.sha256" )
echo "$out_dir/$archive"
