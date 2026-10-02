"""Reject incomplete translations and unsafe printf format changes before shipping."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f"Duplicate key: {key}"
        result[key] = value
    return result

def formats(text):
    return re.findall(r"%(?:\d+\$)?(?:\.\d+)?[@df]|%%", text)

catalogs = {p.stem: json.loads(p.read_text(), object_pairs_hook=unique_object)
            for p in (ROOT / "Resources/Localization").glob("*.json")}
expected = {"en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt-BR", "ru", "ar", "hi", "id"}
assert set(catalogs) == expected, f"Missing/extra languages: {expected ^ set(catalogs)}"
baseline = catalogs["en"]
for language, catalog in catalogs.items():
    assert catalog.keys() == baseline.keys(), f"Incomplete language: {language}"
    for key, value in catalog.items():
        assert isinstance(value, str) and value.strip(), (language, key)
        assert formats(value) == formats(key), (language, key, "format mismatch")
        assert value.count("\n") == key.count("\n"), (language, key, "newline mismatch")
for path in (ROOT / "Sources").glob("*.[mh]"):
    for value in re.findall(r'UVL\(@"((?:\\.|[^"\\])*)"\)', path.read_text()):
        key = value.replace(r"\n", "\n").replace(r'\"', '"')
        assert key in baseline, f"Untranslated key in {path.name}: {key}"
print(f"Localization resources: {len(catalogs)} languages × {len(baseline)} keys, formats and coverage passed.")
