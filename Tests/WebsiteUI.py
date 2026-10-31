"""Browser checks for the shipped static product site; no external requests needed."""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--base', default='http://127.0.0.1:8765/docs')
parser.add_argument('--output', default='build/website-ui')
args = parser.parse_args()
base = args.base.rstrip('/') + '/'
output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
languages = sorted(path.stem for path in (root / 'docs/locales').glob('*.json'))

with sync_playwright() as p:
    browser = p.chromium.launch(channel='chrome', headless=True)
    context = browser.new_context(viewport={'width': 1280, 'height': 900}, device_scale_factor=1)
    page = context.new_page()
    errors = []; page.on('pageerror', lambda error: errors.append(str(error)))
    for language in languages:
        messages = json.loads((root / f'docs/locales/{language}.json').read_text())
        for width in [1280, 375, 320]:
            page.set_viewport_size({'width': width, 'height': 900})
            page.goto(base + '?lang=' + language)
            expect(page.locator('html')).to_have_attribute('data-locale-ready', language)
            expect(page.locator('html')).to_have_attribute('dir', 'rtl' if language == 'ar' else 'ltr')
            expect(page.locator('h1')).to_contain_text(messages['headline1'])
            expect(page).to_have_title(messages['title'])
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), f'Overflow: {language}/{width}'
            assert page.locator('[data-i18n]').evaluate_all('(nodes) => nodes.every(node => node.textContent.trim())')
            # Load even below-fold images to verify every shipped screenshot.
            page.locator('img').evaluate_all('(images) => images.forEach(image => image.loading = "eager")')
            page.wait_for_function('Array.from(document.images).every(image => image.complete && image.naturalWidth > 0)')
            assert page.locator('a.button, select, summary').evaluate_all('(nodes) => nodes.every(node => node.getBoundingClientRect().width > 25)')
            if width == 375:
                page.locator('summary').first.click()
                assert page.locator('details').first.get_attribute('open') is not None
                expect(page.locator('details p').first).to_be_visible()
            if language in ['en', 'zh-Hans', 'ar'] and width != 320:
                page.evaluate('window.scrollTo(0, 0)')
                page.screenshot(path=str(output / f'{language}-{width}.png'), full_page=True)

    page.goto(base + '?lang=en')
    expect(page.locator('html')).to_have_attribute('data-locale-ready', 'en')
    page.locator('#language').select_option('ar')
    expect(page.locator('html')).to_have_attribute('lang', 'ar')
    expect(page).to_have_url(base + '?lang=ar')
    page.goto(base)
    expect(page.locator('html')).to_have_attribute('lang', 'ar')
    page.locator('#language').select_option('zh-Hant')
    expect(page.locator('html')).to_have_attribute('dir', 'ltr')
    expect(page.locator('html')).to_have_attribute('lang', 'zh-Hant')
    page.evaluate('''() => { const s=document.querySelector('#language'); for (const code of ['ru','ja','en']) { s.value=code; s.dispatchEvent(new Event('change')); } }''')
    expect(page.locator('html')).to_have_attribute('lang', 'en')
    expect(page.locator('#language')).to_have_value('en')

    # Failed fetch retains the current translated page and restores the picker.
    page.route('**/locales/de.json', lambda route: route.abort())
    page.locator('#language').select_option('de')
    expect(page.locator('#language')).to_have_value('en')
    expect(page.locator('html')).to_have_attribute('lang', 'en')
    expect(page.locator('#language-status')).not_to_be_empty()
    page.unroute('**/locales/de.json')

    page.emulate_media(reduced_motion='reduce')
    assert page.locator('.button').first.evaluate('(el) => getComputedStyle(el).transitionDuration') == '0s'
    page.emulate_media(reduced_motion='no-preference')
    page.keyboard.press('Tab')
    expect(page.locator('html')).to_have_attribute('data-input', 'keyboard')
    assert page.locator('.button').first.evaluate('(el) => getComputedStyle(el).transitionDuration') == '0s'
    assert page.locator(':focus-visible').count() > 0

    for requested, expected in [('zh-HK','zh-Hant'), ('zh-SG','zh-Hans'), ('pt-PT','pt-BR'), ('fr-CA','fr')]:
        page.goto(base + '?lang=' + requested)
        expect(page.locator('html')).to_have_attribute('lang', expected)
    fallback = browser.new_context(locale='sv-SE', java_script_enabled=True)
    fallback.add_init_script('Object.defineProperty(window, "localStorage", { get() { throw new Error("Storage disabled"); } });')
    fallback_page = fallback.new_page(); fallback_page.goto(base + '?lang=unknown')
    expect(fallback_page.locator('html')).to_have_attribute('data-locale-ready', 'en')
    fallback.close()
    no_js = browser.new_context(java_script_enabled=False)
    plain = no_js.new_page(); plain.goto(base)
    expect(plain.locator('h1')).to_contain_text('Every sound.')
    expect(plain.locator('.download')).to_have_attribute('href', 'https://github.com/imboni/usb-volume/releases/download/v0.3.0/USBVolume-0.3.0-arm64.zip')
    no_js.close()
    assert not errors, errors
    context.close(); browser.close()
print(f'Website: {len(languages)} languages × 3 widths; images, RTL, language persistence/races/fallback, keyboard, reduced motion and no-JS passed.')
