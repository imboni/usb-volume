"use strict";
(() => {
  const picker = document.querySelector("#language");
  const supported = [...picker.options].map(option => option.value);
  let request = 0;
  let current = "en";
  function resolveLanguage(value) {
    const language = String(value || "").replaceAll("_", "-").toLowerCase();
    if (language === "zh" || language.startsWith("zh-")) return /(?:^|-)hant(?:-|$)|(?:^|-)(?:tw|hk|mo)(?:-|$)/.test(language) ? "zh-Hant" : "zh-Hans";
    if (language === "pt" || language.startsWith("pt-")) return "pt-BR";
    return supported.find(code => code.toLowerCase() === language) || supported.find(code => code === language.split("-")[0]);
  }
  function setText(messages) {
    for (const node of document.querySelectorAll("[data-i18n]")) if (messages[node.dataset.i18n]) node.textContent = messages[node.dataset.i18n];
    for (const [attribute, dataAttribute] of [["aria-label", "i18nAria"], ["alt", "i18nAlt"]]) {
      for (const node of document.querySelectorAll(attribute === "alt" ? "[data-i18n-alt]" : "[data-i18n-aria]")) {
        if (messages[node.dataset[dataAttribute]]) node.setAttribute(attribute, messages[node.dataset[dataAttribute]]);
      }
    }
    document.title = messages.title;
    document.querySelector('meta[property="og:title"]').content = messages.title;
    document.querySelector('meta[name="description"]').content = messages.description;
    document.querySelector('meta[property="og:description"]').content = messages.description;
  }
  async function changeLanguage(language, remember = false) {
    const generation = ++request;
    picker.setAttribute("aria-busy", "true");
    try {
      const response = await fetch("./locales/" + language + ".json");
      if (!response.ok) throw new Error("Language unavailable");
      const messages = await response.json();
      if (generation !== request) return;
      setText(messages);
      current = language;
      document.documentElement.lang = language;
      document.documentElement.dir = language === "ar" ? "rtl" : "ltr";
      document.documentElement.dataset.localeReady = language;
      document.querySelector('meta[property="og:locale"]').content = ({ en: "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "pt-BR": "pt_BR" })[language] || language;
      picker.value = language;
      const screenshotLanguage = language.startsWith("zh") ? "zh" : "en";
      const nativeScreenshotLanguage = language === "ar" ? "ar" : screenshotLanguage;
      document.querySelector("#hero-screenshot").src = "./assets/mixer-light-" + nativeScreenshotLanguage + ".png";
      document.querySelector("#dark-screenshot").src = "./assets/mixer-dark-" + nativeScreenshotLanguage + ".png";
      document.querySelector("#browser-screenshot").src = "./assets/browser-light-" + screenshotLanguage + ".png";
      document.querySelector("#language-status").textContent = "";
      if (remember) {
        try { localStorage.setItem("usb-volume-language", language); } catch {}
        const url = new URL(location.href);
        url.searchParams.set("lang", language);
        history.replaceState(null, "", url);
      }
    } catch {
      if (generation !== request) return;
      picker.value = current;
      if (current === "en") document.documentElement.dataset.localeReady = "en";
      document.querySelector("#language-status").textContent = "Language could not be loaded. Please try again.";
    } finally {
      if (generation === request) picker.removeAttribute("aria-busy");
    }
  }
  let stored;
  try { stored = localStorage.getItem("usb-volume-language"); } catch {}
  const requested = new URL(location.href).searchParams.get("lang");
  const preferred = resolveLanguage(requested) || resolveLanguage(stored) || (navigator.languages || [navigator.language]).map(resolveLanguage).find(Boolean) || "en";
  picker.addEventListener("change", () => changeLanguage(picker.value, true));
  document.addEventListener("keydown", () => { document.documentElement.dataset.input = "keyboard"; }, { passive: true });
  document.addEventListener("pointerdown", () => { document.documentElement.dataset.input = "pointer"; }, { passive: true });
  changeLanguage(preferred);
})();
