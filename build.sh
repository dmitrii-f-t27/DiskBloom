#!/bin/zsh
# Build DiskBloom.app for direct download (ad-hoc signed, not sandboxed).
#
#   ./build.sh            -> ./DiskBloom.app (the GitHub release build)
#   ./build.sh --sandbox  -> ./.build/Sandbox/DiskBloom.app, ad-hoc signed with the
#                            Mac App Store entitlements, for testing the sandboxed flow locally
#
# The Mac App Store build itself is produced by DiskBloom.xcodeproj (see AppStore/README.md).
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/.build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODE="${1:-direct}"

case "$MODE" in
  direct) APP_PATH="$ROOT_DIR/DiskBloom.app" ;;
  --sandbox) APP_PATH="$BUILD_DIR/Sandbox/DiskBloom.app" ;;
  *) print -u2 "Usage: ./build.sh [--sandbox]"; exit 2 ;;
esac

config_value() {
  local value
  value="$(/usr/bin/sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$ROOT_DIR/Config/Version.xcconfig" | /usr/bin/tail -1)"
  if [[ -z "$value" ]]; then
    print -u2 "Missing $1 in Config/Version.xcconfig"
    exit 2
  fi
  print -r -- "$value"
}
MARKETING_VERSION="$(config_value MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(config_value CURRENT_PROJECT_VERSION)"
PRODUCT_BUNDLE_IDENTIFIER="$(config_value PRODUCT_BUNDLE_IDENTIFIER)"

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

/usr/bin/sed \
  -e "s|\$(EXECUTABLE_NAME)|DiskBloom|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$PRODUCT_BUNDLE_IDENTIFIER|g" \
  -e "s|\$(MARKETING_VERSION)|$MARKETING_VERSION|g" \
  -e "s|\$(CURRENT_PROJECT_VERSION)|$CURRENT_PROJECT_VERSION|g" \
  "$ROOT_DIR/Info.plist" > "$APP_PATH/Contents/Info.plist"
if /usr/bin/grep -q '\$(' "$APP_PATH/Contents/Info.plist"; then
  print -u2 "Unresolved build variable in Info.plist"
  exit 2
fi
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

# The icon PNGs are shared with the Xcode asset catalog.
ICONSET="$BUILD_DIR/AppIcon.iconset"
/bin/rm -rf "$ICONSET"
/bin/mkdir -p "$ICONSET"
/bin/cp "$ROOT_DIR"/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
/bin/cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_PATH/Contents/Resources/"

if [[ "$MODE" == "--sandbox" ]]; then
  /usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT_DIR/Config/DiskBloom-AppStore.entitlements" "$APP_PATH"
else
  /usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

print "$APP_PATH"
