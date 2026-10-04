#!/usr/bin/env node
// Turns this repo's built GitHub Pages site (the old <app>.wemiller.com address) into
// redirects to each page's copy on wemiller.com, whose mirror-app-docs workflow rsyncs
// the same source folder from this repo (never from the deployed Pages site).
//
//   node .github/legacy-site.mjs <builtSite> <sourceDir> <newBase> [--keep <path>]...
//
// - Only HTML pages that exist in <sourceDir> at the same relative path are replaced: those
//   are exactly the pages the portfolio mirrors, so each one forwards to its own copy and never
//   to a 404. Anything else in the build (generated pages, files the mirror leaves out) stays.
// - Paths with a segment starting with '_' (_src/, _preview.html) are never mirrored, so stay.
// - --keep <path> leaves a mirrored page as it is (deep-link landing pages, for example).
// - Every non-HTML file (.well-known/, JSON, images, downloads) is untouched and still served.
//
// The redirect keeps the path, the query and the hash: JS location.replace, a meta refresh
// for browsers without JS, and rel=canonical pointing at the new address.
import { readdirSync, readFileSync, writeFileSync, statSync, existsSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const args = process.argv.slice(2);
const keep = new Set();
const positional = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--keep') keep.add(args[++i].replace(/^\/+/, ''));
  else positional.push(args[i]);
}
const [site, source, base] = positional;
if (!site || !source || !base || !base.endsWith('/')) {
  console.error('usage: legacy-site.mjs <builtSite> <sourceDir> <newBase ending in /> [--keep <path>]...');
  process.exit(2);
}
if (!existsSync(join(site, 'index.html'))) throw new Error(`${site}: no index.html — build first`);

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* walk(full);
    else yield full;
  }
}

const esc = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');

function page(target) {
  const t = esc(target);
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Moved to wemiller.com</title>
<link rel="canonical" href="${t}">
<script>
  // This site moved to ${base}. Same page, same query, same #fragment.
  (function () {
    var path = location.pathname.replace(/^\\/+/, '');
    location.replace(${JSON.stringify(base)} + path + location.search + location.hash);
  })();
</script>
<meta http-equiv="refresh" content="0; url=${t}">
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px; box-sizing: border-box; font: 1.05rem/1.5 system-ui, -apple-system, sans-serif; text-align: center; }
</style>
</head>
<body>
<p>This page has moved to <a href="${t}">${esc(target.replace(/^https:\/\//, ''))}</a>.</p>
</body>
</html>
`;
}

const redirected = [];
const kept = [];
for (const file of walk(site)) {
  if (!file.endsWith('.html')) continue;
  const rel = relative(site, file).split(sep).join('/');
  if (keep.has(rel) || rel.split('/').some((seg) => seg.startsWith('_')) || !existsSync(join(source, rel))) { kept.push(rel); continue; }
  const url = rel === 'index.html' ? '' : rel.endsWith('/index.html') ? rel.slice(0, -'index.html'.length) : rel;
  writeFileSync(file, page(base + url));
  redirected.push(rel);
}
console.log(`redirected → ${base}:\n  ${redirected.sort().join('\n  ')}`);
console.log(`served as-is:\n  ${kept.sort().join('\n  ') || '(none)'}`);
