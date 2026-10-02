#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
resource_root="$1"
privacy_key='USB 音量需要读取系统播放的声音，在本机调节音量后发送给 USB 音箱。不会录制、保存或上传音频。'
for catalog in Resources/Localization/*.json; do
  language="$(basename "$catalog" .json)"
  directory="$resource_root/$language.lproj"
  mkdir -p "$directory"
  plutil -convert binary1 -o "$directory/Localizable.strings" "$catalog"
  localized_name="$(plutil -extract 'USB 音量' raw -o - "$catalog")"
  privacy_message="$(plutil -extract "$privacy_key" raw -o - "$catalog")"
  about_message="$(plutil -extract '本机音频控制' raw -o - "$catalog")"
  info="$directory/InfoPlist.strings"
  plutil -create xml1 "$info"
  plutil -insert CFBundleName -string "$localized_name" "$info"
  plutil -insert CFBundleDisplayName -string "$localized_name" "$info"
  plutil -insert NSAudioCaptureUsageDescription -string "$privacy_message" "$info"
  plutil -insert NSHumanReadableCopyright -string "$localized_name · $about_message" "$info"
  plutil -convert binary1 "$info"
done
