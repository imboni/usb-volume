# USB Volume 网页音量扩展

Chrome / Edge 116+ 的配套扩展，按**标签页**分别调节音量、静音。网页可独立工作；安装 macOS USB Volume 后，网页音量会与应用的总音量、浏览器音量叠加。网页控制面板位于浏览器扩展弹窗，目前不与 macOS 菜单栏同步。

## 安装与使用

1. 将整个 `BrowserExtension` 文件夹放到固定位置；不要只复制 `manifest.json`。
2. 在 Chrome 打开 `chrome://extensions`（Edge 为 `edge://extensions`），打开「开发者模式」，选择「加载已解压的扩展程序」，选择此文件夹。
3. 固定工具栏上的 USB Volume 扩展。打开一个播放声音的 HTTP/HTTPS 网页，点击扩展，再点「控制此页」。浏览器会显示标签页音频被捕获的指示，这是本机音量处理所需。
4. 为其他网页重复启用。弹窗中的各行可分别调节 0–100%、静音和恢复 100%。可使用方向键调整滑块；拖动或按键调整音量会自动取消该网页的静音。
5. 关闭弹窗后继续生效。刷新、标签页内跳转通常保留控制；关闭标签页、浏览器停止共享音频、重载扩展或退出浏览器会结束控制。浏览器重启后需要重新启用，不会自动捕获网页。

**停止控制、重载或卸载扩展会恢复网页原来的音量，建议先暂停播放。** 100% 表示不再额外衰减，不会放大网页原声音。网页自身播放器、浏览器静音、USB Volume 的应用音量与总音量仍然影响最终声音。

## 支持范围

- 支持 Chrome / Edge 的普通 HTTP/HTTPS 标签页，包括使用 Web Audio 的网页。每个标签页需手动启用一次；同一网站的两个标签页也能分别设置。
- 不支持 Safari / Firefox、浏览器内部页面、扩展商店等禁止捕获的页面、无痕窗口；受保护媒体可能限制捕获。失败时会显示错误并清理音频捕获。
- 浏览器音频被重新输出到其默认输出设备。若网页自行选择了其他音频输出设备，启用后可能改变输出路由。
- 不需要麦克风、摄像头、站点内容脚本或服务器。扩展仅在内存处理音频，不录音、不保存音频、不上传。`tabs` 权限用于显示已控制标签页标题，`storage.session` 只保存本次浏览器会话的控制状态；不会记录历史浏览数据。
- 使用浏览器标签页音频捕获和隐藏音频页面，服务工作线程暂停后音量控制仍保持。标签页音量设置与浏览器生命周期一致，不跨重启保存。

## 界面语言

与原生应用对齐，支持 14 种语言：英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、意大利语、巴西葡萄牙语、俄语、阿拉伯语、印地语和印度尼西亚语。扩展跟随浏览器界面语言，不修改原生应用的语言设置。

中文按脚本和地区区分简繁体；葡萄牙语地区变体使用巴西葡萄牙语。未支持的语言和缺失翻译回退到英语。百分比使用本地数字与格式；阿拉伯语界面镜像排列，网页标题独立处理文字方向。音量滑块始终保持左减右增，键盘操作一致。

翻译位于 `_locales/*/messages.json`，覆盖弹窗、无障碍标签、错误提示及扩展名称/说明。打包时必须保留整个 `_locales` 目录，不能只复制根目录文件。[Chrome 国际化文档](https://developer.chrome.com/docs/extensions/reference/api/i18n)

## 开发验证

无 npm 依赖，使用 Node.js 18+：

```sh
node --test BrowserExtension/tests/*.test.js
```

自动测试覆盖独立增益/静音、重复启用、捕获超时及延迟返回清理、播放失败清理、标签页关闭、工作线程重启恢复、消息来源限制、快速键盘操作的过期回执、通知队列无循环、标签页消失清理及 14 语资源完整性、语言回退、百分比和错误提示。浏览器实际捕获仍需手动验证：两页同时播放，交替调整/静音，关弹窗、刷新网页、停止工作线程、关闭标签页，再确认其余音源保持正常。

实现依据：[Chrome tabCapture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture)、[后台标签页音频处理示例](https://developer.chrome.com/docs/extensions/how-to/web-platform/screen-capture)、[offscreen 生命周期](https://developer.chrome.com/docs/extensions/reference/api/offscreen)。

## 界面回归与预览

界面夹具直接载入真实 `popup.html/css/js`，用确定性的本机浏览器 API 替身提供网页数据；不安装扩展、不申请权限、不捕获音频。需从项目根目录启动静态服务器：

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

打开 `http://127.0.0.1:8765/BrowserExtension/tests/preview.html`。参数 `scenario` 支持 `multiple`、`empty`、`error`、`restricted`、`disconnected`、`many`、`long`；`lang` 支持全部 14 种语言及地区变体，例如 `zh-Hans`、`zh-TW`、`en-US`、`ar`。`error` 场景点击主按钮显示可恢复错误；深浅色跟随系统。

安装 Python Playwright 并已有 Google Chrome 时，可在另一个终端执行：

```sh
python3 BrowserExtension/tests/popup_ui.py --base http://127.0.0.1:8765
```

测试在隔离的无头 Chrome 中运行，不访问现有浏览器用户资料。覆盖网页间独立操作、快速方向键、鼠标拖动、Home/End、静音与恢复、启用中及失败状态、焦点恢复、长标题、多网页滚动、全部 14 语、RTL、浅深主题、文字对比度，以及三网页的紧凑高度。动效仅使用 130–140ms 的透明度与变换；键盘操作和减少动态效果模式禁用动效。截图保存在 `build/browser-ui/`。这些测试验证界面和命令行为，不能替代真实浏览器标签页音频播放验证。

官网截图可用以下命令重建：

```sh
python3 BrowserExtension/tests/popup_ui.py --base http://127.0.0.1:8765 --release-assets docs/assets
```

生成的 `docs/assets/browser-light-en.png`、`browser-dark-en.png`、`browser-light-zh.png`、`browser-dark-zh.png` 均为**真实扩展 UI 的测试数据界面**，使用 `tests/preview-api.js` 中的示例网页名称和音量，不代表采集了用户网页或实际音频。官网展示时请附注「测试数据界面 / Interface shown with sample data」。
