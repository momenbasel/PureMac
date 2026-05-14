#!/usr/bin/env bash
#
# Local mirror of .github/workflows/release.yml. Use for emergency hotfixes
# when CI is unavailable. Requires:
#   - Developer ID Application identity in your login keychain
#   - APPLE_ID, APPLE_APP_PASSWORD env vars (or notarytool keychain profile)
#   - xcodegen + create-dmg installed (brew install xcodegen create-dmg)
#
# Usage: scripts/release-local.sh <version>
#        scripts/release-local.sh 2.2.0
#
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
TEAM_ID="H3WXHVTP97"
SIGN_ID="Developer ID Application: Moamen Basel (${TEAM_ID})"
SCHEME="PureMac"
PROJECT="PureMac.xcodeproj"
APP="build/export/PureMac.app"
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
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dvv "${APP}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${APP}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Hardened runtime missing"; exit 1; }
lipo -archs "${APP}/Contents/MacOS/PureMac"

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

echo "==> notarize app zip"
ditto -c -k --keepParent --sequesterRsrc "${APP}" build/PureMac-app.zip
xcrun notarytool submit build/PureMac-app.zip \
  --apple-id "${APPLE_ID:?set APPLE_ID env var}" \
  --password "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD env var}" \
  --team-id "${TEAM_ID}" \
  --wait --timeout 30m
xcrun stapler staple "${APP}"

echo "==> notarize dmg"
xcrun notarytool submit "${DMG}" \
  --apple-id "${APPLE_ID}" \
  --password "${APPLE_APP_PASSWORD}" \
  --team-id "${TEAM_ID}" \
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
