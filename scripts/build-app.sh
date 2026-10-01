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
# ModelTrace reference fingerprints (MIT) for the local detection mode.
cp Sources/CodexConfigCore/Resources/modeltrace_bank.json "$app/Contents/Resources/"
cp Sources/CodexConfigCore/Resources/ModelTrace-LICENSE.txt "$app/Contents/Resources/"
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
    volume="Codex 配置"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/cgl-dmg.XXXXXX")"
    rw_image="$staging.rw.dmg"
    mount_point=""
    trap 'if [[ -n "$mount_point" ]]; then hdiutil detach "$mount_point" -quiet 2>/dev/null || true; fi; rm -rf "$staging" "$rw_image"' EXIT
    ditto "$app" "$staging/CodexConfig.app"
    ln -s /Applications "$staging/Applications"
    # Retina-aware window background; layout constants are shared with generate-dmg-background.swift.
    mkdir -p "$staging/.background" .build/dmg-background
    swift scripts/generate-dmg-background.swift .build/dmg-background
    tiffutil -cathidpicheck .build/dmg-background/background.png .build/dmg-background/background@2x.png \
        -out "$staging/.background/background.tiff" >/dev/null 2>&1
    cp Resources/AppIcon.icns "$staging/.VolumeIcon.icns"

    # Lay the window out in a writable image, then compress it. Finder addresses the disk by name, so
    # eject earlier mounts of this installer ("Codex 配置 1", …) that would otherwise share it.
    for stale in "/Volumes/$volume" "/Volumes/$volume "*; do
        if [[ -d "$stale" ]]; then hdiutil detach "$stale" -quiet; fi
    done
    hdiutil create -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw_image" >/dev/null
    mount_point="$(hdiutil attach "$rw_image" -readwrite -noverify -noautoopen | awk -F '\t' '/Apple_HFS/ {print $NF}')"
    [[ "$mount_point" == "/Volumes/$volume" ]] || { echo "Unexpected mount point: $mount_point" >&2; exit 1; }
    SetFile -a C "$mount_point"
    # Finder writes the window layout to .DS_Store. Needs Automation permission for Finder; without it
    # the DMG still works, just with Finder's default window.
    if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$volume"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        close
        open
        -- Place icons only after the toolbar is gone (hiding it shifts icons by its height). Support
        -- files go below the visible area so they stay out of sight when Finder shows hidden files.
        set position of item "CodexConfig.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        try
            set position of item ".background" of container window to {170, 620}
        end try
        try
            set position of item ".VolumeIcon.icns" of container window to {490, 620}
        end try
        -- No "update": it deletes .VolumeIcon.icns. Closing the window writes the layout.
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "WARNING: Finder layout skipped (allow Automation for Finder to get the styled window)." >&2
    fi
    rm -rf "$mount_point/.fseventsd"
    sync
    hdiutil detach "$mount_point" -quiet
    mount_point=""
    rm -f "$PWD/dist/CodexConfig.dmg"
    hdiutil convert "$rw_image" -format UDZO -imagekey zlib-level=9 -o "$PWD/dist/CodexConfig.dmg" >/dev/null
    echo "Installer: $PWD/dist/CodexConfig.dmg"
fi
