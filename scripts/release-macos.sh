#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
notary_profile=${STEVE_NOTARY_PROFILE:-steve-notary}

cd "$repo_dir"

if [ -n "$(git status --porcelain)" ]; then
  echo "release requires a clean working tree" >&2
  exit 1
fi

identity=${APPLE_SIGNING_IDENTITY:-}
if [ -z "$identity" ]; then
  echo "set APPLE_SIGNING_IDENTITY to an existing Developer ID Application identity" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  echo "missing or invalid notarytool keychain profile: $notary_profile" >&2
  exit 1
fi

APPLE_SIGNING_IDENTITY="$identity" STEVE_DISTRIBUTION_BUILD=1 ./scripts/build-native.sh
app="artifacts/native/Steve.app"
archive="artifacts/Steve-macOS.zip"
if [ ! -d "$app" ]; then
  echo "native build did not produce the expected app" >&2
  exit 1
fi

# Sparkle's nested helpers require their own hardened-runtime signatures. Do
# not use --deep: Downloader.xpc has entitlements that must be preserved.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$sparkle/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle"
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/Steve"
# Hardened runtime otherwise blocks the Apple Events used by Messages sending.
# The entitlement permits the normal macOS consent flow; it does not grant it.
codesign --force --options runtime --timestamp \
  --entitlements native/Resources/Steve.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
rm -f "$archive" "$archive.sha256"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --context context:primary-signature -vv "$app"

# The notarization ticket changes the app after submission. Archive and hash
# the stapled app so the checksum describes the downloadable artifact.
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
(cd artifacts && shasum -a 256 Steve-macOS.zip > Steve-macOS.zip.sha256)

# Generate the authenticated Sparkle feed from the exact final downloadable
# archive. The private Ed25519 key remains in Keychain; only the public key and
# signed feed are committed. Publishing must upload this unchanged archive.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
feed_dir=$(mktemp -d)
trap 'rm -rf "$feed_dir"' EXIT
cp "$archive" "$feed_dir/Steve-macOS.zip"
if [ -f updates/appcast.xml ]; then cp updates/appcast.xml "$feed_dir/appcast.xml"; fi
generate_appcast=$(find native/.build/artifacts/sparkle/Sparkle/bin -maxdepth 1 -type f -name generate_appcast -perm -111 | head -n 1)
if [ -z "$generate_appcast" ]; then
  echo "Sparkle generate_appcast tool is missing" >&2
  exit 1
fi
"$generate_appcast" --download-url-prefix "https://github.com/swaymun/steve/releases/download/v$version/" \
  --link "https://github.com/swaymun/steve/releases/tag/v$version" \
  --versions "$build" --maximum-deltas 0 -o "$feed_dir/appcast.xml" "$feed_dir"
if ! grep -q "https://github.com/swaymun/steve/releases/download/v$version/Steve-macOS.zip" "$feed_dir/appcast.xml" || \
   ! grep -q 'sparkle:edSignature=' "$feed_dir/appcast.xml" || \
   ! grep -q 'sparkle-signatures:' "$feed_dir/appcast.xml"; then
  echo "generated Sparkle feed is missing its release URL or signatures" >&2
  exit 1
fi
mkdir -p updates
cp "$feed_dir/appcast.xml" updates/appcast.xml

echo "$app"
echo "$archive"
echo "$archive.sha256"
echo "updates/appcast.xml"
