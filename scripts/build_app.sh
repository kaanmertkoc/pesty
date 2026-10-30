#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="packaging/Pesty.app"

ARCH="${ARCH:-universal}"
case "$ARCH" in
  native) ARCH_ARGS=(--arch "$(uname -m)") ;;
  arm64|x86_64) ARCH_ARGS=(--arch "$ARCH") ;;
  universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
  *) echo "ARCH must be native, arm64, x86_64, or universal" >&2; exit 1 ;;
esac

echo "==> Building release binary ($ARCH)"
swift build -c release "${ARCH_ARGS[@]}"

BIN="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)/Pesty"
echo "    binary: $BIN"

echo "==> Generating icon"
bash scripts/make_icon.sh >/dev/null

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pesty"
cp packaging/Pesty.icns "$APP/Contents/Resources/Pesty.icns"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Explicitly sign the assembled bundle with a stable designated requirement.
# Without this, each release build only carries Swift's per-binary linker
# signature (a changing CDHash), which makes macOS ask for Accessibility again.
echo "==> Signing $APP"
/usr/bin/codesign --force --sign - --identifier com.greycorelabs.pesty \
  -r='designated => identifier "com.greycorelabs.pesty"' "$APP"

echo "==> Built $APP"
/usr/bin/file "$APP/Contents/MacOS/Pesty"
echo "    version $VERSION ($BUILD)"
