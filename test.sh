#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -std=c11 -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I Sources \
  Sources/VolumeDSP.c Tests/VolumeDSPTests.c -o build/VolumeDSPTests
./build/VolumeDSPTests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Sources/MediaKeys.m Sources/Localization.m Tests/MediaKeyParsing.m \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -o build/MediaKeyParsing
./build/MediaKeyParsing
xcrun clang -std=c11 -O1 -c Sources/VolumeDSP.c -o build/MediaStateDSP.o
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
  Tests/MediaKeyState.m Sources/AudioController.m Sources/MediaKeys.m Sources/SettingsController.m Sources/StatusServer.m Sources/Localization.m build/MediaStateDSP.o \
  -framework AppKit -framework CoreAudio -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement -o build/MediaKeyState
./build/MediaKeyState
python3 Tests/LocalizationResources.py
test_bundle="$PWD/build/LocalizationTests.app"
mkdir -p "$test_bundle/Contents/MacOS"
cp Tests/LocalizationTests-Info.plist "$test_bundle/Contents/Info.plist"
bash localize-resources.sh "$test_bundle/Contents/Resources"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g \
  Sources/Localization.m Tests/LocalizationTests.m -framework Foundation \
  -o "$test_bundle/Contents/MacOS/LocalizationTests"
"$test_bundle/Contents/MacOS/LocalizationTests"
