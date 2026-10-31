#!/usr/bin/env bash

set -euo pipefail

repo=KercyDing/kdeocr
install_dir=${KOCR_INSTALL_DIR:-"$HOME/.local/bin"}
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
binary_path=$install_dir/kocr
unit_path=$unit_dir/kocr.service
temporary_dir=

fail() {
    echo "kocr installer: $*" >&2
    exit 1
}

require() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        require sudo
        sudo "$@"
    fi
}

distribution_family() {
    [[ -r /etc/os-release ]] || return 1
    local ID= ID_LIKE= identifiers

    # os-release is the system-defined source of distribution identifiers.
    source /etc/os-release
    identifiers=" ${ID,,} ${ID_LIKE,,} "
    case $identifiers in
        *" arch "*) printf '%s\n' arch ;;
        *" debian "* | *" ubuntu "*) printf '%s\n' debian ;;
        *" fedora "* | *" rhel "*) printf '%s\n' fedora ;;
        *) return 1 ;;
    esac
}

install_packages() {
    local family=$1
    shift
    (( $# > 0 )) || return

    echo "Installing missing system packages: $*"
    case $family in
        arch)
            require pacman
            run_as_root pacman -S --needed --noconfirm "$@"
            ;;
        debian)
            require apt-get
            run_as_root apt-get update
            run_as_root apt-get install -y "$@"
            ;;
        fedora)
            require dnf
            run_as_root dnf install -y "$@"
            ;;
        *) fail "unsupported Linux distribution" ;;
    esac
}

install_command_dependencies() {
    local family command_name spectacle_package
    local -a missing=() packages=()

    for command_name in spectacle wl-copy notify-send curl; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing+=("$command_name")
        fi
    done
    (( ${#missing[@]} > 0 )) || return

    family=$(distribution_family) \
        || fail "unsupported Linux distribution; missing commands: ${missing[*]}"
    case $family in
        arch)
            command -v spectacle >/dev/null 2>&1 || packages+=(spectacle)
            command -v wl-copy >/dev/null 2>&1 || packages+=(wl-clipboard)
            command -v notify-send >/dev/null 2>&1 || packages+=(libnotify)
            command -v curl >/dev/null 2>&1 || packages+=(curl)
            ;;
        debian)
            spectacle_package=spectacle
            if command -v apt-cache >/dev/null 2>&1 \
                && apt-cache show kde-spectacle >/dev/null 2>&1; then
                spectacle_package=kde-spectacle
            fi
            command -v spectacle >/dev/null 2>&1 || packages+=("$spectacle_package")
            command -v wl-copy >/dev/null 2>&1 || packages+=(wl-clipboard)
            command -v notify-send >/dev/null 2>&1 || packages+=(libnotify-bin)
            command -v curl >/dev/null 2>&1 || packages+=(curl)
            ;;
        fedora)
            command -v spectacle >/dev/null 2>&1 || packages+=(spectacle)
            command -v wl-copy >/dev/null 2>&1 || packages+=(wl-clipboard)
            command -v notify-send >/dev/null 2>&1 || packages+=(libnotify)
            command -v curl >/dev/null 2>&1 || packages+=(curl)
            ;;
    esac

    install_packages "$family" "${packages[@]}"
    hash -r
    for command_name in "${missing[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 \
            || fail "dependency installer did not provide command: $command_name"
    done
}

install_dependencies() {
    [[ ${KOCR_SKIP_DEPENDENCIES:-0} == 1 ]] && return
    install_command_dependencies
}

select_model() {
    local choice=${KOCR_MODEL:-}

    if [[ -z $choice ]]; then
        echo "Select OCR model:" >&2
        echo "  1) ppocrv6-small-r1   24.8 MiB  Recommended" >&2
        echo "  2) ppocrv6-medium-r1  94.9 MiB" >&2
        echo "  3) ppocrv6-tiny-r1     5.4 MiB" >&2
        if [[ -t 0 ]]; then
            read -r -p "Model [1]: " choice
        fi
    fi

    case ${choice:-1} in
        1 | small | ppocrv6-small-r1) printf '%s\n' ppocrv6-small-r1 ;;
        2 | medium | ppocrv6-medium-r1) printf '%s\n' ppocrv6-medium-r1 ;;
        3 | tiny | ppocrv6-tiny-r1) printf '%s\n' ppocrv6-tiny-r1 ;;
        *) fail "unknown model: $choice" ;;
    esac
}

select_action() {
    local choice=

    echo "Select action:" >&2
    echo "  1) Install" >&2
    echo "  2) Uninstall" >&2
    if [[ -t 0 ]]; then
        read -r -p "Action [1]: " choice
    fi

    case ${choice:-1} in
        1 | install) printf '%s\n' install ;;
        2 | uninstall) printf '%s\n' uninstall ;;
        *) fail "unknown action: $choice" ;;
    esac
}

download_binary() {
    local machine target latest_url tag version package archive checksum expected actual release_url

    require curl
    require sha256sum
    require tar

    machine=$(uname -m)
    case "$machine" in
        x86_64) target=x86_64-unknown-linux-gnu ;;
        aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
        *) fail "unsupported architecture: $machine" ;;
    esac

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
    actual=$(sha256sum "$archive" | awk '{ print $1 }')
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || fail "release checksum is invalid"
    [[ $actual == "$expected" ]] || fail "release checksum does not match"

    tar -xzf "$archive" -C "$temporary_dir" "$package/kocr"
    printf '%s\n' "$temporary_dir/$package/kocr"
}

install_kocr() {
    local model= source_binary unit_temporary

    require install
    require mktemp
    require realpath
    require systemctl
    systemctl --user show-environment >/dev/null \
        || fail "systemd user session is unavailable"

    temporary_dir=$(mktemp -d)
    trap 'rm -rf -- "$temporary_dir"' EXIT

    if [[ -n ${KOCR_BINARY:-} ]]; then
        [[ -x $KOCR_BINARY ]] || fail "binary is not executable: $KOCR_BINARY"
        source_binary=$(realpath -- "$KOCR_BINARY")
    else
        source_binary=$(download_binary)
    fi

    [[ $binary_path != *$'\n'* && $binary_path != *'"'* ]] \
        || fail "install path contains unsupported characters"
    mkdir -p -- "$install_dir" "$unit_dir"
    install -m 0755 "$source_binary" "$temporary_dir/kocr"
    mv -f -- "$temporary_dir/kocr" "$binary_path"

    install_dependencies
    if [[ ${KOCR_SKIP_MODEL:-0} != 1 ]]; then
        model=$(select_model)
        if ! "$binary_path" use "$model" >/dev/null 2>&1; then
            "$binary_path" install "$model"
        fi
        "$binary_path" use "$model"
    fi

    unit_temporary=$(mktemp --tmpdir="$unit_dir" .kocr.service.XXXXXX)
    cat > "$unit_temporary" <<EOF
[Unit]
Description=KOCR global shortcut daemon
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=dbus
BusName=io.github.KercyDing.kocr
ExecStart="$binary_path" daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF
    chmod 0644 "$unit_temporary"
    mv -f -- "$unit_temporary" "$unit_path"

    rm -f -- "${XDG_DATA_HOME:-"$HOME/.local/share"}/applications/kocr-capture.desktop"
    systemctl --user daemon-reload
    systemctl --user enable kocr.service
    systemctl --user restart kocr.service

    echo "Installed kocr to $binary_path"
    if [[ -n $model ]]; then
        echo "Model: $model"
    fi
    echo "Shortcuts: Alt+1 (copy), Alt+2 (OCR), Alt+3 (one-line OCR)"
}

uninstall_kocr() {
    if [[ -f $unit_path ]]; then
        systemctl --user disable --now kocr.service
        rm -f -- "$unit_path"
        systemctl --user daemon-reload
    fi

    if command -v busctl >/dev/null 2>&1; then
        busctl --user call \
            org.kde.kglobalaccel \
            /kglobalaccel \
            org.kde.KGlobalAccel \
            unregister \
            ss \
            kocr \
            capture-ocr \
            >/dev/null 2>&1 || true
        busctl --user call \
            org.kde.kglobalaccel \
            /kglobalaccel \
            org.kde.KGlobalAccel \
            unregister \
            ss \
            kocr \
            capture-ocr-oneline \
            >/dev/null 2>&1 || true
    fi

    rm -f -- "$binary_path"
    rm -f -- "${XDG_DATA_HOME:-"$HOME/.local/share"}/applications/kocr-capture.desktop"
    echo "Uninstalled kocr"
}

usage() {
    echo "Usage: $0 [install|uninstall]" >&2
}

if (( $# > 1 )); then
    usage
    exit 2
fi

action=${1:-}
if [[ -z $action ]]; then
    action=$(select_action)
fi

case $action in
    install)
        install_kocr
        ;;
    uninstall)
        uninstall_kocr
        ;;
    *)
        fail "unknown action: $action"
        ;;
esac
