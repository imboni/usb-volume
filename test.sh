#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_root="${1:-build}"
mkdir -p "$test_root"
xcrun clang -std=c11 -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I Sources \
  Sources/VolumeDSP.c Tests/VolumeDSPTests.c -o "$test_root"/VolumeDSPTests
"$test_root"/VolumeDSPTests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Sources/MediaKeys.m Sources/Localization.m Tests/MediaKeyParsing.m \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -o "$test_root"/MediaKeyParsing
"$test_root"/MediaKeyParsing
xcrun clang -std=c11 -O1 -c Sources/VolumeDSP.c -o "$test_root"/MediaStateDSP.o
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Tests/MediaKeyState.m Sources/AudioController.m Sources/MediaKeys.m Sources/SettingsController.m Sources/StatusServer.m Sources/Localization.m "$test_root"/MediaStateDSP.o \
  -framework AppKit -framework QuartzCore -framework CoreAudio -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement -o "$test_root"/MediaKeyState
"$test_root"/MediaKeyState
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Tests/DeviceDetectionState.m Sources/AudioController.m Sources/MediaKeys.m Sources/SettingsController.m Sources/StatusServer.m Sources/Localization.m "$test_root"/MediaStateDSP.o \
  -framework AppKit -framework QuartzCore -framework CoreAudio -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement -o "$test_root"/DeviceDetectionState
"$test_root"/DeviceDetectionState
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Tests/ApplicationAudioState.m Sources/Localization.m "$test_root"/MediaStateDSP.o \
  -framework AppKit -framework QuartzCore -framework CoreAudio -o "$test_root"/ApplicationAudioState
"$test_root"/ApplicationAudioState
python3 Tests/LocalizationResources.py
test_bundle="$test_root/LocalizationTests.app"
trap 'rm -rf "$test_bundle"' EXIT
mkdir -p "$test_bundle/Contents/MacOS"
cp Tests/LocalizationTests-Info.plist "$test_bundle/Contents/Info.plist"
bash localize-resources.sh "$test_bundle/Contents/Resources"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g \
  Sources/Localization.m Tests/LocalizationTests.m -framework Foundation \
  -o "$test_bundle/Contents/MacOS/LocalizationTests"
"$test_bundle/Contents/MacOS/LocalizationTests"
