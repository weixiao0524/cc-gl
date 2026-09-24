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
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp Sources/CTOMLPatch/LICENSE "$app/Contents/Resources/tomlplusplus-LICENSE.txt"
# Keychain access is granted to the app's designated requirement. An ad-hoc signature ("-") pins it to
# the binary hash, so every rebuild looks like a new app and the keychain asks again after each update.
# A certificate identity keeps the requirement stable (bundle id + certificate), so "Always Allow" sticks.
# Prefer Developer ID, then Apple Development; select by SHA-1 to avoid ambiguous duplicate names.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(awk '/"Developer ID Application:/ {print $2; exit}' <<<"$identities")"
    [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="$(awk '/"Apple Development:/ {print $2; exit}' <<<"$identities")"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        echo "Signing with: $(grep -F "$SIGN_IDENTITY" <<<"$identities" | sed -E 's/.*"(.*)"/\1/')"
    else
        SIGN_IDENTITY="-"
        echo "WARNING: no code-signing certificate found; using ad-hoc signing." >&2
        echo "WARNING: the keychain will ask for the password once after every update." >&2
    fi
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$app"
codesign --verify --strict "$app"
codesign -d -r- "$app" 2>&1 | grep '^designated' || true
echo "Built: $app"

if [[ "${1:-}" == "--dmg" ]]; then
    staging="$(mktemp -d "${TMPDIR:-/tmp}/cgl-dmg.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/CodexConfig.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Codex 配置" -srcfolder "$staging" -ov -format UDZO "$PWD/dist/CodexConfig.dmg"
    echo "Installer: $PWD/dist/CodexConfig.dmg"
fi
