#!/bin/bash
# Reproducible release layout; run on an Apple Silicon Mac.
set -euo pipefail
cd "$(dirname "$0")"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
release_root="build/release-$version"
if [[ "$(uname -m)" != arm64 ]]; then
  printf 'Release archives require an Apple Silicon build host.\n' >&2
  exit 1
fi
python3 Tests/ReleaseResources.py
bash build.sh "$release_root"
app="$release_root/USB 音量.app"
test "$(lipo -archs "$app/Contents/MacOS/USBVolume")" = arm64
codesign --verify --strict "$app"
mkdir -p "$release_root/artifacts"
app_zip="USBVolume-$version-arm64.zip"
extension_zip="USBVolume-BrowserExtension-$version.zip"
rm -f "$release_root/artifacts/$app_zip" "$release_root/artifacts/$extension_zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$release_root/artifacts/$app_zip"
ditto --norsrc -c -k --keepParent "$app/Contents/Resources/BrowserExtension" "$release_root/artifacts/$extension_zip"
(
  cd "$release_root/artifacts"
  shasum -a 256 "$app_zip" "$extension_zip" > SHA256SUMS.txt
)
printf 'Release assets: %s/artifacts\n' "$release_root"
