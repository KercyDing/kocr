#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 <deb|rpm> <package> <version> <target> <backend> <bin-dir> <out-dir>" >&2
    echo "backend: cli|gui" >&2
    exit 2
}

[[ $# -eq 7 ]] || usage

format=$1
package=$2
version=$3
target=$4
backend=$5
bin_dir=$(cd -- "$6" && pwd)
out_dir=$7

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
desktop_file=$script_dir/kocr-gui.desktop

case $target in
    x86_64-unknown-linux-gnu)
        deb_arch=amd64
        rpm_arch=x86_64
        ;;
    aarch64-unknown-linux-gnu)
        deb_arch=arm64
        rpm_arch=aarch64
        ;;
    *)
        echo "unsupported target: $target" >&2
        exit 1
        ;;
esac

case $backend in
    cli)
        summary="Offline OCR command-line tool"
        deb_depends="libc6, libgcc-s1"
        deb_recommends=""
        rpm_requires="glibc, libgcc"
        rpm_recommends=""
        conflicts=""
        ;;
    gui)
        summary="KOCR desktop app"
        deb_depends="libc6, libgcc-s1, libgtk-3-0, libayatana-appindicator3-1 | libappindicator3-1, libxkbcommon0, libwayland-client0, libgl1, libx11-6, libxrandr2, libxi6, libxcursor1, libxinerama1, spectacle | kde-spectacle, wl-clipboard, libnotify-bin"
        deb_recommends=""
        rpm_requires="glibc, libgcc, gtk3, libayatana-appindicator-gtk3, libxkbcommon, libwayland-client, mesa-libGL, libX11, libXrandr, libXi, libXcursor, libXinerama, spectacle, wl-clipboard, libnotify"
        rpm_recommends=""
        conflicts=""
        ;;
    *)
        echo "unknown backend: $backend" >&2
        exit 1
        ;;
esac

copy_binaries() {
    local root=$1

    mkdir -p "$root/usr/bin"
    if [[ $backend == cli ]]; then
        install -m 0755 "$bin_dir/kocr" "$root/usr/bin/kocr"
    else
        install -m 0755 "$bin_dir/kocr-gui" "$root/usr/bin/kocr-gui"
        install -D -m 0644 "$desktop_file" "$root/usr/share/applications/kocr-gui.desktop"
        install -D -m 0644 "$repo_dir/kocr-gui/assets/icon.png" "$root/usr/share/pixmaps/kocr.png"
    fi
}

copy_licenses() {
    local root=$1
    local destination=$2

    mkdir -p "$root/$destination"
    install -m 0644 "$repo_dir/LICENSE" "$root/$destination/LICENSE"
    install -m 0644 "$repo_dir/NOTICE" "$root/$destination/NOTICE"
    install -m 0644 "$repo_dir/LICENSE-PaddleOCR" "$root/$destination/LICENSE-PaddleOCR"
    install -m 0644 "$repo_dir/LICENSE-SourceHanSans" "$root/$destination/LICENSE-SourceHanSans"
}

build_deb() {
    local root
    root=$(mktemp -d)
    trap 'rm -rf -- "$root"' RETURN

    mkdir -p "$root/DEBIAN"
    chmod 0755 "$root" "$root/DEBIAN"
    copy_binaries "$root"
    copy_licenses "$root" "usr/share/doc/$package"

    local installed_size
    installed_size=$(du -sk "$root" | awk '{print $1}')

    {
        echo "Package: $package"
        echo "Version: $version"
        echo "Architecture: $deb_arch"
        echo "Maintainer: KercyDing <dkx215417@gmail.com>"
        echo "Section: utils"
        echo "Priority: optional"
        echo "Installed-Size: $installed_size"
        echo "Depends: $deb_depends"
        if [[ -n $deb_recommends ]]; then
            echo "Recommends: $deb_recommends"
        fi
        if [[ -n $conflicts ]]; then
            echo "Conflicts: $conflicts"
        fi
        if [[ $backend != cli ]]; then
            echo "Provides: kocr-gui"
        fi
        echo "Description: $summary"
        echo " KOCR offline OCR."
    } > "$root/DEBIAN/control"

    mkdir -p "$out_dir"
    dpkg-deb --build --root-owner-group "$root" \
        "$out_dir/${package}_${version}_${deb_arch}.deb"
}

build_rpm() {
    local top spec
    top=$(mktemp -d)
    spec=$top/package.spec
    trap 'rm -rf -- "$top"' RETURN

    {
        echo "Name: $package"
        echo "Version: $version"
        echo "Release: 1"
        echo "Summary: $summary"
        echo "License: Apache-2.0"
        echo "AutoReqProv: no"
        echo "Requires: $rpm_requires"
        if [[ -n $rpm_recommends ]]; then
            echo "Recommends: $rpm_recommends"
        fi
        if [[ -n $conflicts ]]; then
            echo "Conflicts: $conflicts"
        fi
        if [[ $backend != cli ]]; then
            echo "Provides: kocr-gui"
        fi
        echo
        echo "%description"
        echo "KOCR offline OCR."
        echo
        echo "%install"
        if [[ $backend == cli ]]; then
            echo "install -D -m 0755 \"$bin_dir/kocr\" %{buildroot}/usr/bin/kocr"
        else
            echo "install -D -m 0755 \"$bin_dir/kocr-gui\" %{buildroot}/usr/bin/kocr-gui"
            echo "install -D -m 0644 \"$desktop_file\" %{buildroot}/usr/share/applications/kocr-gui.desktop"
            echo "install -D -m 0644 \"$repo_dir/kocr-gui/assets/icon.png\" %{buildroot}/usr/share/pixmaps/kocr.png"
        fi
        echo "install -D -m 0644 \"$repo_dir/LICENSE\" %{buildroot}/usr/share/licenses/$package/LICENSE"
        echo "install -D -m 0644 \"$repo_dir/NOTICE\" %{buildroot}/usr/share/licenses/$package/NOTICE"
        echo "install -D -m 0644 \"$repo_dir/LICENSE-PaddleOCR\" %{buildroot}/usr/share/licenses/$package/LICENSE-PaddleOCR"
        echo "install -D -m 0644 \"$repo_dir/LICENSE-SourceHanSans\" %{buildroot}/usr/share/licenses/$package/LICENSE-SourceHanSans"
        echo
        echo "%files"
        if [[ $backend == cli ]]; then
            echo "/usr/bin/kocr"
        else
            echo "/usr/bin/kocr-gui"
            echo "/usr/share/applications/kocr-gui.desktop"
            echo "/usr/share/pixmaps/kocr.png"
        fi
        echo "/usr/share/licenses/$package/LICENSE"
        echo "/usr/share/licenses/$package/NOTICE"
        echo "/usr/share/licenses/$package/LICENSE-PaddleOCR"
        echo "/usr/share/licenses/$package/LICENSE-SourceHanSans"
    } > "$spec"

    rpmbuild -bb \
        --define "_topdir $top" \
        --define "_rpmdir $top/RPMS" \
        "$spec" >&2

    local rpm
    rpm=$(find "$top/RPMS" -type f -name "*.rpm" | head -n 1)
    [[ -n $rpm ]] || {
        echo "rpm was not produced" >&2
        exit 1
    }
    mkdir -p "$out_dir"
    cp "$rpm" "$out_dir/${package}-${version}-1.${rpm_arch}.rpm"
}

case $format in
    deb) build_deb ;;
    rpm) build_rpm ;;
    *) usage ;;
esac
