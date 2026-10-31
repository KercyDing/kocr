#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 <version> <target> <out-dir>" >&2
    exit 2
}

[[ $# -eq 3 ]] || usage

version=$1
target=$2
out_dir=$3
bin_dir="target/${target}/release"
app_name="kocr.app"
app_dir="${out_dir}/${app_name}"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 0755 "$bin_dir/kocr-gui" "$app_dir/Contents/MacOS/kocr-gui"
install -m 0644 LICENSE NOTICE LICENSE-PaddleOCR LICENSE-SourceHanSans "$app_dir/Contents/Resources/"
install -m 0644 kocr-gui/assets/icon.icns "$app_dir/Contents/Resources/icon.icns"

cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>kocr-gui</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.KercyDing.kocr</string>
    <key>CFBundleName</key>
    <string>kocr</string>
    <key>CFBundleDisplayName</key>
    <string>kocr</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

xattr -cr "$app_dir"

mkdir -p "$out_dir"
archive="kocr-gui-${version}-${target}.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$app_dir" "${out_dir}/${archive}"
shasum -a 256 "${out_dir}/${archive}" > "${out_dir}/${archive}.sha256"
