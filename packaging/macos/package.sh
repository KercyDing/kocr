#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 <arch> <out-dir>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage

arch=$1
out_dir=$2
version=$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)
app_name="kocr.app"
app_dir="${out_dir}/${app_name}"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 0755 zig-out/bin/kocr-gui "$app_dir/Contents/MacOS/kocr-gui"
install -m 0644 README.md LICENSE "$app_dir/Contents/Resources/"

cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>kocr-gui</string>
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
    <string>kocr captures a screen region to recognize text.</string>
</dict>
</plist>
EOF

xattr -cr "$app_dir" 2>/dev/null || true

mkdir -p "$out_dir"
archive="kocr-gui-macos-${arch}.zip"
rm -f "${out_dir}/${archive}"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "${out_dir}/${archive}"
shasum -a 256 "${out_dir}/${archive}" > "${out_dir}/${archive}.sha256"
rm -rf "$app_dir"
