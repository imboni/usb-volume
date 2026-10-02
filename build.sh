#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_root="${1:-build}"
mkdir -p "$build_root/USB 音量.app/Contents/MacOS" "$build_root/USB 音量.app/Contents/Resources"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  -c Sources/VolumeDSP.c -o "$build_root/VolumeDSP.o"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.2 \
  Sources/main.m Sources/AudioController.m Sources/MediaKeys.m Sources/SettingsController.m Sources/StatusServer.m Sources/Localization.m "$build_root/VolumeDSP.o" \
  -framework AppKit -framework CoreAudio -framework Foundation -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement \
  -o "$build_root/USB 音量.app/Contents/MacOS/USBVolume"
cp Info.plist "$build_root/USB 音量.app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$build_root/USB 音量.app/Contents/Resources/AppIcon.icns"
fi
bash localize-resources.sh "$build_root/USB 音量.app/Contents/Resources"
codesign --force --sign - --identifier local.lee.USBVolume "$build_root/USB 音量.app"
codesign --verify --strict "$build_root/USB 音量.app"
printf 'Built: %s/USB 音量.app\n' "$build_root"
