#!/bin/zsh
set -euo pipefail

# Package an already-built app without rebuilding or changing its signature.
RELEASE_ROOT="${0:A:h}"
RELEASE_APP="$RELEASE_ROOT/DiskBloom.app"
RELEASE_OUTPUT="$RELEASE_ROOT/release"
RELEASE_VERSION="${1:-1.4.0}"
RELEASE_NAME="DiskBloom-${RELEASE_VERSION}-macOS-arm64"

if [[ ! "$RELEASE_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Usage: ./package-release.sh [version, e.g. 1.3.0]"
  exit 2
fi
if [[ ! -d "$RELEASE_APP" || -L "$RELEASE_APP" ]]; then
  print -u2 "Build DiskBloom.app with ./build.sh before packaging."
  exit 2
fi

RELEASE_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")"
if [[ "$RELEASE_VERSION" != "$RELEASE_APP_VERSION" && "$RELEASE_VERSION" != "${RELEASE_APP_VERSION}.0" ]]; then
  print -u2 "Release version $RELEASE_VERSION does not match app version $RELEASE_APP_VERSION."
  exit 2
fi
if [[ "$(/usr/bin/lipo -archs "$RELEASE_APP/Contents/MacOS/DiskBloom")" != "arm64" ]]; then
  print -u2 "This packaging script expects the Apple Silicon (arm64) build."
  exit 2
fi
/usr/bin/codesign --verify --strict --verbose=2 "$RELEASE_APP"

/bin/mkdir -p "$RELEASE_OUTPUT"
for RELEASE_FILENAME in "$RELEASE_NAME.zip" "$RELEASE_NAME.dmg" SHA256SUMS; do
  if [[ -e "$RELEASE_OUTPUT/$RELEASE_FILENAME" || -L "$RELEASE_OUTPUT/$RELEASE_FILENAME" ]]; then
    print -u2 "Refusing to overwrite existing release artifact: $RELEASE_OUTPUT/$RELEASE_FILENAME"
    print -u2 "Move the existing artifacts elsewhere before packaging this version again."
    exit 2
  fi
done

RELEASE_STAGING="$(/usr/bin/mktemp -d /private/tmp/diskbloom-release.XXXXXX)"
cleanup_release_staging() {
  if [[ -n "${RELEASE_STAGING:-}" && "$RELEASE_STAGING" == /private/tmp/diskbloom-release.* && -d "$RELEASE_STAGING" ]]; then
    /bin/rm -r -- "$RELEASE_STAGING"
  fi
}
trap cleanup_release_staging EXIT

/bin/mkdir "$RELEASE_STAGING/volume" "$RELEASE_STAGING/artifacts"
/usr/bin/ditto --norsrc --noextattr --noacl "$RELEASE_APP" "$RELEASE_STAGING/volume/DiskBloom.app"
/bin/ln -s /Applications "$RELEASE_STAGING/volume/Applications"
/usr/bin/ditto --norsrc --noextattr --noacl "$RELEASE_ROOT/packaging/INSTALL.txt" "$RELEASE_STAGING/volume/Read Me.txt"

/usr/bin/ditto --norsrc --noextattr --noacl -c -k --keepParent \
  "$RELEASE_STAGING/volume/DiskBloom.app" "$RELEASE_STAGING/artifacts/$RELEASE_NAME.zip"
/usr/bin/hdiutil create -quiet -format UDZO \
  -volname "DiskBloom $RELEASE_VERSION" \
  -srcfolder "$RELEASE_STAGING/volume" \
  "$RELEASE_STAGING/artifacts/$RELEASE_NAME.dmg"
/usr/bin/hdiutil verify "$RELEASE_STAGING/artifacts/$RELEASE_NAME.dmg"
(
  cd "$RELEASE_STAGING/artifacts"
  /usr/bin/shasum -a 256 "$RELEASE_NAME.zip" "$RELEASE_NAME.dmg" > SHA256SUMS
)
for RELEASE_FILENAME in "$RELEASE_NAME.zip" "$RELEASE_NAME.dmg" SHA256SUMS; do
  /bin/mv -n "$RELEASE_STAGING/artifacts/$RELEASE_FILENAME" "$RELEASE_OUTPUT/$RELEASE_FILENAME"
  if [[ -e "$RELEASE_STAGING/artifacts/$RELEASE_FILENAME" ]]; then
    print -u2 "Could not publish artifact without overwriting: $RELEASE_FILENAME"
    exit 2
  fi
done
print "Release artifacts: $RELEASE_OUTPUT"
print "This packages the existing signature; it does not sign or notarize the app."
