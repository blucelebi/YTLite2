#!/bin/bash
# make_ipa.sh — builds a distributable IPA for jailbroken devices (AppSync + Filza)
# Usage: ./make_ipa.sh
# Output: YTLite_<version>.ipa in the project root
#
# Env overrides (all optional; used by .github/workflows/build-release.yml):
#   IPA_VERSION            version for the filename + CFBundleShortVersionString
#                          (default: MARKETING_VERSION from build settings)
#   BUILD_NUMBER           sets CFBundleVersion when provided
#   UPDATE_SOURCE=0        skip patching source/apps.json (CI patches it only
#                          after the release is published, so the URL is live)
#   XCODEBUILD_EXTRA_ARGS  extra xcodebuild args, e.g. CODE_SIGNING_ALLOWED=NO

set -e

APP_NAME="YTLite"
PROJECT="YTLite.xcodeproj"
SCHEME="YTVLite"
RELEASE_BUNDLE_ID="com.verback.YTLite"
SOURCE_JSON="source/apps.json"
BUILD_LOG=$(mktemp)

echo "▶ Building Release for device..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration Release \
  -destination "generic/platform=iOS" \
  ${XCODEBUILD_EXTRA_ARGS:-} \
  build \
  > "$BUILD_LOG" 2>&1 || true
grep -E "error:|warning:" "$BUILD_LOG" | tail -5 || true
if ! grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  echo "❌ Build failed — full log: $BUILD_LOG"
  tail -30 "$BUILD_LOG"
  exit 1
fi
rm -f "$BUILD_LOG"

BUILD_SETTINGS=$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration Release \
  -showBuildSettings 2>/dev/null)

BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep "^ *BUILT_PRODUCTS_DIR" | head -1 | awk -F' = ' '{print $2}')
VERSION="${IPA_VERSION:-$(echo "$BUILD_SETTINGS" | grep "^ *MARKETING_VERSION" | head -1 | awk -F' = ' '{print $2}')}"
OUTPUT="${APP_NAME}_${VERSION}.ipa"

APP_PATH="$BUILD_DIR/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "❌ Build failed or app not found at: $APP_PATH"
  exit 1
fi

echo "▶ Replacing bundle ID for release: $RELEASE_BUNDLE_ID"
plutil -replace CFBundleIdentifier -string "$RELEASE_BUNDLE_ID" "$APP_PATH/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Info.plist"
if [ -n "${BUILD_NUMBER:-}" ]; then
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_PATH/Info.plist"
fi

# When the build runs unsigned (CI: CODE_SIGNING_ALLOWED=NO), Xcode embeds the
# toolchain's Swift back-deploy dylibs verbatim, keeping their huge bitcode
# segment; a signed build strips it. No-op when already stripped.
echo "▶ Stripping bitcode from embedded Swift libraries..."
for dylib in "$APP_PATH/Frameworks/"*.dylib; do
  [ -e "$dylib" ] || continue
  xcrun bitcode_strip -r "$dylib" -o "$dylib"
done

# Sign with a FIXED application-identifier: keychain items on jailbroken
# installs are keyed to it, so it must never change between releases (changing
# it logs every AppSync user out once). It is an arbitrary string for ad-hoc
# signing — no Apple registration involved — and is intentionally independent
# of the dev bundle id in Local.xcconfig. Normalized from the accidental
# "WD55N799QB.…YTLite.test" of 1.4.0/1.4.1 to the main team; frozen since.
echo "▶ Replacing dev cert with ad-hoc signature..."
ENTITLEMENTS=$(mktemp).plist
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>4RAT6786W6.com.verback.YTLite</string>
	<key>com.apple.developer.team-identifier</key>
	<string>4RAT6786W6</string>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
codesign -f -s - --deep --entitlements "$ENTITLEMENTS" "$APP_PATH" 2>/dev/null \
  && echo "  codesign: ok" \
  || echo "  codesign: skipped (app will still install via AppSync)"
rm -f "$ENTITLEMENTS"

echo "▶ Packaging IPA..."
TMP=$(mktemp -d)
mkdir "$TMP/Payload"
cp -r "$APP_PATH" "$TMP/Payload/"
(cd "$TMP" && zip -qr "$OLDPWD/$OUTPUT" Payload)
rm -rf "$TMP"

IPA_SIZE=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT" 2>/dev/null)
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPO_URL="https://github.com/verback2308/YTLite"
DOWNLOAD_URL="$REPO_URL/releases/download/${VERSION}/${OUTPUT}"

if [ "${UPDATE_SOURCE:-1}" = "1" ]; then
  echo "▶ Updating source: $SOURCE_JSON"
  python3 scripts/update_source.py \
    --version "$VERSION" \
    --download-url "$DOWNLOAD_URL" \
    --size "$IPA_SIZE" \
    --date "$DATE" \
    --file "$SOURCE_JSON"
fi

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo "✅ $OUTPUT ($SIZE) — ready to share"
echo "   Install: copy to device, open in Filza, tap Install"
