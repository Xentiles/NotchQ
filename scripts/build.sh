#!/bin/zsh
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
NOTCHQ_MODE="${1:-release}"
NOTCHQ_ARCHITECTURE_LIST="${NOTCHQ_ARCHITECTURES:-arm64 x86_64}"
NOTCHQ_ARCHITECTURES=(${=NOTCHQ_ARCHITECTURE_LIST})
NOTCHQ_APP="$NOTCHQ_ROOT/dist/NotchQ.app"
NOTCHQ_FLAGS=()
if [[ "$NOTCHQ_MODE" == "test" ]]; then
  NOTCHQ_APP="$NOTCHQ_ROOT/dist/NotchQTests.app"
  NOTCHQ_FLAGS=(-D NOTCHQ_TESTING)
fi
mkdir -p "$NOTCHQ_APP/Contents/MacOS" "$NOTCHQ_APP/Contents/Resources" "$NOTCHQ_ROOT/work/build"
cp "$NOTCHQ_ROOT/Info.plist" "$NOTCHQ_APP/Contents/Info.plist"
if [[ "$NOTCHQ_MODE" == "test" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.xentiles.NotchQ.tests' "$NOTCHQ_APP/Contents/Info.plist"
fi
cp "$NOTCHQ_ROOT/Resources/Libron-Regular.ttf" "$NOTCHQ_ROOT/Resources/Libron-LICENSE.txt" "$NOTCHQ_ROOT/Resources/NotchQ.icns" "$NOTCHQ_APP/Contents/Resources/"
NOTCHQ_SOURCES=("$NOTCHQ_ROOT"/Source/**/*.swift)
if [[ "$NOTCHQ_MODE" == "test" ]]; then NOTCHQ_SOURCES+=("$NOTCHQ_ROOT"/Tests/*.swift); fi
NOTCHQ_BINARIES=()
for NOTCHQ_ARCH in $NOTCHQ_ARCHITECTURES; do
  NOTCHQ_BINARY="$NOTCHQ_ROOT/work/build/NotchQ-$NOTCHQ_MODE-$NOTCHQ_ARCH"
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$NOTCHQ_ARCH-apple-macos13.0" \
    -module-cache-path "$NOTCHQ_ROOT/work/module-cache" "${NOTCHQ_FLAGS[@]}" "${NOTCHQ_SOURCES[@]}" \
    -framework AppKit -framework ServiceManagement -framework CoreText -framework QuartzCore -framework CryptoKit -o "$NOTCHQ_BINARY"
  NOTCHQ_BINARIES+=("$NOTCHQ_BINARY")
done
if (( ${#NOTCHQ_BINARIES} > 1 )); then
  xcrun lipo -create "${NOTCHQ_BINARIES[@]}" -output "$NOTCHQ_APP/Contents/MacOS/NotchQ"
else
  cp "$NOTCHQ_BINARIES[1]" "$NOTCHQ_APP/Contents/MacOS/NotchQ"
fi
if [[ -n "${NOTCHQ_SIGNING_IDENTITY:-}" && "$NOTCHQ_MODE" != "test" ]]; then
  codesign --force --options runtime --timestamp --sign "$NOTCHQ_SIGNING_IDENTITY" "$NOTCHQ_APP"
else
  codesign --force --sign - "$NOTCHQ_APP"
fi
codesign --verify --strict "$NOTCHQ_APP"
echo "Built $NOTCHQ_APP"
