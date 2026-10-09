#!/bin/zsh
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
NOTCHQ_APP="$NOTCHQ_ROOT/dist/NotchQ.app"
NOTCHQ_FAIL() { echo "package-dmg: $1" >&2; exit 1; }

# Always package a fresh universal release build, never a stale dist/ copy.
rm -rf "$NOTCHQ_APP"
NOTCHQ_ARCHITECTURES="arm64 x86_64" zsh "$NOTCHQ_ROOT/scripts/build.sh"
NOTCHQ_BINARY="$NOTCHQ_APP/Contents/MacOS/NotchQ"
NOTCHQ_PLIST="$NOTCHQ_APP/Contents/Info.plist"
NOTCHQ_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NOTCHQ_PLIST")

# Release checks: anything a downloaded copy on another Mac depends on.
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NOTCHQ_PLIST") == io.github.xentiles.NotchQ ]] || NOTCHQ_FAIL "unexpected bundle identifier"
NOTCHQ_ARCHS=" $(lipo -archs "$NOTCHQ_BINARY") "
[[ "$NOTCHQ_ARCHS" == *" arm64 "* && "$NOTCHQ_ARCHS" == *" x86_64 "* ]] || NOTCHQ_FAIL "binary is not universal:$NOTCHQ_ARCHS"
NOTCHQ_MINOS=$(vtool -show-build "$NOTCHQ_BINARY" | awk '$1 == "minos" { print $2 }' | sort -u)
[[ "$NOTCHQ_MINOS" == "13.0" ]] || NOTCHQ_FAIL "minimum macOS is '$NOTCHQ_MINOS', expected 13.0"
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$NOTCHQ_PLIST") == "13.0" ]] || NOTCHQ_FAIL "Info.plist minimum macOS mismatch"
codesign --verify --strict --deep "$NOTCHQ_APP" || NOTCHQ_FAIL "code signature invalid"
for NOTCHQ_RESOURCE in Libron-Regular.ttf Libron-LICENSE.txt NotchQ.icns; do
  [[ -f "$NOTCHQ_APP/Contents/Resources/$NOTCHQ_RESOURCE" ]] || NOTCHQ_FAIL "missing resource $NOTCHQ_RESOURCE"
done
echo "Release checks passed: version $NOTCHQ_VERSION, archs$NOTCHQ_ARCHS, macOS $NOTCHQ_MINOS+"

NOTCHQ_STAGE="$NOTCHQ_ROOT/work/dmg-stage"
# Public releases are labelled B(eta)v<version>, e.g. Bv0.2.0.
NOTCHQ_IMAGE="$NOTCHQ_ROOT/releases/NotchQ-Bv$NOTCHQ_VERSION-universal-unsigned.dmg"
NOTCHQ_WORKING="$NOTCHQ_ROOT/work/dmg-working.dmg"
mkdir -p "$NOTCHQ_ROOT/releases"
rm -rf "$NOTCHQ_STAGE" "$NOTCHQ_WORKING"
mkdir -p "$NOTCHQ_STAGE"
ditto "$NOTCHQ_APP" "$NOTCHQ_STAGE/NotchQ.app"
ln -s /Applications "$NOTCHQ_STAGE/Applications"
cat > "$NOTCHQ_STAGE/Read Me.txt" <<'TEXT'
NotchQ — AI quota meter

INSTALL
1. Drag NotchQ onto the Applications folder in this window.
2. Open NotchQ from your Applications folder.
   macOS says it cannot verify NotchQ. Click Done (not Move to Bin).
3. Open System Settings → Privacy & Security, scroll to Security,
   and click Open Anyway next to the NotchQ message. Confirm with
   Open Anyway (and your password if asked).
   On macOS 13 or 14 you can instead Control-click NotchQ in
   Applications, choose Open, then click Open.
You only need to do this once for each new version.

Why: this beta is not yet notarized by Apple. Apple's guidance:
https://support.apple.com/en-us/102445

FIRST RUN
- Settings opens automatically. Codex and Claude are both on.
- NotchQ finds your installed Codex and Claude Code by itself and uses
  their existing sign-ins. It never sees your password.
- Claude percentages need Claude Code signed in with Pro or Max.
- Codex updates every 10 seconds. Claude updates once a minute,
  because Claude's usage service limits frequent checks.
- Not detected? Use Choose CLI… in Settings. Not using one? Untick it.
- Start at login is optional.
TEXT

# Writable image first so Finder can save the drag-to-Applications layout.
hdiutil create -volname "NotchQ" -srcfolder "$NOTCHQ_STAGE" -fs HFS+ -format UDRW -ov "$NOTCHQ_WORKING" >/dev/null
if [[ -d /Volumes/NotchQ ]]; then
  echo "warning: another NotchQ volume is mounted; skipping Finder layout" >&2
else
  NOTCHQ_DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$NOTCHQ_WORKING" | awk '/\/Volumes\/NotchQ$/ { print $1 }')
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 &
tell application "Finder"
  tell disk "NotchQ"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 500}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set position of item "NotchQ.app" of container window to {150, 160}
    set position of item "Applications" of container window to {410, 160}
    set position of item "Read Me.txt" of container window to {280, 300}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  NOTCHQ_SCRIPT=$!
  # Finder automation can wait on a permission prompt; never hang the release build.
  for NOTCHQ_TICK in {1..60}; do kill -0 $NOTCHQ_SCRIPT 2>/dev/null || break; sleep 0.5; done
  if kill -0 $NOTCHQ_SCRIPT 2>/dev/null; then
    kill $NOTCHQ_SCRIPT 2>/dev/null || true
    echo "warning: Finder layout timed out (allow Automation → Finder for this terminal); using the default layout" >&2
  elif ! wait $NOTCHQ_SCRIPT; then
    echo "warning: Finder layout was not applied; using the default layout" >&2
  fi
  sync
  hdiutil detach "$NOTCHQ_DEVICE" -quiet || hdiutil detach "$NOTCHQ_DEVICE" -force -quiet
fi
hdiutil convert "$NOTCHQ_WORKING" -format UDZO -imagekey zlib-level=9 -ov -o "$NOTCHQ_IMAGE" >/dev/null
rm -f "$NOTCHQ_WORKING"
hdiutil verify "$NOTCHQ_IMAGE"
(cd "$NOTCHQ_ROOT/releases" && shasum -a 256 "${NOTCHQ_IMAGE:t}" > "${NOTCHQ_IMAGE:t}.sha256")
echo "Created $NOTCHQ_IMAGE"
