#!/bin/zsh
# Archive the Mac App Store build of DiskBloom and upload it to App Store Connect.
#
# Before running:
#   1. Sign in to Xcode (Settings → Accounts) with the Apple Developer team that sells the app.
#   2. Create the app record in App Store Connect with bundle ID io.github.dmitrii-f-t27.DiskBloom.
#
# Usage:
#   TEAM_ID=ABCDE12345 ./AppStore/archive-and-upload.sh            # archive and upload
#   TEAM_ID=ABCDE12345 UPLOAD=0 ./AppStore/archive-and-upload.sh   # archive and export a .pkg only
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
: "${TEAM_ID:?Set TEAM_ID to the 10-character Apple Developer Team ID}"
UPLOAD="${UPLOAD:-1}"
ARCHIVE="$ROOT_DIR/.build/DiskBloom.xcarchive"
EXPORT_DIR="$ROOT_DIR/.build/AppStoreExport"
OPTIONS="$ROOT_DIR/.build/ExportOptions.plist"

cd "$ROOT_DIR"
if command -v xcodegen >/dev/null; then
  xcodegen generate --spec project.yml
fi

/bin/rm -rf "$ARCHIVE" "$EXPORT_DIR"
/bin/mkdir -p "$ROOT_DIR/.build"

xcodebuild \
  -project DiskBloom.xcodeproj \
  -scheme DiskBloom \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  archive

/bin/cp "$ROOT_DIR/AppStore/ExportOptions.plist" "$OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$OPTIONS"
if [[ "$UPLOAD" != "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :destination export" "$OPTIONS"
fi

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

if [[ "$UPLOAD" == "1" ]]; then
  print "Uploaded. The build appears in App Store Connect → TestFlight after processing."
else
  print "Exported to $EXPORT_DIR"
fi
