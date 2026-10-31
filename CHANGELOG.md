# Changelog

## 0.3.0 — 2026-10-31

This release brings the previously local-only mixer and browser companion to the public release channel.

- Independent app volume and mute alongside the master control, with remembered settings and automatic process discovery.
- A bundled Chrome / Edge 116+ extension for individual tab volume, also available as a separate download.
- Compact 300 px native panel, refined hover/press states, and interruptible open/close motion. Keyboard actions and Reduce Motion remain immediate.
- 14 languages across the app, extension, and website; Arabic RTL layouts, locale-aware percentages, and settings that fit longer translations.
- Preserve muted routes when CoreAudio temporarily cannot read the process list; fail closed if an existing muted route becomes unhealthy.
- Rebuilt product website, illustrated English/Chinese README, contribution guide, and reproducible release archives with SHA-256 checksums.
- Expanded native UI, browser, localization, audio-routing, and release-resource tests.

发布包面向 macOS 14.2+ / Apple Silicon，采用本机签名，未经过 Apple 公证。网页控制位于浏览器扩展，尚未集成到原生面板；真实硬件与受保护媒体的兼容性仍因设备和网页而异。

## 0.2.1

Local build; not published as a GitHub release.

- 主面板收紧至 300px 宽，应用行缩至 48px，移除常驻说明与重复状态文字。
- 网页扩展同步精简，恢复、停止与帮助改为图标操作。
- 增加 120ms 打开／90ms 关闭动效与按钮悬停反馈；键盘操作及减少动态效果模式即时响应。
- 覆盖快速开关、动画中断、多语言紧凑布局与核心操作回归。

## 0.2.0

Local build; not published as a GitHub release.

- 重做原生混音器与网页扩展界面：清楚的音量层级、醒目百分比、明暗主题、精简说明和无障碍控件。
- 列表滚动不再误调音量；独立静音通道异常时立即静音总输出，避免意外出声。
- 菜单栏增加应用混音器：独立音量、静音、百分比、音频活动状态及恢复默认。
- 总音量与应用音量叠加，按应用保存设置并自动跟踪音频进程；浏览器辅助进程合并到所属应用。
- 新增 Chrome / Edge 网页音量扩展，分别调节标签页；从应用中查看安装说明和打开扩展文件夹。
- 增加应用路由事务、偏好恢复和浏览器音频生命周期回归测试。

## 0.1.1

- 自动检测 USB 音箱，断开后停止控制并在后台待机。
- 连接后询问是否启用音量控制。
- 选择「暂不」后，同次连接不再重复提示。
- 设置中可开启或关闭自动检测。

## 0.1.0

- 菜单栏音量控制、静音和调节提示音。
- 键盘音量加减与静音，需辅助功能权限。
- 登录时启动与 14 种界面语言。
- 紧凑的原生设置窗口。

支持 macOS 14.2+、Apple Silicon。
