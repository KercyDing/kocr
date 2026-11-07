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
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>kocr captures a screen region to recognize text.</string>
</dict>
</plist>
EOF

xattr -cr "$app_dir" 2>/dev/null || true

identities() {
    security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/^[[:space:]]*[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p'
}

pick_identity() {
    identities | grep -m1 -F "$1" || true
}

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY=$(pick_identity "Developer ID Application")
    [[ -n "${CODESIGN_IDENTITY}" ]] || CODESIGN_IDENTITY=$(pick_identity "Apple Development")
    [[ -n "${CODESIGN_IDENTITY}" ]] || CODESIGN_IDENTITY=$(pick_identity "Mac Developer")
    if [[ -z "${CODESIGN_IDENTITY}" ]]; then
        found=()
        while IFS= read -r name; do
            found+=("$name")
        done < <(identities)
        if [[ ${#found[@]} -eq 1 ]]; then
            CODESIGN_IDENTITY="${found[0]}"
        elif [[ ${#found[@]} -gt 1 ]]; then
            echo "multiple signing identities; set CODESIGN_IDENTITY to one of:" >&2
            printf '  %s\n' "${found[@]}" >&2
        else
            echo "no valid signing identity; available (including invalid):" >&2
            security find-identity -p codesigning 2>&1 | sed 's/^/  /' >&2
        fi
    fi
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$app_dir"
    codesign --verify --deep --strict "$app_dir"
    echo "signed with ${CODESIGN_IDENTITY}"
else
    codesign --force --deep --sign - "$app_dir"
    codesign --verify --deep --strict "$app_dir"
    echo "warning: ad-hoc signed; rebuilding changes the code identity and resets Screen Recording permission" >&2
    echo "         set CODESIGN_IDENTITY to a stable certificate for TCC to persist across builds" >&2
fi

mkdir -p "$out_dir"
archive="kocr-gui-macos-${arch}.zip"
rm -f "${out_dir}/${archive}"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "${out_dir}/${archive}"
shasum -a 256 "${out_dir}/${archive}" > "${out_dir}/${archive}.sha256"
rm -rf "$app_dir"
