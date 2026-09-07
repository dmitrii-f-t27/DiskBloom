#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_PATH="$ROOT_DIR/DiskBloom.app"
BUILD_DIR="$ROOT_DIR/.build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "$APP_PATH" != "$ROOT_DIR/DiskBloom.app" ]]; then
  print -u2 "Unexpected app output path"
  exit 2
fi

/bin/rm -rf "$APP_PATH"
/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$BUILD_DIR"

xcrun swiftc \
  -emit-executable \
  -parse-as-library \
  -O \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework Combine \
  -framework Security \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$APP_PATH/Contents/MacOS/DiskBloom"

/bin/cp "$ROOT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

ICON_PNG="$BUILD_DIR/DiskBloomIcon.png"
ICONSET="$BUILD_DIR/DiskBloom.iconset"
/bin/rm -rf "$ICONSET"
/bin/mkdir -p "$ICONSET"

if /usr/bin/sips -s format png "$ROOT_DIR/Resources/DiskBloomIcon.svg" --out "$ICON_PNG" >/dev/null 2>&1; then
  for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$ICON_PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$ICON_PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/DiskBloom.icns"
else
  print -u2 "Warning: app icon conversion was skipped"
fi

/usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

print "$APP_PATH"
