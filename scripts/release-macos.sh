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

APPLE_SIGNING_IDENTITY="$identity" ./scripts/build-native.sh
app="artifacts/native/Steve.app"
archive="artifacts/Steve-macOS.zip"
if [ ! -d "$app" ]; then
  echo "native build did not produce the expected app" >&2
  exit 1
fi

# Hardened runtime otherwise blocks the Apple Events used by Messages sending.
# The entitlement permits the normal macOS consent flow; it does not grant it.
codesign --force --deep --options runtime --timestamp \
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
shasum -a 256 "$archive" > "$archive.sha256"

echo "$app"
echo "$archive"
echo "$archive.sha256"
