# USB Volume

免费的 macOS 菜单栏工具，为 USB 音箱提供音量调节、静音和提示音。音频仅在本机处理。

[下载 0.1.0](https://github.com/imboni/usb-volume/releases/download/v0.1.0/USBVolume-0.1.0-arm64.zip) · [产品网站](https://imboni.github.io/usb-volume/) · [版本发布](https://github.com/imboni/usb-volume/releases) · [反馈问题](https://github.com/imboni/usb-volume/issues)

需要 **macOS 14.2+、Apple Silicon**。面向双声道、无输入通道的 USB 输出设备，兼容性因设备而异。

## 安装

1. 解压安装包，将「USB 音量.app」移入「应用程序」。
2. 打开应用。本版尚未经过 Apple 公证；如被阻止，在「系统设置 → 隐私与安全性」中允许打开。
3. 连接音箱，退出其他音频处理软件，并按提示允许系统音频录制。

## 使用

- 点击菜单栏图标调节音量；点击扬声器静音。松开滑块播放提示音，静音或零音量时保持安静。
- 右键图标选择输出设备或打开设置。设置支持登录启动、提示音和 14 种界面语言。
- 自动记住音量与设备。系统原生音量滑块可能仍不可用，请使用应用的菜单栏滑块。
- 键盘音量键需要辅助功能权限；其他音频控制软件可能影响按键响应。

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

USB Volume is a free macOS menu bar utility for USB speaker volume, mute, and adjustment feedback. It includes optional launch at login and 14 interface languages. Requires macOS 14.2+ and Apple Silicon. Designed for stereo USB output devices without input channels; compatibility varies by device.

Move the app to Applications and grant system audio recording permission when prompted. The app is locally signed and not notarized by Apple. Media keys require Accessibility permission and may be affected by other audio-control apps.

Audio stays in memory and is never saved or uploaded. The microphone is not used. **Pause playback before quitting or pausing control: the speaker returns to its original volume.**
