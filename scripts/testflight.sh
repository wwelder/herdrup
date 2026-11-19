#!/usr/bin/env bash
#
# Archive the Herdr (Herdrup) iOS app for App Store / TestFlight and, optionally,
# upload it. Runs on the MAC (needs Xcode + xcodegen) — it cannot run on Linux,
# where the app is authored, so this script IS the archive lane, kept in-repo and
# reviewable rather than hidden in Xcode UI. See docs/testflight-lane.md.
#
# SIGNING AND UPLOAD both go through the Mac's signed-in Xcode account (Apple ID).
# `-allowProvisioningUpdates` creates/renews the Apple Distribution certificate +
# App Store provisioning profile from that account session, and `destination:
# upload` distributes through the same account. NO App Store Connect API key is used
# or needed here — deliberately: passing an API key to `-exportArchive` makes it
# perform distribution *signing*, not upload only, which would require the key to
# hold cloud-managed-distribution/provisioning access an individual or non-Admin key
# may lack. (For a fully-headless CI without an interactive account, see the
# alternative in docs/testflight-lane.md: a manually-installed distribution cert +
# profile plus an upload-only Transporter step with the API key.)
#
# Usage:
#   scripts/testflight.sh                         # archive + export a signed .ipa (no upload)
#   TESTFLIGHT_UPLOAD=1 scripts/testflight.sh     # ...and upload to TestFlight
#   PLATFORM=mac TESTFLIGHT_UPLOAD=1 scripts/testflight.sh   # the Mac build (Mac Catalyst)
#
# PLATFORM=mac archives the same scheme for Mac Catalyst and exports a .pkg. The app record
# needs its macOS platform added in App Store Connect first. Automatic signing also needs one
# Mac registered on the team to make the Mac Catalyst profile: on a team that has none, run
# once with REGISTER_DEVICE=1. That first does a signed Debug build for THIS Mac, which is what
# makes Xcode register it as a development device (an archive does not, with or without
# -allowProvisioningDeviceRegistration).
#
# Upload requires the App Store Connect app record for inc.simcast.herdrup to exist.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Herdr}"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
PLATFORM="${PLATFORM:-ios}"
case "$PLATFORM" in
  ios) DESTINATION='generic/platform=iOS'; ARCHIVE="$BUILD_DIR/Herdr.xcarchive"; EXPORT_DIR="$BUILD_DIR/export" ;;
  mac) DESTINATION='generic/platform=macOS,variant=Mac Catalyst'; ARCHIVE="$BUILD_DIR/HerdrMac.xcarchive"; EXPORT_DIR="$BUILD_DIR/export-mac" ;;
  *) echo "error: PLATFORM must be ios or mac, not '$PLATFORM'" >&2; exit 1 ;;
esac
UPLOAD="${TESTFLIGHT_UPLOAD:-0}"

# Each TestFlight build needs a unique, monotonic build number. Default to a
# second-precision timestamp; for rapid successive uploads or reproducibility pass
# a durable CI counter via BUILD_NUMBER (the caller owns uniqueness then).
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "==> xcodegen generate"
xcodegen generate
for plist in App/Info.plist HerdrWidgets/Info.plist HerdrNotificationService/Info.plist HerdrShareExtension/Info.plist; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$plist"
done

if [ "$PLATFORM" = "mac" ] && [ "${REGISTER_DEVICE:-0}" = "1" ]; then
  echo "==> register this Mac (a signed Debug build for it)"
  xcodebuild build \
    -project Herdr.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m),variant=Mac Catalyst" \
    -derivedDataPath "$BUILD_DIR/register-mac" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration
fi

echo "==> archive ($PLATFORM, $CONFIG, build $BUILD_NUMBER)"
xcodebuild archive \
  -project Herdr.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates

if [ "$UPLOAD" = "1" ]; then
  echo "==> export + upload via the signed-in Xcode account"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ci/ExportOptions-upload.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  echo "==> uploaded (build $BUILD_NUMBER). It appears in TestFlight after Apple finishes processing."
else
  echo "==> export the signed package (no upload)"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ci/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  IPA="$(find "$EXPORT_DIR" -maxdepth 1 \( -name '*.ipa' -o -name '*.pkg' \) 2>/dev/null | head -1 || true)"
  [ -n "$IPA" ] || { echo "error: no .ipa or .pkg produced in $EXPORT_DIR" >&2; exit 1; }
  echo "==> archived + exported: $IPA (build $BUILD_NUMBER)"
  echo "    Set TESTFLIGHT_UPLOAD=1 to upload. Upload needs the App Store Connect"
  echo "    app record for inc.simcast.herdrup."
fi
