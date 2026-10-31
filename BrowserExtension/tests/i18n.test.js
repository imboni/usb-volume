import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { loadLocale, resolveLocale, supportedLocales, isolate, localizedError } from '../i18n.js';
const root = new URL('../', import.meta.url);
const read = async folder => JSON.parse(await readFile(new URL(`_locales/${folder}/messages.json`, root), 'utf8'));

test('all 14 locales cover UI, accessibility, errors and manifest metadata', async () => {
  const english = await read('en');
  assert.equal(Object.keys(supportedLocales).length, 14);
  assert.deepEqual((await readdir(new URL('_locales/', root))).sort(), Object.values(supportedLocales).sort());
  for (const [locale, folder] of Object.entries(supportedLocales)) {
    const catalog = await read(folder);
    assert.deepEqual(Object.keys(catalog).sort(), Object.keys(english).sort(), locale);
    for (const [key, entry] of Object.entries(catalog)) {
      assert.equal(typeof entry.message, 'string', `${locale}.${key}`);
      assert.ok(entry.message.trim(), `${locale}.${key} is empty`);
      assert.ok(!entry.message.includes('__MSG_'), `${locale}.${key} unresolved placeholder`);
    }
    assert.ok(catalog.extensionName.message.length <= 75, locale);
    assert.ok(catalog.extensionDescription.message.length <= 132, locale);
    const data = await loadLocale([locale], read);
    assert.equal(data.copy.mute, catalog.mute.message, locale);
    assert.equal(data.direction, locale === 'ar' ? 'rtl' : 'ltr');
  }
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
  assert.equal(manifest.default_locale, 'en');
  for (const key of [manifest.name, manifest.description, manifest.action.default_title]) {
    const match = /^__MSG_(.+)__$/.exec(key);
    assert.ok(match && english[match[1]], 'Manifest message exists in fallback locale');
  }
  for (const file of ['popup.js', 'i18n.js']) {
    const source = await readFile(new URL(file, root), 'utf8');
    for (const match of source.matchAll(/copy\.([A-Za-z]+)/g))
      assert.ok(english[match[1]], `${file} references an untranslated message: ${match[1]}`);
  }
});

test('locale resolution distinguishes Chinese scripts, accepts regional variants and uses ordered fallback', () => {
  for (const code of ['zh-TW', 'zh-HK', 'zh-MO', 'zh-Hant', 'zh-Hant-CN', 'zh_TW']) assert.equal(resolveLocale([code]), 'zh-Hant', code);
  for (const code of ['zh', 'zh-CN', 'zh-SG', 'zh-Hans', 'zh-Hans-HK', 'zh_CN']) assert.equal(resolveLocale([code]), 'zh-Hans', code);
  for (const code of ['pt', 'pt-BR', 'pt-PT']) assert.equal(resolveLocale([code]), 'pt-BR', code);
  assert.equal(resolveLocale(['fr-CA']), 'fr');
  assert.equal(resolveLocale(['en-GB', 'ar']), 'en');
  assert.equal(resolveLocale(['not_a_locale', 'nl-NL', 'ar-SA']), 'ar');
  assert.equal(resolveLocale(['in-ID']), 'id');
  assert.equal(resolveLocale([null, {}, '', 'nl-NL']), 'en');
});

test('missing translated entries fall back to English without blank controls', async () => {
  const english = await read('en');
  const data = await loadLocale(['de'], async folder => folder === 'en' ? english : {
    mute: { message: 'Stumm' }, enable: { message: '' }, stop: { message: null }
  });
  assert.equal(data.copy.mute, 'Stumm');
  assert.equal(data.copy.enable, english.enable.message);
  assert.equal(data.copy.stop, english.stop.message);
  const unavailable = await loadLocale(['ar'], async folder => {
    if (folder !== 'en') throw new Error('Missing resource');
    return english;
  });
  assert.equal(unavailable.copy.help, english.help.message);
  assert.equal(unavailable.locale, 'en');
  assert.equal(unavailable.direction, 'ltr');
});

test('percent display and spoken range value follow selected locale while numeric gain remains normalized', async () => {
  for (const locale of Object.keys(supportedLocales)) {
    const data = await loadLocale([locale], read);
    const expected = new Intl.NumberFormat(locale, { style: 'percent', maximumFractionDigits: 0,
      ...(locale === 'ar' ? { numberingSystem: 'arab' } : {}) });
    assert.equal(data.percent(.42), expected.format(.42));
    assert.equal(data.percent(NaN), expected.format(0));
    assert.equal(data.percent(2), expected.format(1));
  }
  const french = await loadLocale(['fr'], read);
  assert.match(french.percent(.42), /42[\u00a0\u202f]％?%/);
  const arabic = await loadLocale(['ar'], read);
  assert.match(arabic.percent(.42), /٤٢/);
  assert.match(arabic.percent(.42), /٪/);
  assert.equal(isolate('English · العربية'), '\u2068English · العربية\u2069');
});

test('known audio failures and unknown platform errors are presented in the selected language', async () => {
  for (const locale of Object.keys(supportedLocales)) {
    const { copy } = await loadLocale([locale], read);
    assert.equal(localizedError('Capture timed out', copy), copy.errorTimeout);
    assert.equal(localizedError('Audio processor unavailable', copy), copy.errorConnection);
    assert.equal(localizedError('Tab is no longer controlled', copy), copy.errorTabEnded);
    assert.equal(localizedError('Permission denied', copy), copy.errorPermission);
    assert.equal(localizedError('Untranslated vendor error', copy, copy.errorCapture), copy.errorCapture);
  }
});
