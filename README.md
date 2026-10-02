# USB Volume

免费的 macOS 菜单栏工具，为 USB 音箱提供软件音量、静音和调节提示音。音频仅在本机处理。

[产品网站](https://imboni.github.io/usb-volume/) · [反馈问题](https://github.com/imboni/usb-volume/issues)

**0.1.0 正在验收。** 实体音量键验证完成后开放下载。

需要 **macOS 14.2+、Apple Silicon**。适用于双声道、无输入通道的 USB 输出设备；已在 MOONDROP MM3A 的 48 kHz 通路验证，其他设备的兼容性可能不同。

## 发布后安装

1. 下载并解压 ZIP，将「USB 音量.app」移入「应用程序」。
2. 打开应用。本版使用本机签名，尚未经过 Apple 公证；如被阻止，在「系统设置 → 隐私与安全性」中允许打开。
3. 退出 eqMac 等音频处理软件，连接音箱，并按提示允许系统音频录制。

## 使用

- 点击菜单栏图标调节音量；点击扬声器静音。松开滑块播放一次提示音，静音或零音量时不播放。
- 右键图标选择输出设备或打开设置。设置支持登录启动、提示音和 14 种界面语言。
- 音量与设备会被记住。系统原生音量滑块可能仍不可用，请使用应用的菜单栏滑块。
- 键盘音量键支持正在完善，需要辅助功能权限，授权后的实际兼容性仍需验证。

**退出或暂停控制前，请先暂停播放：音箱会恢复原始音量，声音可能变大。**

## 权限与隐私

系统音频录制权限用于读取正在播放的声音、调整音量并输出。音频只在内存中处理，不保存、不上传，不读取麦克风。键盘控制需另行授权；更新本机签名的应用后，macOS 可能要求重新授权。

## 本地构建

需要 macOS 和 Apple Command Line Tools，无第三方运行依赖。

```sh
bash build.sh
bash test.sh
```

应用位于 `build/USB 音量.app`。`--status` 可只读查询已运行实例；`--list-devices` 列出音频设备。网站为 `docs/` 下的静态文件。

## English

**Version 0.1.0 is in validation.** Downloads will open after physical media-key testing.

USB Volume is a free, local menu bar volume control for USB speakers on Apple Silicon Macs running macOS 14.2 or later. It includes mute, adjustment feedback, optional launch at login, and 14 interface languages. Tested with MOONDROP MM3A; other stereo USB output devices without input channels may vary. Keyboard media-key support is still being validated. The app is locally signed and not notarized by Apple.

Once released, download the ZIP, move the app to Applications, and grant system audio recording permission when prompted. Quit other audio-processing apps first. Audio stays in memory and is never saved or uploaded. **Pause playback before quitting: the speaker returns to its original volume.**
