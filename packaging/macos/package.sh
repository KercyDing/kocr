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
install -m 0644 LICENSE NOTICE LICENSE-PaddleOCR "$app_dir/Contents/Resources/"
install -m 0644 kocr-gui/assets/fonts/SOURCE-HAN-SANS-LICENSE.txt "$app_dir/Contents/Resources/LICENSE-SourceHanSans"
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
    <key>NSScreenCaptureUsageDescription</key>
    <string>KOCR captures a screen region to recognize text.</string>
</dict>
</plist>
EOF

xattr -cr "$app_dir"

mkdir -p "$out_dir"
dmg_dir="${out_dir}/dmg"
rm -rf "$dmg_dir"
mkdir -p "$dmg_dir"
ditto "$app_dir" "${dmg_dir}/${app_name}"
ln -s /Applications "${dmg_dir}/Applications"

archive="kocr-gui-${version}-${target}.dmg"
hdiutil create -quiet -volname "KOCR ${version}" -srcfolder "$dmg_dir" -ov -format UDZO "${out_dir}/${archive}"
rm -rf "$dmg_dir"
shasum -a 256 "${out_dir}/${archive}" > "${out_dir}/${archive}.sha256"
