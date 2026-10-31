#!/bin/bash
# Requires a logged-in macOS graphical session. Kept separate from headless CI.
# --build-only compiles without connecting to WindowServer.
# --show leaves an interactive fake mixer visible after assertions pass.
# --all-locales runs all 14 languages in both light and dark appearances.
set -euo pipefail
cd "$(dirname "$0")"
test_root="${USB_VOLUME_UI_TEST_ROOT:-build/mixer-ui}"
test_bundle="$test_root/USB Volume UI Test.app"
mkdir -p "$test_bundle/Contents/MacOS" "$test_bundle/Contents/Resources"
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  -c Sources/VolumeDSP.c -o "$test_root/MixerUIDSP.o"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g -mmacosx-version-min=14.2 \
  Tests/MixerUIState.m Sources/AudioController.m Sources/MediaKeys.m Sources/SettingsController.m Sources/StatusServer.m Sources/Localization.m "$test_root/MixerUIDSP.o" \
  -framework AppKit -framework CoreAudio -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement -framework QuartzCore \
  -o "$test_bundle/Contents/MacOS/MixerUIState"
cp Tests/MixerUIState-Info.plist "$test_bundle/Contents/Info.plist"
bash localize-resources.sh "$test_bundle/Contents/Resources"
# Keep test-app names distinct in every language; only UI strings match production.
for localized_info in "$test_bundle"/Contents/Resources/*.lproj/InfoPlist.strings; do
  plutil -replace CFBundleName -string 'USB Volume UI Test' "$localized_info"
  plutil -replace CFBundleDisplayName -string 'USB Volume UI Test' "$localized_info"
done
if [[ "${1:-}" == --build-only ]]; then
  printf 'Built UI fixture: %s\n' "$test_bundle"
  exit 0
fi
if [[ "${1:-}" == --all-locales ]]; then
  for language in en zh-Hans zh-Hant ja ko fr de es it pt-BR ru ar hi id; do
    for appearance in light dark; do
      if [[ "$language" == en && "$appearance" == light ]]; then
        "$test_bundle/Contents/MacOS/MixerUIState" --language "$language" --appearance "$appearance"
      else
        # Native visibility/cancellation races are appearance-independent; check
        # them once, while checking layout, states and motion policy in every case.
        "$test_bundle/Contents/MacOS/MixerUIState" --language "$language" --appearance "$appearance" --skip-motion
      fi
    done
  done
  printf 'Mixer UI matrix: all 28 language/appearance combinations passed.\n'
  exit 0
fi
exec "$test_bundle/Contents/MacOS/MixerUIState" "$@"
