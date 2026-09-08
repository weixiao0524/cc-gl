#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
app="$PWD/dist/CodexConfig.app"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/CodexConfig" "$app/Contents/MacOS/CodexConfig"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    mkdir -p .build/AppIcon.iconset
    swift scripts/generate-icon.swift .build/AppIcon.iconset
    iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Sources/CTOMLPatch/LICENSE "$app/Contents/Resources/tomlplusplus-LICENSE.txt"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$app"
codesign --verify --strict "$app"
echo "Built: $app"

if [[ "${1:-}" == "--dmg" ]]; then
    staging="$(mktemp -d "${TMPDIR:-/tmp}/cgl-dmg.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/CodexConfig.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Codex 配置" -srcfolder "$staging" -ov -format UDZO "$PWD/dist/CodexConfig.dmg"
    echo "Installer: $PWD/dist/CodexConfig.dmg"
fi
