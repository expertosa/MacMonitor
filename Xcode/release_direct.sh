#!/bin/bash
# Builds the direct-download edition (full features + widget), signs it with Developer ID,
# notarizes and staples it, and packages MacMonitor-<version>.dmg and .zip in Xcode/build/.
#
# Requirements: Xcode signed in to team NWPTRYJ9FL with a "Developer ID Application" certificate,
# and XcodeGen (brew install xcodegen).
# Notarization credentials (one of):
#   NOTARY_PROFILE=<name>   a profile saved with: xcrun notarytool store-credentials <name>
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   App Store Connect API key (.p8 path, key id, issuer id)
# Without credentials the app is still signed but not notarized (SKIP_NOTARIZE=1 to silence the warning).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)}"
case "$BUILD_NUMBER" in
    ''|*[!0-9]*|0*) echo "CFBundleVersion must be a short sequential integer from project.yml (got '${BUILD_NUMBER:-empty}')" >&2; exit 1 ;;
esac
if [[ ${#BUILD_NUMBER} -gt 4 ]]; then
    echo "CFBundleVersion must be a short sequential integer, not a timestamp (got '$BUILD_NUMBER')" >&2
    exit 1
fi
OUT="$PWD/build"
ARCHIVE="$OUT/MacMonitor-Direct.xcarchive"
EXPORT="$OUT/export-direct"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"

xcodegen generate
xcodebuild -project MacMonitor.xcodeproj -scheme MacMonitorDirect -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions-DeveloperID.plist \
    -exportPath "$EXPORT" -allowProvisioningUpdates
APP="$EXPORT/MacMonitor.app"
codesign --verify --deep --strict --verbose=1 "$APP"

notarize() {   # $1 = file to submit
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [[ -n "${NOTARY_KEY:-}" ]]; then
        xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    else
        return 1
    fi
}

ZIP="$OUT/MacMonitor-$VERSION.zip"
DMG="$OUT/MacMonitor-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
NOTARIZED=0
if notarize "$ZIP"; then
    xcrun stapler staple "$APP"
    NOTARIZED=1
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip the stapled app
elif [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "warning: no notarization credentials; users will see a Gatekeeper warning" >&2
fi

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacMonitor $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "Developer ID Application" "$DMG" || true
if [[ $NOTARIZED == 1 ]]; then notarize "$DMG" && xcrun stapler staple "$DMG"; fi

echo
echo "Built:   $DMG"
echo "         $ZIP"
echo "sha256:  $(shasum -a 256 "$DMG" | cut -d' ' -f1)  (paste into Casks/macmonitor.rb)"
