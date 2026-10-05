// node --test Scripts/tests/ — the website's 9-locale dictionaries stay in sync with the
// pages. docs/i18n/i18n.js swaps text by key, so a key missing from a locale shows
// English, and a key the page uses but the English file lacks shows nothing localized.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const i18nDir = join(root, 'docs/i18n');
const LOCALES = ['en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'zh-Hans'];
const PAGES = { index: 'docs/index.html', faq: 'docs/faq/index.html' };

const load = (page, locale) => JSON.parse(readFileSync(join(i18nDir, `${page}.${locale}.json`), 'utf8'));
const tags = (html) => (html.match(/<\/?[a-z][a-z0-9]*/gi) ?? []).map((t) => t.toLowerCase()).sort();

function pageKeys(html) {
  const keys = { text: new Set(), html: new Set() };
  for (const [, k] of html.matchAll(/data-i18n="([^"]+)"/g)) keys.text.add(k);
  for (const [, k] of html.matchAll(/data-i18n-html="([^"]+)"/g)) keys.html.add(k);
  for (const [, spec] of html.matchAll(/data-i18n-attr="([^"]+)"/g)) {
    for (const pair of spec.split(';')) keys.text.add(pair.split(':').slice(1).join(':').trim());
  }
  return keys;
}

test('no dictionary exists for an unknown page or locale', () => {
  const expected = new Set(Object.keys(PAGES).flatMap((p) => LOCALES.map((l) => `${p}.${l}.json`)));
  const actual = readdirSync(i18nDir).filter((f) => f.endsWith('.json'));
  assert.deepEqual(actual.filter((f) => !expected.has(f)), []);
});

for (const [page, htmlPath] of Object.entries(PAGES)) {
  const html = readFileSync(join(root, htmlPath), 'utf8');
  const en = load(page, 'en');

  test(`${page}: the page loads the ${page} dictionary`, () => {
    assert.match(html, new RegExp(`i18n\\.js[^>]*data-page="${page}"`));
  });

  test(`${page}: every key the page uses exists in English`, () => {
    const { text, html: htmlKeys } = pageKeys(html);
    const missing = [...text, ...htmlKeys].filter((k) => !(k in en));
    assert.deepEqual(missing, []);
    assert.ok(text.size + htmlKeys.size > 0, 'page has no i18n hooks');
  });

  for (const locale of LOCALES.filter((l) => l !== 'en')) {
    test(`${page}.${locale}: same keys as English, all non-empty`, () => {
      const dict = load(page, locale);
      const enKeys = Object.keys(en).sort();
      assert.deepEqual(Object.keys(dict).sort(), enKeys);
      assert.deepEqual(enKeys.filter((k) => typeof dict[k] !== 'string' || !dict[k].trim()), []);
    });

    test(`${page}.${locale}: inline-markup values keep the English tags`, () => {
      const { html: htmlKeys } = pageKeys(html);
      const dict = load(page, locale);
      const bad = [...htmlKeys].filter((k) => JSON.stringify(tags(en[k])) !== JSON.stringify(tags(dict[k] ?? '')));
      assert.deepEqual(bad, []);
    });
  }
}
