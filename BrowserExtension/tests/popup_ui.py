"""Real-popup browser tests against deterministic local APIs, never actual capture.

Requires Python Playwright + Chrome. Serve the repo root on localhost first:
  python3 -m http.server 8765 --bind 127.0.0.1
  python3 BrowserExtension/tests/popup_ui.py --base http://127.0.0.1:8765
"""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--base', default='http://127.0.0.1:8765')
parser.add_argument('--output', default='build/browser-ui')
parser.add_argument('--release-assets', help='Optional directory for English/Chinese light/dark fixture screenshots')
args = parser.parse_args()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
base = args.base.rstrip('/') + '/BrowserExtension/tests/preview.html'
folders = {'en': 'en', 'zh-Hans': 'zh_CN', 'zh-Hant': 'zh_TW', 'ja': 'ja', 'ko': 'ko',
           'fr': 'fr', 'de': 'de', 'es': 'es', 'it': 'it', 'pt-BR': 'pt_BR', 'ru': 'ru',
           'ar': 'ar', 'hi': 'hi', 'id': 'id'}
catalogs = {locale: {key: entry['message'] for key, entry in json.loads(
    (Path(__file__).resolve().parents[1] / '_locales' / folder / 'messages.json').read_text()).items()}
    for locale, folder in folders.items()}
aliases = {'en-US': 'en', 'zh-CN': 'zh-Hans', 'zh-TW': 'zh-Hant', 'zh-HK': 'zh-Hant',
           'pt-PT': 'pt-BR', 'fr-CA': 'fr', 'ar-SA': 'ar', 'nl-NL': 'en'}

with sync_playwright() as p:
    browser = p.chromium.launch(channel='chrome', headless=True)
    context = browser.new_context(viewport={'width': 320, 'height': 600}, device_scale_factor=2)
    page = context.new_page()
    page.add_init_script('''
      window.__motionCalls = [];
      const animate = Element.prototype.animate;
      Element.prototype.animate = function(frames, options) {
        window.__motionCalls.push({ frames, options });
        return animate.call(this, frames, options);
      };
    ''')
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))

    def load(scenario='multiple', language='zh-CN', theme='light', motion='reduce'):
        page.emulate_media(color_scheme=theme, reduced_motion=motion)
        page.goto(base + '?scenario=' + scenario + '&lang=' + language)
        page.wait_for_load_state('networkidle')
        page.wait_for_function('window.__fixture?.ready && document.querySelector("#current-title")?.textContent.length > 0')
        resolved = language if language in folders else aliases.get(language, 'en')
        expect(page.locator('html')).to_have_attribute('lang', resolved)
        expect(page.locator('#subtitle')).to_have_text(catalogs[resolved]['subtitle'])
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'No horizontal overflow'

    def readable_text():
        # Explicit contrast checks on the quiet labels most vulnerable to regressions.
        pairs = page.evaluate('''() => {
          const bg = getComputedStyle(document.documentElement).backgroundColor;
          return ['#subtitle', '.title', 'output'].map(selector => ({
            color: getComputedStyle(document.querySelector(selector)).color, background: bg, selector
          }));
        }''')
        def luminance(rgb):
            components = [float(n) / 255 for n in rgb[rgb.index('(') + 1:rgb.index(')')].split(',')[:3]]
            values = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in components]
            return sum(v * w for v, w in zip(values, [.2126, .7152, .0722]))
        for pair in pairs:
            light, dark = sorted([luminance(pair['color']), luminance(pair['background'])], reverse=True)
            assert (light + .05) / (dark + .05) >= 4.5, 'Readable label: ' + pair['selector']

    def screenshot(name):
        page.locator('body').screenshot(path=str(output / name))

    # Three independent pages, long-title truncation, muted state, native accessibility.
    load()
    expect(page.locator('.tab-row')).to_have_count(3)
    expect(page.locator('#enable')).to_be_hidden()
    expect(page.locator('#current')).to_be_hidden()
    assert page.locator('body').evaluate('(el) => el.getBoundingClientRect().height <= 300'), 'Three-page popup stays compact'
    assert page.locator('body').evaluate('(el) => el.getBoundingClientRect().width === 320'), 'Compact 320px width'
    expect(page.locator('[data-tab-id="8"] .mute')).to_have_attribute('aria-pressed', 'true')
    assert page.locator('[data-tab-id="9"] .title').evaluate('(el) => el.title.startsWith(el.textContent) && el.title.includes("podcasts.example.com")'), 'Tooltip preserves full title and domain'
    assert page.locator('[data-tab-id="9"] .title').evaluate('(el) => el.scrollWidth > el.clientWidth'), 'Long title truncates'
    assert page.locator('button').evaluate_all('(buttons) => buttons.every(el => el.textContent.trim() || el.getAttribute("aria-label"))'), 'Every button has an accessible name'
    readable_text()
    assert page.locator('main').evaluate('(el) => el.scrollHeight <= el.clientHeight + 1'), 'Three rows fit without clipping'
    screenshot('popup-light.png')
    load(theme='dark')
    readable_text()
    screenshot('popup-dark.png')

    # Keyboard edits unmute one page and preserve the others. Repeated keys while
    # responses are delayed must keep the user's final slider value.
    slider = page.locator('[data-tab-id="8"] input')
    slider.focus()
    assert slider.evaluate('(el) => el.matches(":focus-visible")'), 'Keyboard focus remains visible'
    page.evaluate('window.__fixture.latency = 35')
    for _ in range(6):
        slider.press('ArrowLeft')
    expect(slider).to_have_value('62')
    page.wait_for_function('window.__fixture.tabs().find(t => t.tabId === 8).volume === .62')
    expect(page.locator('[data-tab-id="8"] .mute')).to_have_attribute('aria-pressed', 'false')
    assert page.evaluate('window.__fixture.tabs().find(t => t.tabId === 7).volume') == .42
    page.locator('[data-tab-id="8"] .mute').click()
    expect(page.locator('[data-tab-id="8"] .mute')).to_have_attribute('aria-pressed', 'true')
    page.locator('[data-tab-id="8"] .reset').click()
    expect(slider).to_have_value('100')
    expect(page.locator('[data-tab-id="8"] .mute')).to_have_attribute('aria-pressed', 'false')
    page.wait_for_function('window.__fixture.tabs().find(t => t.tabId === 8).volume === 1')
    page.locator('[data-tab-id="8"] .stop').click()
    expect(page.locator('.tab-row')).to_have_count(2)
    expect(page.locator('[data-tab-id="7"] output')).to_have_text('42%')
    expect(page.locator('[data-tab-id="7"] .mute')).to_be_focused()

    # Physical pointer drag and keyboard bounds retain native range behavior.
    load()
    slider = page.locator('[data-tab-id="7"] input')
    box = slider.bounding_box()
    page.mouse.move(box['x'] + box['width'] * .42, box['y'] + box['height'] / 2)
    page.mouse.down()
    page.mouse.move(box['x'] + box['width'] * .25, box['y'] + box['height'] / 2, steps=5)
    page.mouse.up()
    page.wait_for_function('window.__fixture.tabs().find(t => t.tabId === 7).volume < .3')
    slider.press('Home')
    expect(slider).to_have_value('0')
    slider.press('End')
    expect(slider).to_have_value('100')

    # Empty -> start -> controlled, with a clear connecting state and no big disabled CTA.
    load('empty')
    expect(page.locator('#current')).to_be_visible()
    expect(page.locator('.tab-row')).to_have_count(0)
    expect(page.locator('#enable')).to_be_enabled()
    screenshot('popup-empty.png')
    page.locator('#help-label').click()
    expect(page.locator('#hint')).to_be_visible()
    page.wait_for_function('document.querySelector(".help-content").getBoundingClientRect().bottom <= document.body.getBoundingClientRect().bottom')
    assert page.locator('.help-content').evaluate('(el) => el.getBoundingClientRect().bottom <= document.body.getBoundingClientRect().bottom'), 'Help fits even in the smallest popup'
    page.locator('#help-label').click()
    page.evaluate('window.__fixture.latency = 120')
    page.locator('#enable').click()
    expect(page.locator('#enable')).to_have_attribute('aria-busy', 'true')
    expect(page.locator('#enable-label')).to_have_text('正在连接…')
    expect(page.locator('.tab-row')).to_have_count(1)
    expect(page.locator('#enable')).to_be_hidden()
    expect(page.locator('#current')).to_be_hidden()
    expect(page.locator('.tab-row input')).to_be_focused()

    # Error is recoverable, not just logged; dismissing keeps controls intact.
    load('error')
    page.locator('#enable').click()
    expect(page.locator('#error')).to_be_visible()
    expect(page.locator('#enable')).to_be_enabled()
    expect(page.locator('.tab-row')).to_have_count(3)
    screenshot('popup-error.png')
    page.get_by_role('button', name='关闭错误提示').click()
    expect(page.locator('#error')).to_be_hidden()

    # Restricted page, many-tab scroll, English, and on-demand help.
    load('disconnected')
    expect(page.locator('#error')).to_contain_text('请关闭弹窗后重新打开重试。')
    expect(page.locator('#enable')).to_be_disabled()
    expect(page.locator('#enable-label')).to_have_text('控制此页')
    load('restricted')
    expect(page.locator('#enable')).to_be_disabled()
    expect(page.locator('#enable-label')).to_have_text('不支持此页')
    load('many', 'en-US')
    expect(page.locator('.tab-row')).to_have_count(12)
    assert page.locator('main').evaluate('(el) => el.scrollHeight > el.clientHeight'), 'Many tabs scroll inside the popup'
    screenshot('popup-english.png')
    page.locator('#help-label').click()
    expect(page.locator('#hint')).to_be_visible()
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Expanded help fits'
    assert page.locator('body').evaluate('(el) => el.getBoundingClientRect().height <= 600'), 'Help stays within browser popup height limit'
    load('long')
    assert page.locator('#current-title').evaluate('(el) => el.scrollWidth > el.clientWidth'), 'Uncontrolled current page title is truncated'
    assert page.locator('body').evaluate('(el) => el.getBoundingClientRect().height <= 340'), 'Three rows plus current-page action stay compact'
    screenshot('popup-long-title.png')
    # Motion is limited to opacity/transform, and all motion stops for reduced
    # motion and keyboard input, including continuous native range adjustments.
    load(motion='no-preference')
    assert page.locator('body').evaluate('(el) => !el.classList.contains("entering")'), 'Entry fade ends and cannot replay'
    page.locator('[data-tab-id="7"] .mute').click()
    page.wait_for_function('window.__fixture.tabs().find(t => t.tabId === 7).muted')
    motions = page.evaluate('window.__motionCalls')
    assert len(motions) == 1 and motions[0]['options']['duration'] == 140, 'Pointer mute has one short state transition'
    assert all(set(frame) <= {'opacity', 'transform'} for frame in motions[0]['frames']), 'Only composited properties animate'
    assert page.locator('[data-tab-id="7"] .mute').evaluate('(el) => getComputedStyle(el).transitionProperty') == 'opacity, transform'
    slider = page.locator('[data-tab-id="7"] input')
    slider.focus(); slider.press('ArrowLeft')
    assert page.locator('body').get_attribute('data-input') == 'keyboard'
    assert page.locator('body').evaluate('(el) => getComputedStyle(el).animationName') == 'none'
    assert page.locator('.mute').first.evaluate('(el) => getComputedStyle(el).transitionDuration') == '0s'
    assert page.evaluate('document.getAnimations().length') == 0
    assert len(page.evaluate('window.__motionCalls')) == 1, 'Keyboard volume changes do not animate'
    page.locator('[data-tab-id="7"] .reset').click()
    assert page.locator('body').evaluate('(el) => getComputedStyle(el).animationName') == 'none', 'Returning to pointer input does not replay entry'
    load(motion='reduce')
    page.locator('[data-tab-id="7"] .mute').click()
    assert page.locator('body').evaluate('(el) => getComputedStyle(el).animationName') == 'none'
    assert page.locator('.mute').first.evaluate('(el) => getComputedStyle(el).transitionDuration') == '0s'
    assert page.evaluate('document.getAnimations().length') == 0
    assert page.evaluate('window.__motionCalls.length') == 0, 'Reduced motion disables scripted state effects too'
    page.locator('#help-label').click()
    expect(page.locator('#hint')).to_be_visible()
    page.keyboard.press('Escape')
    expect(page.locator('#hint')).to_be_hidden()
    expect(page.locator('#help-label')).to_be_focused()
    # All supported locales: localized controls/ARIA/percentages, compact layouts,
    # expandable long help, accessible errors and normal physical range keys.
    for language, catalog in catalogs.items():
        load(language=language)
        expect(page.locator('html')).to_have_attribute('dir', 'rtl' if language == 'ar' else 'ltr')
        expect(page.locator('[data-tab-id="7"] .mute')).to_have_attribute('aria-label',
            catalog['mute'] + ' · \u2068' + page.locator('[data-tab-id="7"] .title').inner_text() + '\u2069')
        value = page.evaluate('''() => new Intl.NumberFormat(document.documentElement.lang,
            {style: 'percent', maximumFractionDigits: 0,
             ...(document.documentElement.lang === 'ar' ? {numberingSystem: 'arab'} : {})}).format(.42)''')
        expect(page.locator('[data-tab-id="7"] output')).to_have_text(value)
        expect(page.locator('[data-tab-id="7"] input')).to_have_attribute('aria-valuetext', value)
        assert page.locator('body').evaluate('(el) => el.getBoundingClientRect().height <= 300'), language + ': compact controls'
        if language == 'ar':
            assert page.locator('#subtitle').bounding_box()['x'] > page.locator('#help-label').bounding_box()['x'], 'RTL header mirrors'
            expect(page.locator('[data-tab-id="7"] input')).to_have_attribute('dir', 'ltr')
            page.locator('[data-tab-id="7"] input').press('ArrowLeft')
            expect(page.locator('[data-tab-id="7"] input')).to_have_value('41')
            screenshot('popup-arabic.png')
        load('empty', language)
        expect(page.locator('#enable-label')).to_have_text(catalog['enable'])
        assert page.locator('#enable').evaluate('(el) => el.scrollWidth <= el.clientWidth + 1'), language + ': full primary label fits'
        page.locator('#help-label').click()
        expect(page.locator('#hint')).to_have_text(catalog['hint'])
        page.wait_for_function('document.querySelector(".help-content").getBoundingClientRect().bottom <= document.body.getBoundingClientRect().bottom')
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), language + ': help has no horizontal overflow'
        page.locator('#help-label').click()
        page.evaluate('window.__fixture.failNext = "Permission denied"')
        page.locator('#enable').click()
        expect(page.locator('#error-text')).to_have_text(catalog['failure'] + catalog['errorPermission'])
        assert page.locator('#error-text').evaluate('(el) => el.scrollWidth <= el.clientWidth + 1'), language + ': error wraps'

    for language in ['zh-TW', 'zh-HK', 'pt-PT', 'fr-CA', 'nl-NL']:
        load(language=language)

    # Publication images are actual popup pixels with deterministic test data.
    # No audio is captured; the website must caption them as example/test data.
    if args.release_assets:
        assets = Path(args.release_assets).resolve()
        assets.mkdir(parents=True, exist_ok=True)
        for language, suffix in [('en', 'en'), ('zh-Hans', 'zh')]:
            for theme in ['light', 'dark']:
                load(language=language, theme=theme)
                page.locator('body').screenshot(path=str(assets / ('browser-' + theme + '-' + suffix + '.png')))
    assert errors == [], f'No uncaught browser errors: {errors}'
    browser.close()
print('Popup UI: 14 locales, RTL, fallback, localized errors/percentages, themes, independent controls, keyboard races, focus, compact layout and motion passed.')
print('Screenshots: ' + str(output))
