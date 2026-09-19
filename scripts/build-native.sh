#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$repo_dir/artifacts/native"
app="$output_dir/Steve.app"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cd "$repo_dir"
swift build --package-path native --configuration release
bin_dir=$(swift build --package-path native --configuration release --show-bin-path)
scratch_dir=$bin_dir
while [ "$scratch_dir" != / ] && [ ! -d "$scratch_dir/checkouts" ]; do
  scratch_dir=$(dirname "$scratch_dir")
done
if [ ! -d "$scratch_dir/checkouts" ]; then
  echo "Could not locate SwiftPM dependency checkouts from $bin_dir" >&2
  exit 1
fi
swift_binary="$bin_dir/SteveNative"
resource_bundle="$bin_dir/SteveNative_SteveNative.bundle"

if [ ! -x "$swift_binary" ] || [ ! -d "$resource_bundle" ]; then
  echo "Swift build did not produce the expected executable and resources" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$swift_binary" "$app/Contents/MacOS/Steve"
cp -R "$resource_bundle" "$app/Contents/Resources/"
cp "$repo_dir/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$app/Contents/Resources/ThirdPartyLicenses"
cp "$scratch_dir/checkouts/SQLite.swift/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/SQLite.swift-LICENSE.txt"
cp "$scratch_dir/checkouts/PhoneNumberKit/LICENSE" "$app/Contents/Resources/ThirdPartyLicenses/PhoneNumberKit-LICENSE.txt"
cp "$scratch_dir/checkouts/swift-nio/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/swift-nio-LICENSE.txt"
cp "$scratch_dir/checkouts/swift-nio/NOTICE.txt" "$app/Contents/Resources/ThirdPartyLicenses/swift-nio-NOTICE.txt"
cp "$scratch_dir/checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE" "$app/Contents/Resources/ThirdPartyLicenses/swift-nio-CNIOLLHTTP-LICENSE.txt"
cp "$scratch_dir/checkouts/swift-atomics/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/swift-atomics-LICENSE.txt"
cp "$scratch_dir/checkouts/swift-collections/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/swift-collections-LICENSE.txt"
cp "$scratch_dir/checkouts/swift-system/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/swift-system-LICENSE.txt"

# SwiftPM places SQLite.swift and PhoneNumberKit resources beside the binary.
# They are data bundles only; Steve has no helper executable or bundled imsg.
find "$bin_dir" -maxdepth 1 -type d -name '*.bundle' ! -name 'SteveNative_SteveNative.bundle' -exec cp -R {} "$app/Contents/Resources/" \;
cp "$repo_dir/native/Resources/Info.plist" "$app/Contents/Info.plist"

# Build the app icon from the canonical PNG. No vector redraw or alternate
# logo is introduced, so the transparent blue-violet artwork stays identical.
cp "$repo_dir/native/Sources/SteveNative/Resources/SteveLogo.png" "$tmp_dir/SteveLogo.png"
mkdir -p "$tmp_dir/Steve.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$tmp_dir/SteveLogo.png" --out "$tmp_dir/Steve.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$tmp_dir/SteveLogo.png" --out "$tmp_dir/Steve.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$app/Contents/Resources/icon.icns" "$tmp_dir/Steve.iconset"

# Source builds are ad hoc signed unless the caller explicitly selects an
# existing identity. This avoids silently binding an install to an account.
signing_identity=${APPLE_SIGNING_IDENTITY:-${STEVE_CODESIGN_IDENTITY:--}}

chmod 755 "$app/Contents/MacOS/Steve"
# Remove local build paths and debug symbols before the distributable bundle is
# signed. Swift release binaries otherwise retain checkout-specific paths.
/usr/bin/strip -S "$app/Contents/MacOS/Steve"
codesign --force --sign "$signing_identity" "$app/Contents/MacOS/Steve" >/dev/null
codesign --force --sign "$signing_identity" "$app" >/dev/null
echo "$app"
