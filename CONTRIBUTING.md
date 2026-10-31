# Contributing to USB Volume

Small, focused improvements are welcome. For a larger change, open an issue describing the user-facing problem first.

## Source map

| Path | Purpose |
| --- | --- |
| `Sources/main.m`, `SettingsController.m` | Native menu bar mixer and settings |
| `Sources/AudioController.m` | CoreAudio discovery, process taps, output routing |
| `Sources/VolumeDSP.c` | Allocation-free gain, mute, ramping, and feedback |
| `Resources/Localization/` | Native UI translations |
| `BrowserExtension/` | Chrome / Edge companion, without runtime dependencies |
| `docs/` | Static GitHub Pages website and translations |
| `Tests/` | Native state, DSP, UI, localization, and release checks |

## Local checks

Use macOS 14.2+, Apple Command Line Tools, and Node.js 18+.

```sh
bash test.sh
bash test-ui.sh --all-locales
node --test BrowserExtension/tests/*.test.js
python3 Tests/ReleaseResources.py
bash build.sh
```

The native UI suite requires an active graphical session. It uses simulated audio and does not modify audio-device routing or app preferences. To inspect or export the actual views:

```sh
bash test-ui.sh --show --language ar --appearance dark
bash test-ui.sh --language en --appearance light --skip-motion --screenshot /tmp/usb-volume.png
```

For website and extension browser tests, install Python Playwright (`python3 -m pip install playwright`) and Google Chrome. In one terminal, serve the repository:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

In another terminal:

```sh
python3 Tests/WebsiteUI.py --base http://127.0.0.1:8765/docs
python3 BrowserExtension/tests/popup_ui.py --base http://127.0.0.1:8765
```

Browser tests use deterministic tab fixtures; they do not exercise real browser audio capture. Verify audio changes with a real USB speaker, several simultaneous sources, mute, reconnect, and device changes. Start quietly and pause playback before stopping control. Do not record or upload private playback for a bug report.

## Translations

The native app, extension, and website support the same 14 languages. Keep keys and format placeholders consistent with English:

- Native: `Resources/Localization/<language>.json`
- Extension: `BrowserExtension/_locales/<Chrome locale>/messages.json`
- Website: `docs/locales/<language>.json`

Use natural, concise labels. Verify long strings and Arabic RTL layouts in both appearances. App names and numeric sliders keep their appropriate direction. Translated UI should remain usable when an application name is long or an error wraps to several lines.

## Releases

Update `Info.plist`, the extension manifest, download URLs, changelog, and release notes together. Run the checks above, then `bash package-release.sh` on Apple Silicon. It builds the signed app and produces two ZIP archives plus `SHA256SUMS.txt` under `build/release-<version>/artifacts/`.

Inspect the archives before tagging and uploading them to GitHub Releases. Local signing is not Apple notarization; keep that distinction in download instructions. Website screenshots are rendered from the production views with explicitly labelled sample sources, not fabricated mockups.

Contributions are distributed under the project's [MIT license](LICENSE).
