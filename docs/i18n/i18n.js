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
 * Language resolution: ?lang= URL param → localStorage → navigator.language,
 * falling back to English. An explicit choice (param or switcher) persists.
 *
 * The script tag configures the page:
 *   <script src="/i18n/i18n.js" defer
 *           data-page="apps.ari-helper"    (dictionary basename)
 *           data-pos="bottom-left"></script>  (switcher corner, optional)
 */
(function () {
  'use strict';

  var script = document.currentScript ||
    document.querySelector('script[src*="i18n.js"][data-page]');
  if (!script) return;

  var PAGE = script.getAttribute('data-page') || 'index';
  var POS = script.getAttribute('data-pos') || 'bottom-right';
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
  var STORE_KEY = 'wemiller-lang';
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

  function switchTo(lang) {
    try { localStorage.setItem(STORE_KEY, lang); } catch (e) {}
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
    '.i18n-switcher-btn{display:inline-flex;align-items:center;gap:6px;padding:10px 14px;border-radius:50px;cursor:pointer;' +
    'color:inherit;background:rgba(255,255,255,0.25);border:1px solid rgba(255,255,255,0.18);' +
    '-webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);' +
    'box-shadow:0 8px 32px 0 rgba(31,38,135,0.15);transition:transform .25s ease,box-shadow .25s ease;font:inherit;}' +
    '.i18n-switcher-btn:hover{transform:translateY(-2px);box-shadow:0 12px 40px 0 rgba(31,38,135,0.25);}' +
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
    '.i18n-switcher-btn{background:rgba(15,23,42,0.65);border-color:rgba(255,255,255,0.08);color:#f8fafc;box-shadow:0 8px 32px 0 rgba(0,0,0,0.35);}' +
    '.i18n-switcher-menu{background:rgba(15,23,42,0.88);border-color:rgba(255,255,255,0.1);}' +
    '.i18n-switcher-item{color:#f8fafc;}' +
    '.i18n-switcher-item:hover{background:rgba(102,126,234,0.3);}' +
    '.i18n-switcher-item[aria-current="true"]{background:rgba(102,126,234,0.22);}}' +
    '@media (max-width:768px){.i18n-switcher.i18n-bottom-right{bottom:16px;right:16px;}' +
    '.i18n-switcher.i18n-bottom-left{bottom:16px;left:16px;}' +
    '.i18n-switcher.i18n-top-right{top:16px;right:16px;}}';

  function buildSwitcher(current) {
    var style = document.createElement('style');
    style.textContent = SWITCHER_CSS;
    document.head.appendChild(style);

    var wrap = document.createElement('div');
    wrap.className = 'i18n-switcher i18n-' + POS;

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'i18n-switcher-btn';
    btn.setAttribute('aria-haspopup', 'true');
    btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('aria-label', 'Language');
    btn.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
      '<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.8"/>' +
      '<path d="M3.6 9h16.8M3.6 15h16.8M12 3a14.6 14.6 0 0 1 0 18M12 3a14.6 14.6 0 0 0 0 18"' +
      ' stroke="currentColor" stroke-width="1.8"/></svg>' +
      '<span></span>';
    btn.querySelector('span').textContent = (NAMES[current] || current);

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

    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      var open = wrap.classList.toggle('i18n-open');
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    document.addEventListener('click', function (e) {
      if (!wrap.contains(e.target)) {
        wrap.classList.remove('i18n-open');
        btn.setAttribute('aria-expanded', 'false');
      }
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        wrap.classList.remove('i18n-open');
        btn.setAttribute('aria-expanded', 'false');
      }
    });

    wrap.appendChild(btn);
    wrap.appendChild(menu);
    document.body.appendChild(wrap);
  }

  function init() {
    var lang = resolveLang();
    buildSwitcher(lang);
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
