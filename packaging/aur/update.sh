#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "usage: $0 <pkgbase> <pkgver> <asset-name> <asset-url> <sha256> <cli|qt|gtk> <repo>" >&2
    exit 2
fi

pkgbase=$1
pkgver=$2
asset_name=$3
asset_url=$4
sha256=$5
kind=$6
repo=$7

case $kind in
    cli)
        pkgdesc="Offline OCR command-line tool (prebuilt binary)"
        depends="'glibc' 'gcc-libs'"
        provides="'kocr'"
        conflicts="'kocr'"
        deb_doc=kocr
        ;;
    qt)
        pkgdesc="KOCR settings window and shortcut daemon (Qt, prebuilt binary)"
        depends="'glibc' 'gcc-libs' 'qt6-base' 'spectacle' 'wl-clipboard' 'libnotify'"
        provides="'kocr-gui'"
        conflicts="'kocr-gtk-bin'"
        deb_doc=kocr-gui-qt
        ;;
    gtk)
        pkgdesc="KOCR settings window and shortcut daemon (GTK, prebuilt binary)"
        depends="'glibc' 'gcc-libs' 'gtk4' 'spectacle' 'wl-clipboard' 'libnotify'"
        provides="'kocr-gui'"
        conflicts="'kocr-qt-bin'"
        deb_doc=kocr-gui-gtk
        ;;
    *)
        echo "unknown kind: $kind" >&2
        exit 1
        ;;
esac

git clone "ssh://aur@aur.archlinux.org/${pkgbase}.git" aur
cd aur

cat > PKGBUILD <<EOF
pkgname=${pkgbase}
pkgver=${pkgver}
pkgrel=1
pkgdesc='${pkgdesc}'
arch=('x86_64')
url='https://github.com/${repo}'
license=('Apache-2.0')
depends=(${depends})
provides=(${provides})
conflicts=(${conflicts})
source=("${asset_name}::${asset_url}")
sha256sums=('${sha256}')

package() {
  cd "\${srcdir}"
  bsdtar -xf "${asset_name}"
  local data_tar
  data_tar=\$(find . -maxdepth 1 -type f -name 'data.tar.*' | head -n 1)
  bsdtar -xf "\${data_tar}"

  install -Dm644 "usr/share/doc/${deb_doc}/LICENSE" "\${pkgdir}/usr/share/licenses/${pkgbase}/LICENSE"
  install -Dm644 "usr/share/doc/${deb_doc}/NOTICE" "\${pkgdir}/usr/share/licenses/${pkgbase}/NOTICE"
  install -Dm644 "usr/share/doc/${deb_doc}/LICENSE-PaddleOCR" "\${pkgdir}/usr/share/licenses/${pkgbase}/LICENSE-PaddleOCR"
EOF

if [[ $kind == cli ]]; then
    cat >> PKGBUILD <<'EOF'
  install -Dm755 usr/bin/kocr "${pkgdir}/usr/bin/kocr"
}
EOF
else
    cat >> PKGBUILD <<'EOF'
  install -Dm755 usr/bin/kocr-gui "${pkgdir}/usr/bin/kocr-gui"
  install -Dm755 usr/bin/kocr-daemon "${pkgdir}/usr/bin/kocr-daemon"
  install -Dm644 usr/share/applications/kocr-gui.desktop "${pkgdir}/usr/share/applications/kocr-gui.desktop"
}
EOF
fi

cat > .SRCINFO <<EOF
pkgbase = ${pkgbase}
	pkgdesc = ${pkgdesc}
	pkgver = ${pkgver}
	pkgrel = 1
	url = https://github.com/${repo}
	arch = x86_64
	license = Apache-2.0
EOF

for dependency in ${depends//\'/}; do
    printf '\tdepends = %s\n' "${dependency}" >> .SRCINFO
done
for provided in ${provides//\'/}; do
    printf '\tprovides = %s\n' "${provided}" >> .SRCINFO
done
for conflict in ${conflicts//\'/}; do
    printf '\tconflicts = %s\n' "${conflict}" >> .SRCINFO
done

cat >> .SRCINFO <<EOF
	source = ${asset_name}::${asset_url}
	sha256sums = ${sha256}

pkgname = ${pkgbase}
EOF

git add PKGBUILD .SRCINFO

if git diff --cached --quiet; then
    echo "No AUR changes detected"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -m "Update to ${pkgver}"
git push
