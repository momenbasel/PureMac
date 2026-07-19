#!/usr/bin/env bash
#
# Local mirror of .github/workflows/release.yml. Use for emergency hotfixes
# when CI is unavailable. Requires:
#   - Developer ID Application identity in your login keychain
#   - notarytool keychain profile already stored, e.g.:
#       xcrun notarytool store-credentials AC_NOTARY \
#         --key ~/.appstoreconnect/private_keys/AuthKey_5G7R52L8RK.p8 \
#         --key-id 5G7R52L8RK --issuer 5de3898a-cd31-4061-850f-ae17b389e46a
#   - xcodegen + create-dmg installed (brew install xcodegen create-dmg)
#
# Usage: scripts/release-local.sh <version> [notary_profile]
#        scripts/release-local.sh 2.2.0
#        scripts/release-local.sh 2.2.0 AC_NOTARY
#
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary_profile]}"
NOTARY_PROFILE="${2:-AC_NOTARY}"
TEAM_ID="H3WXHVTP97"
SIGN_ID="Developer ID Application: Moamen Basel (${TEAM_ID})"
SCHEME="PureMac"
PROJECT="PureMac.xcodeproj"
APP="build/export/PureMac.app"
HELPER="${APP}/Contents/Library/LaunchServices/com.puremac.privileged-helper"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/com.puremac.privileged-cleaning.plist"
DMG="build/PureMac-${VERSION}.dmg"
ZIP="build/PureMac-${VERSION}.zip"

cd "$(dirname "$0")/.."

PROJ_VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "${PROJ_VERSION}" != "${VERSION}" ]]; then
  echo "ERROR: project.yml MARKETING_VERSION (${PROJ_VERSION}) != ${VERSION}" >&2
  exit 1
fi

rm -rf build
mkdir -p build

echo "==> xcodegen"
xcodegen generate

echo "==> archive"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/PureMac.xcarchive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_ID}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  archive

echo "==> export"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/PureMac.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

echo "==> verify codesign"
APP_REQUIREMENT='anchor apple generic and identifier "com.puremac.app" and certificate leaf[subject.OU] = "H3WXHVTP97"'
HELPER_REQUIREMENT='anchor apple generic and identifier "com.puremac.privileged-helper" and certificate leaf[subject.OU] = "H3WXHVTP97"'
test -x "${HELPER}"
test -f "${DAEMON_PLIST}"
plutil -lint "${DAEMON_PLIST}"
test "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${DAEMON_PLIST}")" = "com.puremac.privileged-cleaning"
test "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}")" = "Contents/Library/LaunchServices/com.puremac.privileged-helper"
test "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "${DAEMON_PLIST}")" = "com.puremac.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.puremac.privileged-cleaning' "${DAEMON_PLIST}")" = "true"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --verify --strict --verbose=2 "${HELPER}"
codesign --verify --strict --verbose=2 -R="${APP_REQUIREMENT}" "${APP}"
codesign --verify --strict --verbose=2 -R="${HELPER_REQUIREMENT}" "${HELPER}"
codesign -d --entitlements :- "${APP}" > /tmp/puremac-app-entitlements.plist
codesign -d --entitlements :- "${HELPER}" > /tmp/puremac-helper-entitlements.plist
! plutil -p /tmp/puremac-app-entitlements.plist | grep -E 'get-task-allow|disable-library-validation|allow-dyld-environment-variables'
! plutil -p /tmp/puremac-helper-entitlements.plist | grep -E 'get-task-allow|disable-library-validation|allow-dyld-environment-variables'
codesign -dvv "${APP}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${APP}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Hardened runtime missing"; exit 1; }
codesign -dvv "${HELPER}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${HELPER}" 2>&1 | grep -q "Identifier=com.puremac.privileged-helper" || { echo "Unexpected privileged helper identifier"; exit 1; }
codesign -dvv "${HELPER}" 2>&1 | grep -q "TeamIdentifier=${TEAM_ID}" || { echo "Unexpected privileged helper team"; exit 1; }
codesign -dvv "${HELPER}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Privileged helper hardened runtime missing"; exit 1; }
lipo -archs "${APP}/Contents/MacOS/PureMac"
lipo -archs "${HELPER}" | grep -q "x86_64"
lipo -archs "${HELPER}" | grep -q "arm64"

echo "==> dmg"
create-dmg \
  --volname "PureMac ${VERSION}" \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "PureMac.app" 140 180 \
  --hide-extension "PureMac.app" \
  --app-drop-link 400 180 \
  --no-internet-enable \
  "${DMG}" \
  build/export/PureMac.app
codesign --sign "${SIGN_ID}" --timestamp "${DMG}"

echo "==> notarize app zip (profile: ${NOTARY_PROFILE})"
ditto -c -k --keepParent --sequesterRsrc "${APP}" build/PureMac-app.zip
xcrun notarytool submit build/PureMac-app.zip \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${APP}"

echo "==> notarize dmg"
xcrun notarytool submit "${DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type install --verbose=4 "${DMG}"

echo "==> final zip with stapled app"
ditto -c -k --keepParent --sequesterRsrc "${APP}" "${ZIP}"

DMG_SHA=$(shasum -a 256 "${DMG}" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "${ZIP}" | awk '{print $1}')

echo ""
echo "===================="
echo "PureMac ${VERSION} signed + notarized"
echo "===================="
echo "DMG: ${DMG}"
echo "  sha256: ${DMG_SHA}"
echo "ZIP: ${ZIP}"
echo "  sha256: ${ZIP_SHA}"
echo ""
echo "Next: gh release create v${VERSION} ${DMG} ${ZIP} --title \"PureMac v${VERSION}\""
echo "Then: bump homebrew/puremac.rb sha256 to ${ZIP_SHA}"
