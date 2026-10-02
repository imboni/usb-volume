"use strict";

const messages = {
  "zh": {
    "nav": "主导航",
    "skip": "跳到主要内容",
    "features": "功能",
    "install": "安装",
    "download": "免费下载 Mac 版",
    "eyebrow": "给 USB 音箱的菜单栏小工具",
    "line1": "USB 接上。",
    "line2": "音量，随手调。",
    "intro": "给无法直接调节音量的 USB 音箱，一个常驻 Mac 菜单栏的滑块。",
    "demoLabel": "音量交互演示，不播放声音",
    "device": "USB 音箱",
    "try": "拖动试试",
    "demoCaption": "交互示意，不播放声音。",
    "demoVolume": "演示音量",
    "mute": "静音演示",
    "unmute": "取消静音",
    "muted": "已静音",
    "volume": "音量",
    "compatibility": "适用于双声道、无输入通道的 USB 输出设备。已在 MOONDROP MM3A 上验证。",
    "featureTitle": "需要的功能，刚刚好。",
    "featureSub": "留在菜单栏，不占 Dock。",
    "volumeTitle": "滑动调节，点击静音",
    "volumeBody": "记住音量与输出设备，下次打开接着用。",
    "feedbackTitle": "调节之后，轻响一声",
    "feedbackBody": "松开滑块获得声音反馈。静音或零音量时保持安静。",
    "languagesTitle": "14 种界面语言",
    "languagesBody": "跟随系统，或在设置中选择熟悉的语言。",
    "loginTitle": "可选登录时启动",
    "loginBody": "在设置中开启，登录 Mac 后自动回到菜单栏。",
    "local": "音频只在本机处理，不保存、不上传，不读取麦克风。",
    "installTitle": "三步，准备好。",
    "installSub": "适用于搭载 Apple 芯片的 Mac。",
    "step1Title": "下载，移入应用程序",
    "step1Body": "解压 ZIP，将「USB 音量.app」移入「应用程序」文件夹。",
    "step2Title": "允许首次打开",
    "step2Body": "本版尚未公证。如被 macOS 阻止，在「系统设置 → 隐私与安全性」中选择「仍要打开」。",
    "step3Title": "连接音箱，调节音量",
    "step3Body": "退出 eqMac 等音频处理软件。按提示允许系统音频录制，再点击顶部菜单栏图标。",
    "faqTitle": "使用前，了解这些。",
    "q1": "我的 USB 音箱可以用吗？",
    "a1": "目前面向双声道、没有输入通道的 USB 输出设备，已在 MOONDROP MM3A 的 48 kHz 音频通路验证。其他设备的兼容性可能不同；不支持 Intel Mac。",
    "q2": "为什么需要系统音频录制权限？",
    "a2": "应用需要读取正在播放的系统音频，调节音量后送回音箱。这个权限名称由 macOS 提供；应用只在内存中处理音频，不录制文件、不上传，也不读取麦克风。",
    "q3": "能用键盘音量键吗？",
    "a3": "键盘音量键支持正在完善，需要单独授予辅助功能权限，目前仍需在实际设备上验证。建议以菜单栏滑块作为主要控制方式。",
    "q4": "系统音量滑块还会变灰吗？",
    "a4": "可能会。USB Volume 通过自己的菜单栏滑块控制声音，不会改变设备对 macOS 原生音量控制的支持。",
    "q5": "退出应用后会怎样？",
    "a5": "音箱会恢复原始音量，声音可能变大。退出或暂停音量控制前，请先暂停播放。",
    "closing": "一个滑块，让 USB 音箱更好用。",
    "closingDownload": "下载 v0.1.0",
    "source": "代码",
    "releases": "版本发布",
    "issues": "反馈问题",
    "title": "USB Volume — USB 音箱，菜单栏调音量",
    "description": "免费的 macOS 菜单栏音量工具，为 USB 音箱提供软件音量、静音和提示音。支持 14 种语言，音频仅在本机处理。"
  },
  "en": {
    "nav": "Main navigation",
    "skip": "Skip to content",
    "features": "Features",
    "install": "Install",
    "download": "Download for Mac — free",
    "eyebrow": "A little menu bar tool for USB speakers",
    "line1": "USB connected.",
    "line2": "Volume in reach.",
    "intro": "A menu bar volume control for USB speakers your Mac can’t adjust directly.",
    "demoLabel": "Interactive volume demo. No audio is played.",
    "device": "USB speaker",
    "try": "Try the slider",
    "demoCaption": "Interactive illustration. No audio is played.",
    "demoVolume": "Demo volume",
    "mute": "Mute demo",
    "unmute": "Unmute",
    "muted": "Muted",
    "volume": "Volume",
    "compatibility": "For stereo USB output devices with no input channels. Tested with MOONDROP MM3A.",
    "featureTitle": "Just the controls you need.",
    "featureSub": "In your menu bar. Out of your Dock.",
    "volumeTitle": "Slide to adjust. Click to mute.",
    "volumeBody": "Your volume and output device are remembered for next time.",
    "feedbackTitle": "A small sound of confirmation.",
    "feedbackBody": "Hear a short tone after you release the slider. Muted and zero volume stay quiet.",
    "languagesTitle": "14 interface languages.",
    "languagesBody": "Follow your system language, or choose your own in Settings.",
    "loginTitle": "Ready when you log in.",
    "loginBody": "Enable launch at login to bring the menu bar control back automatically.",
    "local": "Audio is processed locally. Never saved or uploaded. No microphone access.",
    "installTitle": "Three steps. Ready to listen.",
    "installSub": "For Macs with Apple silicon.",
    "step1Title": "Download and move the app.",
    "step1Body": "Unzip the download and move the app to your Applications folder.",
    "step2Title": "Allow the first launch.",
    "step2Body": "This release is not notarized. If macOS blocks it, choose Open Anyway in System Settings → Privacy & Security.",
    "step3Title": "Connect your speaker.",
    "step3Body": "Quit eqMac or other audio-processing apps. Allow system audio recording when prompted, then click the menu bar icon.",
    "faqTitle": "A few things to know.",
    "q1": "Will it work with my USB speaker?",
    "a1": "The app supports stereo USB output devices with no input channels. It has been tested with MOONDROP MM3A at 48 kHz. Compatibility with other devices may vary. Intel Macs are not supported.",
    "q2": "Why does it need audio recording permission?",
    "a2": "The app reads the system’s playing audio, adjusts its volume, and sends it to your speaker. macOS names this a recording permission. Processing stays in memory: no audio files, uploads, or microphone access.",
    "q3": "Can I use my keyboard’s volume keys?",
    "a3": "Media-key support is still being refined. It needs separate Accessibility permission and further testing on physical devices. Use the menu bar slider as your primary control.",
    "q4": "Will the system volume slider stay disabled?",
    "a4": "It may. USB Volume adjusts audio through its own menu bar slider. It does not change your device’s support for native macOS volume control.",
    "q5": "What happens when I quit?",
    "a5": "Your speaker returns to its original volume, which may be louder. Pause playback before quitting or pausing volume control.",
    "closing": "One slider. A more useful USB speaker.",
    "closingDownload": "Download v0.1.0",
    "source": "Source",
    "releases": "Releases",
    "issues": "Report an issue",
    "title": "USB Volume — Menu bar volume for USB speakers",
    "description": "A free macOS menu bar tool for USB speaker volume, mute, and adjustment feedback. 14 languages. Audio stays on your Mac."
  }
};

(() => {
  const languageButton = document.getElementById("language-toggle");
  const volume = document.getElementById("demo-volume");
  const muteButton = document.getElementById("mute-button");
  const output = document.getElementById("demo-value");
  const symbol = document.getElementById("speaker-symbol");
  const stage = document.getElementById("volume-demo");
  let language = "zh";
  let muted = false;
  try {
    if (localStorage.getItem("usb-volume.site.language") === "en") language = "en";
  } catch (_) { /* Language selection also works when storage is unavailable. */ }

  function updateDemo() {
    const value = Math.min(100, Math.max(0, Number(volume.value) || 0));
    const silent = muted || value === 0;
    volume.style.setProperty("--fill", value + "%");
    volume.setAttribute("aria-valuetext", messages[language].volume + " " + value + "%" +
      (muted ? " · " + messages[language].muted : ""));
    muteButton.setAttribute("aria-label", messages[language][muted ? "unmute" : "mute"]);
    muteButton.setAttribute("aria-pressed", String(muted));
    symbol.setAttribute("href", silent ? "#speaker-muted" : "#speaker");
    stage.dataset.muted = String(muted);
    output.textContent = muted ? messages[language].muted : value + "%";
  }

  function setLanguage(next) {
    language = next === "en" ? "en" : "zh";
    document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
    document.querySelectorAll("[data-i18n]").forEach(element => {
      const text = messages[language][element.dataset.i18n];
      if (text !== undefined) element.textContent = text;
    });
    document.querySelectorAll("[data-i18n-aria]").forEach(element => {
      element.setAttribute("aria-label", messages[language][element.dataset.i18nAria]);
    });
    languageButton.textContent = language === "zh" ? "EN" : "中文";
    languageButton.lang = language === "zh" ? "en" : "zh-CN";
    languageButton.setAttribute("aria-label", language === "zh" ? "Switch to English" : "切换为中文");
    document.title = messages[language].title;
    document.querySelector('meta[name="description"]').content = messages[language].description;
    document.querySelector('meta[property="og:title"]').content = messages[language].title;
    document.querySelector('meta[property="og:description"]').content = messages[language].description;
    document.querySelector('meta[property="og:locale"]').content = language === "zh" ? "zh_CN" : "en_US";
    updateDemo();
  }

  languageButton.addEventListener("click", () => {
    setLanguage(language === "zh" ? "en" : "zh");
    try { localStorage.setItem("usb-volume.site.language", language); } catch (_) {}
  });
  volume.addEventListener("input", () => { muted = false; updateDemo(); });
  muteButton.addEventListener("click", () => { muted = !muted; updateDemo(); });
  setLanguage(language);
})();
