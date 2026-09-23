/* Site-wide static i18n runtime — dependency-free.
 *
 * How it works
 * ------------
 * English is the content baked into every page (SEO / no-JS baseline).
 * Each localized page has a per-page dictionary at /i18n/<page>.<lang>.json
 * mapping stable keys to translated strings. Elements opt in with:
 *
 *   data-i18n="key"        → textContent is replaced
 *   data-i18n-html="key"   → innerHTML is replaced (value keeps inline markup)
 *   data-i18n-attr="attr:key[;attr2:key2]" → named attributes are replaced
 *
 * Special keys: "_title" (document.title), "_meta.description".
 *
 * Localized screenshots
 * ---------------------
 * An <img> or <picture><source> carrying a bare `data-i18n-src` attribute is
 * swapped to the visitor's language. The baked-in English URL names the
 * locale as a path segment — `…/screens/en/01-reader-800.webp` — and every
 * URL in src and srcset has that segment replaced by the active language.
 * Availability comes from `…/screens/manifest.json`, written by
 * scripts/sync-app-screens.py next to the images, so a locale that has no
 * render yet keeps English without a 404 ever being requested. The manifest
 * also carries each file's content hash, which becomes the `?v=` stamp.
 * Swaps are all-or-nothing per element: if any candidate in its srcset is
 * missing for the language, the element stays English. og:image is never
 * touched. See docs/app-page-design.md.
 *
 * Language resolution: ?lang= URL param → localStorage → navigator.language,
 * falling back to English. An explicit choice (param or switcher) persists.
 *
 * The script tag configures the page:
 *   <script src="/i18n/i18n.js" defer
 *           data-page="apps.ari-helper"    (dictionary basename)
 *           data-pos="bottom-left"></script>  (switcher corner, optional)
 *
 * Switcher presentation
 * ---------------------
 * Default: a fixed pill in a screen corner (data-pos), showing the current
 * language name. Every page but the home page uses this.
 *
 * Opt-in "anchored" mode, for pages that want the control to live inside
 * their own layout instead of floating over it:
 *
 *   data-anchor="#navigable-links"        (CSS selector for the mount point)
 *   data-anchor-class="liquidGlass button" (host classes copied onto the
 *                                           trigger so it inherits the page's
 *                                           own button styling)
 *
 * In anchored mode the trigger collapses to a circular globe and expands on
 * hover/focus into a pill that cross-fades to the current language name; the
 * menu flips above the trigger when there is no room below it.
 */
(function () {
  'use strict';

  var script = document.currentScript ||
    document.querySelector('script[src*="i18n.js"][data-page]');
  if (!script) return;

  var PAGE = script.getAttribute('data-page') || 'index';
  var POS = script.getAttribute('data-pos') || 'bottom-right';
  var ANCHOR = script.getAttribute('data-anchor') || '';
  var ANCHOR_CLASS = script.getAttribute('data-anchor-class') || '';
  // data-langs lets a page restrict its language set (unused today, but the
  // mechanism exists for pages with export-compliance limits, e.g. Haven).
  var LANGS = (script.getAttribute('data-langs') ||
    'en,zh-Hans,ja,de,fr,es,ko,pt-BR,it').split(',');
  var NAMES = {
    'en': 'English',
    'zh-Hans': '简体中文',
    'ja': '日本語',
    'de': 'Deutsch',
    'fr': 'Français',
    'es': 'Español',
    'ko': '한국어',
    'pt-BR': 'Português (Brasil)',
    'it': 'Italiano'
  };
  // The anchored pill is width-constrained by the card it sits in, so it uses
  // a shorter display form where the menu's full name would not fit.
  var SHORT_NAMES = { 'pt-BR': 'Português' };
  var STORE_KEY = 'wemiller-lang';
  var SWITCHED_KEY = 'wemiller-lang-switched';
  var BASE = (function () {
    // Dictionaries live next to this script, wherever it is served from.
    try { return new URL('.', script.src).href; }
    catch (e) { return '/i18n/'; }
  })();

  function normalize(code) {
    if (!code) return null;
    // Exact match first (case-insensitive), then primary-subtag match.
    var lower = String(code).toLowerCase();
    for (var i = 0; i < LANGS.length; i++) {
      if (LANGS[i].toLowerCase() === lower) return LANGS[i];
    }
    var primary = lower.split('-')[0];
    if (primary === 'zh') return LANGS.indexOf('zh-Hans') >= 0 ? 'zh-Hans' : null;
    if (primary === 'pt') return LANGS.indexOf('pt-BR') >= 0 ? 'pt-BR' : null;
    for (var j = 0; j < LANGS.length; j++) {
      if (LANGS[j].toLowerCase().split('-')[0] === primary) return LANGS[j];
    }
    return null;
  }

  function resolveLang() {
    var param = null;
    try {
      param = new URLSearchParams(window.location.search).get('lang');
    } catch (e) { /* ancient browser: fall through */ }
    var fromParam = normalize(param);
    if (fromParam) {
      try { localStorage.setItem(STORE_KEY, fromParam); } catch (e) {}
      return fromParam;
    }
    var stored = null;
    try { stored = localStorage.getItem(STORE_KEY); } catch (e) {}
    var fromStore = normalize(stored);
    if (fromStore) return fromStore;
    var nav = navigator.languages || [navigator.language || 'en'];
    for (var i = 0; i < nav.length; i++) {
      var n = normalize(nav[i]);
      if (n) return n;
    }
    return 'en';
  }

  function applyDict(dict, lang) {
    if (dict._title) document.title = dict._title;
    if (dict['_meta.description']) {
      var meta = document.querySelector('meta[name="description"]');
      if (meta) meta.setAttribute('content', dict['_meta.description']);
    }
    var nodes = document.querySelectorAll('[data-i18n]');
    for (var i = 0; i < nodes.length; i++) {
      var key = nodes[i].getAttribute('data-i18n');
      if (Object.prototype.hasOwnProperty.call(dict, key)) {
        nodes[i].textContent = dict[key];
      }
    }
    var htmlNodes = document.querySelectorAll('[data-i18n-html]');
    for (var h = 0; h < htmlNodes.length; h++) {
      var hkey = htmlNodes[h].getAttribute('data-i18n-html');
      if (Object.prototype.hasOwnProperty.call(dict, hkey)) {
        htmlNodes[h].innerHTML = dict[hkey];
      }
    }
    var attrNodes = document.querySelectorAll('[data-i18n-attr]');
    for (var a = 0; a < attrNodes.length; a++) {
      var pairs = attrNodes[a].getAttribute('data-i18n-attr').split(';');
      for (var p = 0; p < pairs.length; p++) {
        var idx = pairs[p].indexOf(':');
        if (idx < 0) continue;
        var attr = pairs[p].slice(0, idx).trim();
        var akey = pairs[p].slice(idx + 1).trim();
        if (Object.prototype.hasOwnProperty.call(dict, akey)) {
          attrNodes[a].setAttribute(attr, dict[akey]);
        }
      }
    }
    // Some pages stamp the current year into <span id="year"> before the
    // dictionary arrives; replacing a parent's innerHTML wipes it. Restore.
    var year = document.getElementById('year');
    if (year && !year.textContent) year.textContent = new Date().getFullYear();
    document.documentElement.setAttribute('lang', lang);
    try {
      document.dispatchEvent(new CustomEvent('i18n:applied', {
        detail: { lang: lang, dict: dict }
      }));
    } catch (e) { /* CustomEvent unsupported: non-fatal */ }
  }

  /* ---- localized screenshots ------------------------------------------ */

  var SCREEN_SELECTOR = 'img[data-i18n-src], source[data-i18n-src]';
  var SCREEN_SEGMENT = '/screens/en/';
  var manifestCache = {};

  // The manifest that describes a screenshot URL: `<prefix>/screens/manifest.json`.
  function manifestUrl(url) {
    var at = url.indexOf(SCREEN_SEGMENT);
    if (at < 0) return null;
    try {
      return new URL(url.slice(0, at) + '/screens/manifest.json', document.baseURI).href;
    } catch (e) { return null; }
  }

  function loadManifest(href) {
    if (!manifestCache[href]) {
      manifestCache[href] = fetch(href)
        .then(function (res) {
          if (!res.ok) throw new Error('no screens manifest');
          return res.json();
        })
        .catch(function () { return null; });
    }
    return manifestCache[href];
  }

  // One URL for `lang`, or null when the manifest does not list that file.
  function localizeUrl(url, lang, files) {
    var at = url.indexOf(SCREEN_SEGMENT);
    if (at < 0) return url; // not a screenshot URL: leave it alone
    var rest = url.slice(at + SCREEN_SEGMENT.length).split('?')[0].split('#')[0];
    var hash = files[lang + '/' + rest];
    if (!hash) return null;
    return url.slice(0, at) + '/screens/' + lang + '/' + rest + '?v=' + hash;
  }

  function localizeSrcset(srcset, lang, files) {
    var parts = srcset.split(','), out = [];
    for (var i = 0; i < parts.length; i++) {
      var bits = parts[i].trim().split(/\s+/);
      if (!bits[0]) continue;
      var url = localizeUrl(bits[0], lang, files);
      if (url === null) return null;
      bits[0] = url;
      out.push(bits.join(' '));
    }
    return out.join(', ');
  }

  // Swap every tagged screenshot to `lang`, falling back to the baked-in
  // English per element. Safe to call again with another language: the
  // English originals are remembered on first touch.
  function applyScreens(lang) {
    var nodes = document.querySelectorAll(SCREEN_SELECTOR);
    if (!nodes.length) return;
    for (var i = 0; i < nodes.length; i++) {
      (function (node) {
        if (!node._i18nScreen) {
          node._i18nScreen = {
            src: node.getAttribute('src'),
            srcset: node.getAttribute('srcset')
          };
        }
        var orig = node._i18nScreen;
        var probe = orig.src || (orig.srcset || '').trim().split(/\s+/)[0] || '';
        var href = manifestUrl(probe);
        if (!href) return;
        var restore = function () {
          if (orig.srcset !== null && node.getAttribute('srcset') !== orig.srcset) node.setAttribute('srcset', orig.srcset);
          if (orig.src !== null && node.getAttribute('src') !== orig.src) node.setAttribute('src', orig.src);
        };
        if (lang === 'en') { restore(); return; }
        loadManifest(href).then(function (manifest) {
          var files = manifest && manifest.files;
          if (!files) { restore(); return; }
          var srcset = orig.srcset !== null ? localizeSrcset(orig.srcset, lang, files) : null;
          var src = orig.src !== null ? localizeUrl(orig.src, lang, files) : null;
          if ((orig.srcset !== null && srcset === null) || (orig.src !== null && src === null)) {
            restore();
            return;
          }
          // srcset before src, so the browser never picks a candidate from
          // the old set against the new fallback.
          if (srcset !== null) node.setAttribute('srcset', srcset);
          if (src !== null) node.setAttribute('src', src);
        });
      })(nodes[i]);
    }
  }

  function switchTo(lang) {
    try { localStorage.setItem(STORE_KEY, lang); } catch (e) {}
    // Survives the reload below so the anchored pill can come back already
    // expanded on the newly chosen language (it collapses on mouse-leave).
    try { sessionStorage.setItem(SWITCHED_KEY, '1'); } catch (e) {}
    var url = new URL(window.location.href);
    if (lang === 'en') url.searchParams.delete('lang');
    else url.searchParams.set('lang', lang);
    // Full reload: restores baked-in English cleanly and re-runs
    // document.write-driven content in the new language.
    window.location.href = url.toString();
  }

  var SWITCHER_CSS =
    '.i18n-switcher{position:fixed;z-index:2147483000;font:600 0.85rem/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}' +
    '.i18n-switcher.i18n-bottom-right{bottom:24px;right:24px;}' +
    '.i18n-switcher.i18n-bottom-left{bottom:24px;left:24px;}' +
    '.i18n-switcher.i18n-top-right{top:24px;right:24px;}' +
    '.i18n-switcher.i18n-top-left{top:24px;left:24px;}' +
    // Corner-pill chrome. Scoped away from anchored mode so a host page's own
    // button classes (data-anchor-class) can own the surface there.
    '.i18n-switcher:not(.i18n-anchored) .i18n-switcher-btn{display:inline-flex;align-items:center;gap:6px;padding:10px 14px;border-radius:50px;cursor:pointer;' +
    'color:inherit;background:rgba(255,255,255,0.25);border:1px solid rgba(255,255,255,0.18);' +
    '-webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);' +
    'box-shadow:0 8px 32px 0 rgba(31,38,135,0.15);transition:transform .25s ease,box-shadow .25s ease;font:inherit;}' +
    '.i18n-switcher:not(.i18n-anchored) .i18n-switcher-btn:hover{transform:translateY(-2px);box-shadow:0 12px 40px 0 rgba(31,38,135,0.25);}' +
    '.i18n-switcher-menu{position:absolute;min-width:170px;max-height:60vh;overflow-y:auto;margin:8px 0;padding:6px;border-radius:16px;' +
    'background:rgba(255,255,255,0.72);border:1px solid rgba(255,255,255,0.3);' +
    '-webkit-backdrop-filter:blur(24px) saturate(180%);backdrop-filter:blur(24px) saturate(180%);' +
    'box-shadow:0 12px 40px 0 rgba(31,38,135,0.25);display:none;}' +
    '.i18n-switcher.i18n-open .i18n-switcher-menu{display:block;}' +
    '.i18n-bottom-right .i18n-switcher-menu,.i18n-bottom-left .i18n-switcher-menu{bottom:100%;}' +
    '.i18n-top-right .i18n-switcher-menu,.i18n-top-left .i18n-switcher-menu{top:100%;}' +
    '.i18n-bottom-right .i18n-switcher-menu,.i18n-top-right .i18n-switcher-menu{right:0;}' +
    '.i18n-bottom-left .i18n-switcher-menu,.i18n-top-left .i18n-switcher-menu{left:0;}' +
    '.i18n-switcher-item{display:block;width:100%;text-align:left;padding:9px 12px;border:0;border-radius:10px;cursor:pointer;' +
    'background:transparent;color:#161616;font:inherit;font-weight:500;}' +
    '.i18n-switcher-item:hover{background:rgba(102,126,234,0.18);}' +
    '.i18n-switcher-item[aria-current="true"]{font-weight:700;background:rgba(102,126,234,0.12);}' +
    '@media (prefers-color-scheme: dark){' +
    '.i18n-switcher:not(.i18n-anchored) .i18n-switcher-btn{background:rgba(15,23,42,0.65);border-color:rgba(255,255,255,0.08);color:#f8fafc;box-shadow:0 8px 32px 0 rgba(0,0,0,0.35);}' +
    '.i18n-switcher-menu{background:rgba(15,23,42,0.88);border-color:rgba(255,255,255,0.1);}' +
    '.i18n-switcher-item{color:#f8fafc;}' +
    '.i18n-switcher-item:hover{background:rgba(102,126,234,0.3);}' +
    '.i18n-switcher-item[aria-current="true"]{background:rgba(102,126,234,0.22);}}' +
    '@media (max-width:768px){.i18n-switcher.i18n-bottom-right{bottom:16px;right:16px;}' +
    '.i18n-switcher.i18n-bottom-left{bottom:16px;left:16px;}' +
    '.i18n-switcher.i18n-top-right{top:16px;right:16px;}}';

  /* Anchored mode: a circular globe that expands on hover into a pill whose
     label cross-fades in. Sizing rides on two custom properties set from JS —
     --i18n-size (collapsed diameter, matched to the host page's own buttons)
     and --i18n-expanded (the hovered pill width). */
  var ANCHORED_CSS =
    '.i18n-switcher.i18n-anchored{position:absolute;left:50%;bottom:0;transform:translateX(-50%);z-index:5;}' +
    '.i18n-anchored .i18n-switcher-btn{position:relative;display:block;box-sizing:border-box;' +
    'width:var(--i18n-size,34px);height:var(--i18n-size,34px);min-width:0;padding:0;border-radius:999px;' +
    'overflow:hidden;cursor:pointer;color:inherit;font:inherit;' +
    'transition:width .42s cubic-bezier(.4,0,.2,1),background .3s ease,box-shadow .3s ease;}' +
    '.i18n-anchored.i18n-expanded .i18n-switcher-btn{width:var(--i18n-expanded,var(--i18n-size,34px));}' +
    '.i18n-anchored .i18n-face{position:absolute;top:0;bottom:0;display:flex;align-items:center;' +
    'justify-content:center;pointer-events:none;transition:opacity .45s ease;}' +
    '.i18n-anchored .i18n-globe{left:50%;width:var(--i18n-size,34px);' +
    'margin-left:calc(var(--i18n-size,34px) / -2);opacity:1;}' +
    '.i18n-anchored .i18n-globe svg{width:56%;height:56%;display:block;}' +
    '.i18n-anchored .i18n-label{left:0;right:0;padding:0 13px;opacity:0;}' +
    '.i18n-anchored .i18n-label span{display:block;max-width:100%;overflow:hidden;' +
    'text-overflow:ellipsis;white-space:nowrap;}' +
    '.i18n-anchored.i18n-expanded .i18n-globe{opacity:0;}' +
    '.i18n-anchored.i18n-expanded .i18n-label{opacity:1;}' +
    // Off-screen twin used to measure the natural label width.
    '.i18n-anchored .i18n-measure{position:absolute;left:-9999px;top:0;right:auto;bottom:auto;' +
    'width:auto;padding:0;white-space:nowrap;opacity:0;visibility:hidden;pointer-events:none;}' +
    '.i18n-anchored .i18n-switcher-menu{left:50%;right:auto;top:calc(100% + 10px);bottom:auto;margin:0;' +
    'transform:translateX(calc(-50% + var(--i18n-menu-shift,0px)));}' +
    '.i18n-anchored.i18n-flip-up .i18n-switcher-menu{top:auto;bottom:calc(100% + 10px);}' +
    // Still scrollable when the viewport is short; just without the chrome,
    // which is how the rest of the page treats its scroll areas.
    '.i18n-anchored .i18n-switcher-menu{scrollbar-width:none;-ms-overflow-style:none;}' +
    '.i18n-anchored .i18n-switcher-menu::-webkit-scrollbar{display:none;}' +
    '@media (prefers-reduced-motion: reduce){' +
    '.i18n-anchored .i18n-switcher-btn,.i18n-anchored .i18n-face{transition:none;}}';

  // Only used when the host page did not hand us its own button classes.
  var ANCHORED_FALLBACK_CSS =
    '.i18n-anchored .i18n-switcher-btn{background:rgba(255,255,255,0.25);' +
    'border:1px solid rgba(255,255,255,0.18);box-shadow:0 8px 32px 0 rgba(31,38,135,0.15);' +
    '-webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);}' +
    '@media (prefers-color-scheme: dark){.i18n-anchored .i18n-switcher-btn{' +
    'background:rgba(15,23,42,0.65);border-color:rgba(255,255,255,0.08);' +
    'box-shadow:0 8px 32px 0 rgba(0,0,0,0.35);}}';

  var GLOBE_SVG =
    '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">' +
    '<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="2"/>' +
    '<path d="M3.2 9h17.6M3.2 15h17.6M12 3a14.6 14.6 0 0 1 0 18M12 3a14.6 14.6 0 0 0 0 18"' +
    ' stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';

  function buildSwitcher(current) {
    var host = ANCHOR ? document.querySelector(ANCHOR) : null;
    var anchored = !!host;

    var style = document.createElement('style');
    style.textContent = SWITCHER_CSS +
      (anchored ? ANCHORED_CSS + (ANCHOR_CLASS ? '' : ANCHORED_FALLBACK_CSS) : '');
    document.head.appendChild(style);

    var wrap = document.createElement('div');
    wrap.className = 'i18n-switcher ' + (anchored ? 'i18n-anchored' : 'i18n-' + POS);

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'i18n-switcher-btn' +
      (anchored && ANCHOR_CLASS ? ' ' + ANCHOR_CLASS : '');
    btn.setAttribute('aria-haspopup', 'true');
    btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('aria-label', 'Language: ' + (NAMES[current] || current));

    var measure = null;
    if (anchored) {
      btn.innerHTML =
        '<span class="i18n-face i18n-globe">' + GLOBE_SVG + '</span>' +
        '<span class="i18n-face i18n-label"><span></span></span>';
      btn.querySelector('.i18n-label span').textContent =
        SHORT_NAMES[current] || NAMES[current] || current;
      measure = document.createElement('span');
      measure.className = 'i18n-label i18n-measure';
      measure.setAttribute('aria-hidden', 'true');
      measure.textContent = SHORT_NAMES[current] || NAMES[current] || current;
    } else {
      btn.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
        '<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.8"/>' +
        '<path d="M3.6 9h16.8M3.6 15h16.8M12 3a14.6 14.6 0 0 1 0 18M12 3a14.6 14.6 0 0 0 0 18"' +
        ' stroke="currentColor" stroke-width="1.8"/></svg>' +
        '<span></span>';
      btn.querySelector('span').textContent = (NAMES[current] || current);
    }

    var menu = document.createElement('div');
    menu.className = 'i18n-switcher-menu';
    menu.setAttribute('role', 'menu');

    for (var i = 0; i < LANGS.length; i++) {
      (function (lang) {
        var item = document.createElement('button');
        item.type = 'button';
        item.className = 'i18n-switcher-item';
        item.setAttribute('role', 'menuitem');
        item.setAttribute('lang', lang);
        if (lang === current) item.setAttribute('aria-current', 'true');
        item.textContent = NAMES[lang] || lang;
        item.addEventListener('click', function () {
          if (lang !== current) switchTo(lang);
        });
        menu.appendChild(item);
      })(LANGS[i]);
    }

    /* ---- anchored geometry -------------------------------------------- */

    var FALLBACK_SIZE = 34;

    // Match the collapsed circle to whatever sits alongside us in the host
    // (the Summary / Projects toggles), so the row reads as one control set.
    // `widest` only counts siblings that are actually on screen — the host
    // swaps its two toggles by fading one out, and the faded one should not
    // steal room from the expanded pill.
    function siblingMetrics() {
      var widest = 0, size = 0, kids = host.children;
      for (var k = 0; k < kids.length; k++) {
        if (kids[k] === wrap) continue;
        var h = kids[k].offsetHeight;
        if (h > size) size = h;
        if (getComputedStyle(kids[k]).pointerEvents === 'none') continue;
        var w = kids[k].offsetWidth;
        if (w > widest) widest = w;
      }
      return { widest: widest, size: size };
    }

    function syncWidth() {
      var m = siblingMetrics();
      var size = m.size || FALLBACK_SIZE;
      wrap.style.setProperty('--i18n-size', size + 'px');

      // 26px of label padding plus a few px so the text never clips to "…".
      var natural = Math.max(size, (measure ? measure.offsetWidth : 0) + 30);
      var hostW = host.clientWidth || 0;
      if (hostW) {
        // We grow from the centre, so the visible toggle on either side caps
        // us. On a phone the longest names still ellipsise — the menu below
        // always spells them out in full.
        var room = hostW - 2 * (m.widest + 5);
        if (room < size) room = hostW - 10;
        if (natural > room) natural = Math.max(size, room);
      }
      wrap.style.setProperty('--i18n-expanded', Math.round(natural) + 'px');
    }

    // Re-measure on the way open: which toggle is showing (and therefore how
    // much room we have) changes when the card flips Summary <-> Projects.
    function expand() {
      if (!anchored) return;
      syncWidth();
      wrap.classList.add('i18n-expanded');
    }
    // Keyboard focus holds the pill open; a click leaves the button focused
    // too, so :focus-visible (not :focus) is what we ask about.
    function keyboardFocused() {
      var el = document.activeElement;
      if (!el || !wrap.contains(el)) return false;
      try { return el.matches(':focus-visible'); } catch (e) { return true; }
    }

    var hovered = false;

    function collapse() {
      if (anchored && !hovered && !wrap.classList.contains('i18n-open') &&
          !keyboardFocused()) {
        wrap.classList.remove('i18n-expanded');
      }
    }

    // Menu placement: prefer downward, flip above when the viewport says no.
    function placeMenu() {
      if (!anchored) return;
      wrap.classList.remove('i18n-flip-up');
      menu.style.maxHeight = '';
      menu.style.setProperty('--i18n-menu-shift', '0px');
      var r = btn.getBoundingClientRect();
      var vh = window.innerHeight || document.documentElement.clientHeight;
      var vw = window.innerWidth || document.documentElement.clientWidth;
      var below = vh - r.bottom - 20;
      var above = r.top - 20;
      var need = menu.scrollHeight + 2; // +2: avoid a 1px rounding scrollbar
      var room = below;
      if (need > below && above > below) {
        wrap.classList.add('i18n-flip-up');
        room = above;
      }
      menu.style.maxHeight = Math.max(120, Math.min(need, room)) + 'px';
      var mr = menu.getBoundingClientRect();
      var shift = 0;
      if (mr.left < 8) shift = 8 - mr.left;
      else if (mr.right > vw - 8) shift = vw - 8 - mr.right;
      if (shift) menu.style.setProperty('--i18n-menu-shift', Math.round(shift) + 'px');
    }

    function setOpen(open) {
      wrap.classList.toggle('i18n-open', open);
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) { expand(); placeMenu(); }
      else collapse();
    }

    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      setOpen(!wrap.classList.contains('i18n-open'));
    });
    document.addEventListener('click', function (e) {
      if (!wrap.contains(e.target)) setOpen(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') setOpen(false);
    });

    if (anchored) {
      wrap.addEventListener('mouseenter', function () { hovered = true; expand(); });
      wrap.addEventListener('mouseleave', function () { hovered = false; collapse(); });
      wrap.addEventListener('focusin', expand);
      wrap.addEventListener('focusout', function () {
        // activeElement updates after focusout; defer the check.
        setTimeout(collapse, 0);
      });
      window.addEventListener('resize', function () {
        syncWidth();
        if (wrap.classList.contains('i18n-open')) placeMenu();
      });
    }

    wrap.appendChild(btn);
    wrap.appendChild(menu);
    if (measure) wrap.appendChild(measure);
    (anchored ? host : document.body).appendChild(wrap);

    if (anchored) {
      syncWidth();
      // The label's width moves under us when a web font (or a CJK fallback)
      // swaps in after first layout — re-measure whenever the twin resizes.
      if (window.ResizeObserver) {
        try { new ResizeObserver(syncWidth).observe(measure); } catch (e) {}
      } else if (document.fonts && document.fonts.ready) {
        document.fonts.ready.then(syncWidth).catch(function () {});
      }
      // Coming back from a language switch: show the new name, then let the
      // ordinary mouse-leave (or a beat, where hover does not exist) collapse.
      var justSwitched = false;
      try {
        justSwitched = sessionStorage.getItem(SWITCHED_KEY) === '1';
        if (justSwitched) sessionStorage.removeItem(SWITCHED_KEY);
      } catch (e) {}
      if (justSwitched) {
        expand();
        var hoverless = !window.matchMedia ||
          window.matchMedia('(hover: none)').matches;
        if (hoverless) {
          setTimeout(collapse, 2600);
        } else {
          // The pointer may already be sitting on the pill, in which case no
          // mouseenter is coming; the first move off it collapses us instead.
          var release = function (e) {
            if (wrap.contains(e.target)) return;
            document.removeEventListener('mousemove', release);
            hovered = false;
            collapse();
          };
          document.addEventListener('mousemove', release);
        }
      }
    }
  }

  function init() {
    var lang = resolveLang();
    buildSwitcher(lang);
    // Screenshots don't wait on the dictionary: a page with renders but a
    // missing or failed dictionary still shows its own language's screens.
    applyScreens(lang);
    window.wemillerI18n = { lang: lang, applyScreens: applyScreens };
    if (lang === 'en') {
      document.documentElement.setAttribute('lang', 'en');
      return;
    }
    fetch(BASE + PAGE + '.' + lang + '.json')
      .then(function (res) {
        if (!res.ok) throw new Error('missing dictionary: ' + PAGE + '.' + lang);
        return res.json();
      })
      .then(function (dict) { applyDict(dict, lang); })
      .catch(function () { /* fall back to baked-in English */ });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
