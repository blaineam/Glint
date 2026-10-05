// node --test Scripts/tests/ — the app's string catalog is complete and format-safe.
//
// Glint ships in en + 8 languages. A key without a translation silently shows English,
// and a translation whose printf specifiers differ from the source can crash
// String(format:) at runtime, so both are release blockers.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const catalog = JSON.parse(readFileSync(join(root, 'Glint/Resources/Localizable.xcstrings'), 'utf8'));
const LOCALES = ['de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'zh-Hans'];

// Argument-consuming specifiers as Xcode extracts them (%@, %lld, %1$@, %.1f, …).
const SPEC = /%(?:\d+\$)?(?:\.\d+)?(?:ll|l|h|hh|z|q)?[@dDiuUxXoOfeEgGcCsSp]/g;
const specs = (s) => (s.match(SPEC) ?? []).map((m) => m.replace(/^%\d+\$/, '%')).sort();

const translatable = Object.entries(catalog.strings).filter(([, v]) => v.shouldTranslate !== false);

test('catalog declares English as the source language', () => {
  assert.equal(catalog.sourceLanguage, 'en');
  assert.ok(translatable.length > 0);
});

for (const locale of LOCALES) {
  test(`every string is translated into ${locale}`, () => {
    const missing = translatable
      .filter(([, v]) => {
        const unit = v.localizations?.[locale]?.stringUnit;
        const variations = v.localizations?.[locale]?.variations;
        if (variations) return false; // plural/device variants are validated by Xcode
        return !unit || unit.state !== 'translated' || !unit.value?.trim();
      })
      .map(([k]) => k);
    assert.deepEqual(missing, [], `untranslated in ${locale}`);
  });

  test(`${locale} translations keep the source's format specifiers`, () => {
    const bad = [];
    for (const [key, v] of translatable) {
      const value = v.localizations?.[locale]?.stringUnit?.value;
      if (value == null) continue;
      if (JSON.stringify(specs(key)) !== JSON.stringify(specs(value))) {
        bad.push(`${key.slice(0, 50)} → ${specs(key)} vs ${specs(value)}`);
      }
    }
    assert.deepEqual(bad, []);
  });
}
