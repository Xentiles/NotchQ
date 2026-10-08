#!/bin/zsh
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
NOTCHQ_APP="$NOTCHQ_ROOT/dist/NotchQ.app"
[[ -d "$NOTCHQ_APP" ]] || zsh "$NOTCHQ_ROOT/scripts/build.sh"
NOTCHQ_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NOTCHQ_APP/Contents/Info.plist")
NOTCHQ_STAGE="$NOTCHQ_ROOT/work/dmg-stage"
NOTCHQ_IMAGE="$NOTCHQ_ROOT/releases/NotchQ-$NOTCHQ_VERSION-universal-unsigned-preview.dmg"
mkdir -p "$NOTCHQ_ROOT/releases"
rm -rf "$NOTCHQ_STAGE"
mkdir -p "$NOTCHQ_STAGE"
ditto "$NOTCHQ_APP" "$NOTCHQ_STAGE/NotchQ.app"
ln -s /Applications "$NOTCHQ_STAGE/Applications"
cat > "$NOTCHQ_STAGE/Read Me.txt" <<'TEXT'
NotchQ — AI quota meter

Unsigned preview: not Developer ID signed or notarized by Apple.
macOS may block a downloaded copy. Review Apple's guidance:
https://support.apple.com/en-us/102445

Drag NotchQ.app into Applications, then open the installed app once.
Review its Settings and optionally enable Start at login.
Default placement is beside a usable MacBook notch, with menu-bar fallback.

Codex uses your installed Codex sign-in. Claude requires its optional
Claude Code usage connection on supported plans; Free percentages are unavailable.
TEXT
hdiutil create -volname "NotchQ" -srcfolder "$NOTCHQ_STAGE" -format UDZO -ov "$NOTCHQ_IMAGE"
hdiutil verify "$NOTCHQ_IMAGE"
(cd "$NOTCHQ_ROOT/releases" && shasum -a 256 "${NOTCHQ_IMAGE:t}" > "${NOTCHQ_IMAGE:t}.sha256")
echo "Created $NOTCHQ_IMAGE"
