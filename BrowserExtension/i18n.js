// These are the same 14 interface languages offered by the macOS app.
export const supportedLocales = Object.freeze({
  en: 'en', 'zh-Hans': 'zh_CN', 'zh-Hant': 'zh_TW', ja: 'ja', ko: 'ko',
  fr: 'fr', de: 'de', es: 'es', it: 'it', 'pt-BR': 'pt_BR', ru: 'ru', ar: 'ar', hi: 'hi', id: 'id'
});

export function resolveLocale(preferences = []) {
  for (const preference of preferences) {
    if (typeof preference !== 'string') continue;
    let locale;
    try { locale = new Intl.Locale(preference.replaceAll('_', '-')); } catch { continue; }
    if (locale.language === 'zh') {
      if (locale.script) return locale.script === 'Hant' ? 'zh-Hant' : 'zh-Hans';
      return ['TW', 'HK', 'MO'].includes(locale.region) ? 'zh-Hant' : 'zh-Hans';
    }
    if (locale.language === 'pt') return 'pt-BR';
    if (Object.hasOwn(supportedLocales, locale.language)) return locale.language;
  }
  return 'en';
}

function messages(catalog) {
  return Object.fromEntries(Object.entries(catalog || {}).flatMap(([key, value]) =>
    typeof value?.message === 'string' && value.message.trim() ? [[key, value.message]] : []));
}

async function readCatalog(folder) {
  const response = await fetch(new URL(`./_locales/${folder}/messages.json`, import.meta.url));
  if (!response.ok) throw new Error('Locale resource unavailable');
  return response.json();
}

export async function loadLocale(preferences, read = readCatalog) {
  let locale = resolveLocale(preferences);
  const english = messages(await read('en'));
  let selected = {};
  if (locale !== 'en') {
    try { selected = messages(await read(supportedLocales[locale])); } catch { locale = 'en'; }
    if (!Object.keys(selected).length) locale = 'en';
  }
  // Missing or invalid translated entries fall back individually to English.
  const copy = Object.fromEntries(Object.entries(english).map(([key, value]) => [key, selected[key] || value]));
  const formatter = new Intl.NumberFormat(locale, {
    style: 'percent', maximumFractionDigits: 0, ...(locale === 'ar' ? { numberingSystem: 'arab' } : {})
  });
  return {
    locale,
    direction: locale === 'ar' ? 'rtl' : 'ltr',
    copy,
    percent(value) { return formatter.format(Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0); }
  };
}

// Isolate page-controlled text inside translated accessibility labels and tooltips.
export function isolate(text) { return '\u2068' + text + '\u2069'; }

export function localizedError(message, copy, fallback = copy.errorOperation) {
  if (typeof message !== 'string' || !message || ['No response', 'Audio processor unavailable'].includes(message)) return copy.errorConnection;
  if (['Capture timed out', 'Playback startup timed out'].includes(message)) return copy.errorTimeout;
  if (message === 'Tab is no longer controlled') return copy.errorTabEnded;
  if (message.startsWith('请在需要控制的普通网页上点击扩展')) return copy.errorUnavailable;
  if (/denied|permission|not allowed|not been invoked/i.test(message)) return copy.errorPermission;
  if (['No audio track', 'Capture ended before playback started', 'Audio playback unavailable'].includes(message)) return copy.errorCapture;
  return fallback;
}
