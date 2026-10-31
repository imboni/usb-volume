"""Release contracts: shipped metadata, complete languages, and local docs links."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import json
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]

def load_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            assert key not in result, f'Duplicate key {key} in {path}'
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=pairs)

info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
manifest = load_json(ROOT / 'BrowserExtension/manifest.json')
assert manifest['version'] == version, 'Native and browser versions must match'
languages = set(info['CFBundleLocalizations'])
website_files = list((ROOT / 'docs/locales').glob('*.json'))
assert {path.stem for path in website_files} == languages
english = load_json(ROOT / 'docs/locales/en.json')
for path in website_files:
    messages = load_json(path)
    assert messages.keys() == english.keys(), f'Incomplete website locale: {path.stem}'
    assert all(isinstance(value, str) and value.strip() for value in messages.values())
    assert not any('<script' in value.lower() for value in messages.values())

class Links(HTMLParser):
    def __init__(self):
        super().__init__(); self.links = []; self.keys = set(); self.ids = set(); self.languages = set()
    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        self.links.extend(attrs[key] for key in ('href', 'src') if attrs.get(key))
        self.keys.update(attrs[key] for key in ('data-i18n', 'data-i18n-alt', 'data-i18n-aria') if attrs.get(key))
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, f'Duplicate HTML ID: {attrs["id"]}'
            self.ids.add(attrs['id'])
        if tag == 'option': self.languages.add(attrs['value'])

for relative in ['docs/index.html', 'README.md', 'README.zh-CN.md', 'CONTRIBUTING.md']:
    path = ROOT / relative
    content = path.read_text()
    parsed = Links(); parsed.feed(content)
    links = parsed.links + re.findall(r'(?<!!)\[[^\]]+\]\(([^)]+)\)', content)
    for link in links:
        url = urlsplit(link)
        if '/releases/download/' in link or '/releases/tag/' in link:
            assert f'/v{version}/' in link or link.endswith(f'/v{version}'), f'Stale release: {link}'
        if url.scheme or url.netloc: continue
        if not url.path:
            if relative.endswith('.html'): assert url.fragment in parsed.ids
            continue
        target = (path.parent / unquote(url.path)).resolve()
        assert target.is_relative_to(ROOT), f'Local link leaves checkout: {link}'
        assert target.exists(), f'Missing local file: {relative} → {link}'
    if relative == 'docs/index.html':
        assert parsed.keys == english.keys() - {'title', 'description'}
        assert parsed.languages == languages

for language in ['en', 'zh']:
    for kind in ['mixer-light', 'mixer-dark', 'browser-light']:
        image = ROOT / f'docs/assets/{kind}-{language}.png'
        assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), f'Missing screenshot: {image}'
assert (ROOT / f'releases/v{version}.md').exists()
assert f'## {version}' in (ROOT / 'CHANGELOG.md').read_text()
assert manifest.get('default_locale') == 'en'
extension_codes = {'zh-Hans': 'zh_CN', 'zh-Hant': 'zh_TW', 'pt-BR': 'pt_BR'}
assert {p.name for p in (ROOT / 'BrowserExtension/_locales').iterdir() if p.is_dir()} == {extension_codes.get(code, code) for code in languages}
print(f'Release {version}: versions, {len(languages)} website/extension languages, {len(english)} website keys, links and screenshots passed.')
