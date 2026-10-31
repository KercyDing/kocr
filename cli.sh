#!/usr/bin/env bash

set -euo pipefail

repo=KercyDing/kocr
install_dir=${KOCR_INSTALL_DIR:-"$HOME/.local/bin"}
binary_path=$install_dir/kocr
temporary_dir=

fail() {
    echo "kocr installer: $*" >&2
    exit 1
}

require() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

release_target() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) printf '%s\n' x86_64-unknown-linux-gnu ;;
        Linux-aarch64 | Linux-arm64) printf '%s\n' aarch64-unknown-linux-gnu ;;
        Darwin-x86_64) printf '%s\n' x86_64-apple-darwin ;;
        Darwin-arm64) printf '%s\n' aarch64-apple-darwin ;;
        *) fail "unsupported platform: $(uname -s) $(uname -m)" ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        fail "required command not found: sha256sum or shasum"
    fi
}

download_cli() {
    local target tag version package archive checksum release_url expected actual latest_url

    require curl
    require tar

    target=$(release_target)
    if [[ -n ${KOCR_VERSION:-} ]]; then
        tag=v${KOCR_VERSION#v}
    else
        latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/$repo/releases/latest")
        tag=${latest_url##*/}
    fi
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
        || fail "invalid release tag: $tag"

    version=${tag#v}
    package=kocr-$version-$target
    archive=$temporary_dir/$package.tar.gz
    checksum=$archive.sha256
    release_url=https://github.com/$repo/releases/download/$tag

    curl -fL --progress-bar "$release_url/$package.tar.gz" -o "$archive"
    curl -fsSL "$release_url/$package.tar.gz.sha256" -o "$checksum"

    expected=$(awk 'NR == 1 { print $1 }' "$checksum")
    actual=$(sha256_file "$archive")
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || fail "release checksum is invalid"
    [[ $actual == "$expected" ]] || fail "release checksum does not match"

    tar -xzf "$archive" -C "$temporary_dir" "$package"
    printf '%s\n' "$temporary_dir/$package/kocr"
}

install_cli() {
    local source

    require install
    require mktemp

    [[ $binary_path != *$'\n'* && $binary_path != *'"'* ]] \
        || fail "install path contains unsupported characters"

    temporary_dir=$(mktemp -d)
    trap 'rm -rf -- "$temporary_dir"' EXIT

    if [[ -n ${KOCR_BINARY:-} ]]; then
        require realpath
        [[ -x $KOCR_BINARY ]] || fail "binary is not executable: $KOCR_BINARY"
        source=$(realpath -- "$KOCR_BINARY")
    else
        source=$(download_cli)
    fi

    mkdir -p -- "$install_dir"
    install -m 0755 "$source" "$binary_path"

    echo "Installed kocr to $binary_path"
    echo "Install a model with: kocr install 1"
}

uninstall_cli() {
    rm -f -- "$binary_path"
    echo "Uninstalled kocr"
}

usage() {
    echo "Usage: $0 [install|uninstall]" >&2
}

if (( $# > 1 )); then
    usage
    exit 2
fi

case ${1:-install} in
    install)
        install_cli
        ;;
    uninstall)
        uninstall_cli
        ;;
    *)
        fail "unknown action: $1"
        ;;
esac
