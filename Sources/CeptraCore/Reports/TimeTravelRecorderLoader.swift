import Foundation

/// Generates and caches a zero-dependency CodeceptJS plugin that captures per-step
/// time-travel telemetry for BOTH Web and API tests without modifying the user's `codecept.conf.*`:
/// - Web: before/after screenshots, DOM snapshots with target highlighting, browser network/console/pageerror
/// - API: universal Node/Bun `http`/`https` + `globalThis.fetch` + CodeceptJS `REST`/`GraphQL`/`JSONResponse`
///   request/response bodies (with gzip/deflate/br decoding), DNS/TCP/TLS/TTFB/download timings,
///   credential header redaction, synthetic API steps for direct axios/flex-rest/fetch calls outside `I.*`,
///   BeforeSuite setup traffic, and structured assertion linking.
public enum TimeTravelRecorderLoader {
    private static let directoryName = "ceptra-time-travel-v1"
    private static let pluginFileName = "ceptra-time-travel-plugin.cjs"

    public static let redactedHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token"
    ]

    public static let pluginScriptSource: String = #"""
    'use strict';

    const fs = require('node:fs');
    const path = require('node:path');
    const crypto = require('node:crypto');
    const http = require('node:http');
    const https = require('node:https');
    const zlib = require('node:zlib');

    const MAX_DOM_CHARS = 256 * 1024;
    const MAX_BODY_CHARS = 64 * 1024;
    const MAX_CAPTURE_BYTES = 256 * 1024;
    const MAX_CONSOLE_CHARS = 4096;
    const MAX_TARGET_HTML_CHARS = 4096;
    const MAX_HEADER_VALUE_CHARS = 1024;

    const REDACTED_HEADERS = new Set([
      'authorization',
      'proxy-authorization',
      'cookie',
      'set-cookie',
      'x-api-key',
      'x-auth-token'
    ]);

    const LOCATOR_METHODS = new Set([
      'click', 'doubleClick', 'rightClick', 'forceClick', 'clickLink',
      'tap', 'doubleTap', 'longPress', 'scrollIntoView', 'saveElementScreenshot',
      'swipeUp', 'swipeDown', 'swipeLeft', 'swipeRight',
      'fillField', 'appendField', 'clearField', 'selectOption', 'checkOption',
      'uncheckOption', 'attachFile', 'focus', 'blur', 'moveCursorTo', 'scrollTo',
      'seeElement', 'dontSeeElement', 'seeElementInDOM', 'dontSeeElementInDOM',
      'seeInField', 'dontSeeInField', 'seeCheckboxIsChecked', 'dontSeeCheckboxIsChecked',
      'waitForElement', 'waitForVisible', 'waitForInvisible', 'waitForClickable',
      'waitForEnabled', 'waitForDetached', 'waitToHide', 'grabTextFrom',
      'grabTextFromAll', 'grabAttributeFrom', 'grabValueFrom', 'grabHTMLFrom',
      'grabNumberOfVisibleElements', 'pressKey', 'type', 'see', 'dontSee'
    ]);

    const ASSERTION_METHOD_RE = /^(?:seeResponse|dontSeeResponse|expect|assert)/i;
    const TEXT_CONTENT_RE = /(?:json|text|xml|javascript|ecmascript|x-www-form-urlencoded|graphql|csv|yaml|problem\+json)/i;
    const INTERNAL_CONTROL_URL_RE = /^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):\d+\/(?:json(?:\/|$)|devtools\/|wd\/hub\/|session(?:\/|$)|status$)/i;

    function resolveCodeceptJS() {
      try {
        return require('codeceptjs');
      } catch {}
      let dir = process.cwd();
      for (let i = 0; i < 5; i++) {
        try {
          return require(path.join(dir, 'node_modules', 'codeceptjs'));
        } catch {}
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
      }
      if (require.main && typeof require.main.filename === 'string') {
        let mdir = path.dirname(require.main.filename);
        for (let i = 0; i < 6; i++) {
          try {
            return require(path.join(mdir, 'node_modules', 'codeceptjs'));
          } catch {}
          const parent = path.dirname(mdir);
          if (parent === mdir) break;
          mdir = parent;
        }
      }
      return null;
    }

    function genId() {
      return crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    }

    function truncate(str, max) {
      if (typeof str !== 'string') return null;
      if (str.length <= max) return str;
      return str.slice(0, max) + '\n/* [truncated by Ceptra] */';
    }

    function formatBytes(n) {
      if (typeof n !== 'number' || !Number.isFinite(n) || n < 0) return '0 B';
      if (n < 1024) return `${n} B`;
      if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
      return `${(n / (1024 * 1024)).toFixed(2)} MB`;
    }

    function redactHeaders(raw) {
      const out = {};
      if (!raw || typeof raw !== 'object') return out;
      const entries = typeof raw.entries === 'function' ? Array.from(raw.entries()) : Object.entries(raw);
      for (const [k, v] of entries) {
        if (v === undefined) continue;
        const lower = String(k).toLowerCase();
        if (REDACTED_HEADERS.has(lower)) {
          out[lower] = '[REDACTED]';
        } else {
          const val = Array.isArray(v) ? v.join(', ') : String(v ?? '');
          out[lower] = val.length > MAX_HEADER_VALUE_CHARS ? val.slice(0, MAX_HEADER_VALUE_CHARS) + '…' : val;
        }
      }
      return out;
    }

    function isLikelyBinaryContentType(contentType) {
      if (!contentType) return false;
      const lower = String(contentType).toLowerCase();
      if (TEXT_CONTENT_RE.test(lower)) return false;
      return /(?:image\/|audio\/|video\/|font\/|application\/octet-stream|application\/pdf|application\/zip|application\/gzip|multipart\/form-data)/i.test(lower);
    }

    function hasBinaryBytes(buf) {
      const sampleLen = Math.min(buf.length, 512);
      let nulCount = 0;
      let ctrlCount = 0;
      for (let i = 0; i < sampleLen; i++) {
        const b = buf[i];
        if (b === 0) nulCount++;
        else if (b < 9 || (b > 13 && b < 32)) ctrlCount++;
      }
      return nulCount > 0 || (sampleLen >= 16 && ctrlCount / sampleLen > 0.15);
    }

    function decodeBufferToBody(buf, contentType, contentEncoding, totalBytes) {
      if (!buf || buf.length === 0) return null;
      if (isLikelyBinaryContentType(contentType)) {
        return `[binary ${contentType || 'payload'}: ${formatBytes(totalBytes || buf.length)}]`;
      }
      let decoded = buf;
      const enc = String(contentEncoding || '').toLowerCase().trim();
      const isGzipMagic = buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b;
      const tryDecompress = (kind) => {
        if (kind === 'gzip') return zlib.gunzipSync(buf);
        if (kind === 'br' && typeof zlib.brotliDecompressSync === 'function') return zlib.brotliDecompressSync(buf);
        if (kind === 'deflate') return zlib.inflateSync(buf);
        return null;
      };

      if (enc || isGzipMagic) {
        try {
          if (enc.includes('gzip') || isGzipMagic) {
            decoded = tryDecompress('gzip') || buf;
          } else if (enc.includes('br')) {
            decoded = tryDecompress('br') || buf;
          } else if (enc.includes('deflate')) {
            decoded = tryDecompress('deflate') || buf;
          }
        } catch {
          if (buf.length >= MAX_CAPTURE_BYTES) {
            return `[compressed ${enc || 'gzip'} body > ${formatBytes(MAX_CAPTURE_BYTES)}; total ${formatBytes(totalBytes || buf.length)}]`;
          }
          decoded = buf;
        }
      } else if (TEXT_CONTENT_RE.test(String(contentType || '')) && hasBinaryBytes(buf)) {
        // Some HTTP clients (e.g. axios) strip `res.headers['content-encoding']` before downstream listeners run.
        // Probe brotli/gzip/deflate transparently when a text/JSON response arrives compressed.
        for (const kind of ['br', 'gzip', 'deflate']) {
          try {
            const candidate = tryDecompress(kind);
            if (candidate && candidate.length > 0 && !hasBinaryBytes(candidate)) {
              decoded = candidate;
              break;
            }
          } catch {}
        }
      }

      if (hasBinaryBytes(decoded)) {
        return `[binary payload: ${formatBytes(totalBytes || decoded.length)}]`;
      }
      return truncate(decoded.toString('utf8'), MAX_BODY_CHARS);
    }

    function safeShortUrlLabel(rawUrl) {
      try {
        const u = new URL(rawUrl);
        const pq = (u.pathname || '/') + (u.search || '');
        return pq.length > 92 ? pq.slice(0, 89) + '…' : pq;
      } catch {
        const s = String(rawUrl || '');
        return s.length > 92 ? s.slice(0, 89) + '…' : s;
      }
    }

    function extractTargetSelector(step) {
      if (!step) return null;
      const method = String(step.name || step.helperMethod || '');
      const args = Array.isArray(step.args) ? step.args : [];
      if (!args.length) return null;

      if ((method === 'see' || method === 'dontSee') && args.length >= 2) {
        const second = normalizeLocator(args[1]);
        if (second) return second;
      }
      if (LOCATOR_METHODS.has(method)) {
        return normalizeLocator(args[0]);
      }
      return null;
    }

    function normalizeLocator(arg) {
      if (typeof arg === 'string') {
        const s = arg.trim();
        return s.length > 0 && s.length <= 240 ? s : null;
      }
      if (arg && typeof arg === 'object') {
        if (typeof arg.css === 'string') return arg.css;
        if (typeof arg.testId === 'string') return '~' + arg.testId;
        if (typeof arg.id === 'string') return arg.id.startsWith('#') ? arg.id : '#' + arg.id;
        if (typeof arg.xpath === 'string') return arg.xpath;
        if (typeof arg.role === 'string') {
          const rName = typeof arg.name === 'string' ? arg.name : (typeof arg.text === 'string' ? arg.text : '');
          return rName ? `role=${arg.role}[name="${rName}"]` : `role=${arg.role}`;
        }
        if (typeof arg.label === 'string') return `~${arg.label}`;
        if (typeof arg.placeholder === 'string') return arg.placeholder;
        if (typeof arg.text === 'string') return arg.text;
        if (typeof arg.android === 'string' || typeof arg.ios === 'string') {
          return normalizeLocator(arg.android || arg.ios);
        }
        if (typeof arg.name === 'string') return `[name="${arg.name}"]`;
        if (typeof arg.pw === 'string') return arg.pw;
        if (typeof arg.value === 'string') return arg.value;
      }
      return null;
    }

    function safeSerializeArg(arg, maxLen = 600) {
      if (arg === undefined) return 'undefined';
      if (typeof arg === 'string') return truncate(arg, maxLen);
      if (typeof arg === 'function') return arg.name ? `[Function ${arg.name}]` : '[Function]';
      try {
        return truncate(JSON.stringify(arg, null, 2), maxLen);
      } catch {
        return truncate(String(arg), maxLen);
      }
    }

    function formatStepText(step) {
      if (!step) return 'Step';
      if (typeof step.toString === 'function') {
        const s = String(step.toString()).trim();
        if (s && s !== '[object Object]') return s;
      }
      const name = step.name || step.helperMethod || 'step';
      const args = Array.isArray(step.args)
        ? step.args.map((a) => {
            try { return JSON.stringify(a); } catch { return String(a); }
          }).join(', ')
        : '';
      return args ? `I ${name} ${args}` : `I ${name}`;
    }

    function getActivePage(container) {
      if (!container || typeof container.helpers !== 'function') return null;
      let helpers;
      try { helpers = container.helpers(); } catch { return null; }
      if (!helpers || typeof helpers !== 'object') return null;

      const preferred = ['Playwright', 'Puppeteer', 'CDPBrowser', 'WebDriver'];
      for (const name of preferred) {
        const h = helpers[name];
        if (h && h.page) return { helperName: name, helper: h, page: h.page };
      }
      for (const [name, h] of Object.entries(helpers)) {
        if (h && h.page) return { helperName: name, helper: h, page: h.page };
      }
      return null;
    }

    function getActiveMobileTarget(container) {
      if (!container || typeof container.helpers !== 'function') return null;
      let helpers;
      try { helpers = container.helpers(); } catch { return null; }
      if (!helpers || typeof helpers !== 'object') return null;

      const preferred = ['Mobilewright', 'Appium', 'Detox'];
      for (const name of preferred) {
        const h = helpers[name];
        if (h && (h.screen || h.driver || h.device)) {
          return {
            helperName: name,
            helper: h,
            screen: h.screen || (h.device && h.device.screen) || null,
            driver: h.driver || (h.screen && h.screen.driver) || null,
            device: h.device || null
          };
        }
      }
      for (const [name, h] of Object.entries(helpers)) {
        if (h && !h.page && (h.screen || h.driver || h.device)) {
          return {
            helperName: name,
            helper: h,
            screen: h.screen || (h.device && h.device.screen) || null,
            driver: h.driver || (h.screen && h.screen.driver) || null,
            device: h.device || null
          };
        }
      }
      return null;
    }

    function getMobileVirtualURL(mobile) {
      if (!mobile || !mobile.helper) return null;
      const h = mobile.helper;
      const opts = (h && h.options && typeof h.options === 'object') ? h.options : {};
      const platform = h.platform || opts.platform || 'device';
      const app = opts.app || (mobile.driver && mobile.driver.foreground) || 'app';
      return `mobilewright://${platform}/${app}`;
    }

    function withBoundedTimeout(promise, ms) {
      return Promise.race([
        Promise.resolve(promise),
        new Promise((resolve) => setTimeout(() => resolve(null), ms))
      ]).catch(() => null);
    }

    function parseHttpRequestArgs(defaultProtocol, args) {
      let urlObj = null;
      let opts = {};
      if (typeof args[0] === 'string') {
        try { urlObj = new URL(args[0]); } catch {}
        if (args[1] && typeof args[1] === 'object' && typeof args[1] !== 'function') {
          opts = args[1];
        }
      } else if (args[0] instanceof URL) {
        urlObj = args[0];
        if (args[1] && typeof args[1] === 'object' && typeof args[1] !== 'function') {
          opts = args[1];
        }
      } else if (args[0] && typeof args[0] === 'object') {
        opts = args[0];
      }

      const protocol = (opts.protocol || (urlObj && urlObj.protocol) || defaultProtocol || 'http:');
      const method = String(opts.method || 'GET').toUpperCase();
      let fullUrl = '';
      if (urlObj && !opts.hostname && !opts.host && !opts.path) {
        fullUrl = urlObj.href;
      } else {
        const host = opts.hostname || opts.host || (urlObj && urlObj.hostname) || 'localhost';
        const port = opts.port || (urlObj && urlObj.port) || '';
        const hostHasPort = typeof host === 'string' && host.includes(':') && !host.startsWith('[');
        const portPart = port && !hostHasPort &&
          !((protocol === 'http:' && String(port) === '80') || (protocol === 'https:' && String(port) === '443'))
          ? `:${port}`
          : '';
        const reqPath = opts.path || (urlObj ? (urlObj.pathname + urlObj.search) : '/');
        const cleanPath = String(reqPath).startsWith('/') ? String(reqPath) : '/' + String(reqPath);
        fullUrl = `${protocol}//${host}${portPart}${cleanPath}`;
      }
      const headers = opts.headers || {};
      return { method, url: fullUrl, headers };
    }

    async function captureScreenshot(page) {
      if (!page || typeof page.screenshot !== 'function') return null;
      try {
        let buf;
        try {
          buf = await page.screenshot({ type: 'jpeg', quality: 68, timeout: 2500 });
        } catch {
          buf = await page.screenshot({ timeout: 2500 });
        }
        if (!buf) return null;
        const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf, 'base64');
        if (b.length === 0) return null;
        const isPNG = b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
        const isJPEG = b.length >= 3 && b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF;
        if (!isPNG && !isJPEG) return null;
        const mime = isPNG ? 'image/png' : 'image/jpeg';
        return `data:${mime};base64,${b.toString('base64')}`;
      } catch {
        return null;
      }
    }

    async function captureMobileScreenshot(mobile) {
      if (!mobile) return null;
      try {
        let buf = null;
        if (mobile.driver && typeof mobile.driver.screenshot === 'function') {
          buf = await withBoundedTimeout(mobile.driver.screenshot(), 2500);
        }
        if (!buf && mobile.screen && typeof mobile.screen.screenshot === 'function') {
          buf = await withBoundedTimeout(mobile.screen.screenshot({}), 2500);
        }
        if (!buf) return null;
        const b = Buffer.isBuffer(buf) ? buf : (typeof buf === 'string' ? Buffer.from(buf, 'base64') : null);
        if (!b || b.length < 4) return null;
        const isPNG = b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
        const isJPEG = b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF;
        if (!isPNG && !isJPEG) return null;
        const mime = isPNG ? 'image/png' : 'image/jpeg';
        return `data:${mime};base64,${b.toString('base64')}`;
      } catch {
        return null;
      }
    }

    function matchMobileNodesInTree(roots, targetSelector) {
      const flat = [];
      function walk(list) {
        if (!Array.isArray(list)) return;
        for (const n of list) {
          if (!n || typeof n !== 'object') continue;
          flat.push(n);
          if (Array.isArray(n.children)) walk(n.children);
        }
      }
      walk(Array.isArray(roots) ? roots : (roots ? [roots] : []));
      if (!targetSelector || typeof targetSelector !== 'string') return { matches: [], flat };

      const sel = targetSelector.trim();
      if (!sel) return { matches: [], flat };
      const visibleNodes = flat.filter((n) => n.isVisible !== false);
      const pool = visibleNodes.length > 0 ? visibleNodes : flat;
      const matches = [];

      const roleMatch = sel.match(/^role=([A-Za-z0-9_-]+)(?:\[name="([^"]+)"\])?$/i);
      if (roleMatch) {
        const wantRole = roleMatch[1].toLowerCase();
        const wantName = (roleMatch[2] || '').toLowerCase();
        for (const n of pool) {
          const r = String(n.role || n.type || '').toLowerCase();
          const txt = String(n.label || n.text || n.value || n.testId || n.identifier || '').toLowerCase();
          if (r.includes(wantRole) && (!wantName || txt === wantName || txt.includes(wantName))) {
            matches.push(n);
          }
        }
      } else if (sel.startsWith('~')) {
        const needle = sel.slice(1).toLowerCase();
        for (const n of pool) {
          const id = String(n.testId || n.identifier || '').toLowerCase();
          const lbl = String(n.label || '').toLowerCase();
          if (id === needle || lbl === needle || id.endsWith(':id/' + needle)) {
            matches.push(n);
          }
        }
      } else if (sel.startsWith('#')) {
        const needle = sel.slice(1).toLowerCase();
        for (const n of pool) {
          const id = String(n.testId || n.identifier || '').toLowerCase();
          if (id === needle || id.endsWith(':id/' + needle)) {
            matches.push(n);
          }
        }
      } else {
        const needle = sel.toLowerCase();
        for (const n of pool) {
          const fields = [n.testId, n.identifier, n.label, n.text, n.placeholder, n.value]
            .filter(Boolean)
            .map((v) => String(v).trim().toLowerCase());
          if (fields.some((f) => f === needle)) {
            matches.push(n);
          }
        }
        if (matches.length === 0) {
          for (const n of pool) {
            const fields = [n.label, n.text, n.placeholder, n.testId, n.identifier]
              .filter(Boolean)
              .map((v) => String(v).trim().toLowerCase());
            if (fields.some((f) => f.includes(needle))) {
              matches.push(n);
            }
          }
        }
      }
      return { matches, flat };
    }

    function formatMobileNodeTag(n) {
      if (!n || typeof n !== 'object') return '<Node />';
      const tag = String(n.type || n.role || 'View').replace(/[^A-Za-z0-9_.-]/g, '') || 'View';
      const attrs = [];
      if (n.role) attrs.push(`role="${String(n.role)}"`);
      if (n.testId) attrs.push(`testId="${String(n.testId)}"`);
      if (n.identifier) attrs.push(`id="${String(n.identifier)}"`);
      if (n.label) attrs.push(`label="${String(n.label)}"`);
      if (n.text) attrs.push(`text="${String(n.text)}"`);
      if (n.value !== undefined && n.value !== null && n.value !== '') attrs.push(`value="${String(n.value)}"`);
      if (n.placeholder) attrs.push(`placeholder="${String(n.placeholder)}"`);
      if (n.bounds && typeof n.bounds === 'object') {
        attrs.push(`bounds="[${n.bounds.x ?? 0},${n.bounds.y ?? 0} ${n.bounds.width ?? 0}x${n.bounds.height ?? 0}]"`);
      }
      return `<${tag}${attrs.length ? ' ' + attrs.join(' ') : ''} />`;
    }

    async function captureMobileViewTreeSnapshot(mobile, targetSelector) {
      if (!mobile) return null;
      try {
        let tree = null;
        if (mobile.driver && typeof mobile.driver.getViewHierarchy === 'function') {
          tree = await withBoundedTimeout(mobile.driver.getViewHierarchy(), 2500);
        }
        if (!tree && mobile.screen && typeof mobile.screen.viewTree === 'function') {
          tree = await withBoundedTimeout(mobile.screen.viewTree(), 2500);
        }
        if (!tree) return null;

        let screenSize = null;
        if (mobile.driver && typeof mobile.driver.getScreenSize === 'function') {
          screenSize = await withBoundedTimeout(mobile.driver.getScreenSize(), 1500);
        }
        const roots = Array.isArray(tree) ? tree : [tree];
        const { matches } = matchMobileNodesInTree(roots, targetSelector);

        let viewportWidth = (screenSize && typeof screenSize.width === 'number') ? screenSize.width : null;
        let viewportHeight = (screenSize && typeof screenSize.height === 'number') ? screenSize.height : null;
        if ((!viewportWidth || !viewportHeight) && roots[0] && roots[0].bounds) {
          viewportWidth = viewportWidth || roots[0].bounds.width || null;
          viewportHeight = viewportHeight || roots[0].bounds.height || null;
        }

        let targetOuterHTML = null;
        let targetBoundingBox = null;
        if (matches.length > 0) {
          const first = matches[0];
          targetOuterHTML = formatMobileNodeTag(first);
          const b = first.bounds;
          if (b && typeof b === 'object' && (b.width > 0 || b.height > 0)) {
            targetBoundingBox = {
              x: Math.round((Number(b.x) || 0) * 10) / 10,
              y: Math.round((Number(b.y) || 0) * 10) / 10,
              width: Math.round((Number(b.width) || 0) * 10) / 10,
              height: Math.round((Number(b.height) || 0) * 10) / 10,
              viewportWidth,
              viewportHeight
            };
          }
        }

        const jsonTree = JSON.stringify(tree, null, 2);
        const h = mobile.helper || {};
        const opts = (h.options && typeof h.options === 'object') ? h.options : {};
        const platform = h.platform || opts.platform || 'mobile';
        const app = opts.app || '';
        return {
          html: truncate(jsonTree, MAX_DOM_CHARS),
          url: getMobileVirtualURL(mobile),
          title: app ? `${platform} · ${app}` : platform,
          targetSelector: targetSelector || null,
          targetOuterHTML: truncate(targetOuterHTML, MAX_TARGET_HTML_CHARS),
          targetBoundingBox,
          matchedCount: matches.length
        };
      } catch {
        return null;
      }
    }

    async function captureDOMSnapshot(page, targetSelector) {
      if (!page) return null;
      try {
        if (typeof page.evaluate === 'function') {
          const result = await page.evaluate((sel) => {
            const matches = [];
            try {
              document.querySelectorAll('[data-ceptra-target]').forEach((el) => el.removeAttribute('data-ceptra-target'));
              if (sel && typeof sel === 'string') {
                if (sel.startsWith('/') || sel.startsWith('//') || sel.startsWith('(')) {
                  const xp = document.evaluate(sel, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                  for (let i = 0; i < Math.min(xp.snapshotLength, 8); i++) {
                    const node = xp.snapshotItem(i);
                    if (node && node.nodeType === 1) matches.push(node);
                  }
                } else {
                  let cssMatches = [];
                  try { cssMatches = Array.from(document.querySelectorAll(sel)); } catch {}
                  if (cssMatches.length > 0) {
                    for (const el of cssMatches.slice(0, 8)) matches.push(el);
                  } else {
                    const needle = sel.trim().toLowerCase();
                    if (needle) {
                      const candidates = document.querySelectorAll('button, a, input, textarea, select, label, [role="button"], [role="link"], h1, h2, h3, p, span');
                      for (const el of candidates) {
                        const txt = (el.innerText || el.textContent || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.value || '').trim().toLowerCase();
                        if (txt === needle || (txt.includes(needle) && txt.length < needle.length + 40)) {
                          matches.push(el);
                          if (matches.length >= 5) break;
                        }
                      }
                    }
                  }
                }
              }
              for (const el of matches) {
                el.setAttribute('data-ceptra-target', 'true');
              }
              let targetOuterHTML = null;
              let targetBoundingBox = null;
              if (matches.length > 0) {
                const first = matches[0];
                targetOuterHTML = first.outerHTML || null;
                const rect = first.getBoundingClientRect();
                if (rect && (rect.width > 0 || rect.height > 0)) {
                  targetBoundingBox = {
                    x: Math.round(rect.x * 10) / 10,
                    y: Math.round(rect.y * 10) / 10,
                    width: Math.round(rect.width * 10) / 10,
                    height: Math.round(rect.height * 10) / 10,
                    viewportWidth: window.innerWidth || null,
                    viewportHeight: window.innerHeight || null
                  };
                }
              }
              const doctype = document.doctype ? `<!doctype ${document.doctype.name}>\n` : '<!doctype html>\n';
              const html = doctype + (document.documentElement ? document.documentElement.outerHTML : '');
              for (const el of matches) {
                el.removeAttribute('data-ceptra-target');
              }
              return {
                html,
                url: window.location ? window.location.href : null,
                title: document.title || null,
                targetOuterHTML,
                targetBoundingBox,
                matchedCount: matches.length
              };
            } catch {
              return {
                html: document.documentElement ? document.documentElement.outerHTML : '',
                url: window.location ? window.location.href : null,
                title: document.title || null,
                targetOuterHTML: null,
                targetBoundingBox: null,
                matchedCount: 0
              };
            }
          }, targetSelector || null);

          if (result && typeof result.html === 'string') {
            return {
              html: truncate(result.html, MAX_DOM_CHARS),
              url: result.url || (typeof page.url === 'function' ? page.url() : null),
              title: result.title || null,
              targetSelector: targetSelector || null,
              targetOuterHTML: truncate(result.targetOuterHTML, MAX_TARGET_HTML_CHARS),
              targetBoundingBox: result.targetBoundingBox || null,
              matchedCount: typeof result.matchedCount === 'number' ? result.matchedCount : 0
            };
          }
        }
        if (typeof page.content === 'function') {
          const rawHTML = await page.content();
          if (typeof rawHTML === 'string') {
            return {
              html: truncate(rawHTML, MAX_DOM_CHARS),
              url: typeof page.url === 'function' ? page.url() : null,
              title: typeof page.title === 'function' ? await page.title().catch(() => null) : null,
              targetSelector: targetSelector || null,
              targetOuterHTML: null,
              targetBoundingBox: null,
              matchedCount: 0
            };
          }
        }
      } catch {}
      return null;
    }

    module.exports = function ceptraTimeTravelPlugin() {
      const outputDir = process.env.CEPTRA_TIME_TRAVEL_DIR;
      if (!outputDir) return;

      const codeceptjs = resolveCodeceptJS();
      if (!codeceptjs || !codeceptjs.event || !codeceptjs.event.dispatcher) return;

      const { event, container } = codeceptjs;
      const dispatcher = event.dispatcher;
      const workerFile = path.join(outputDir, `worker-${process.pid}-${crypto.randomBytes(4).toString('hex')}.json`);

      const scenarios = [];
      let currentSuiteTitle = 'Suite';
      let currentScenario = null;
      let currentStep = null;
      let lastStepRecord = null;
      let lastApiRequestInScenario = null;
      let suiteSetupScenario = null;
      const attachedPages = new WeakSet();
      const pendingTasks = new Set();

      function track(promise) {
        if (!promise || typeof promise.then !== 'function') return;
        pendingTasks.add(promise);
        promise.finally(() => pendingTasks.delete(promise));
      }

      function createEmptyDiagnostics(pageURL) {
        return {
          pageURL: pageURL || null,
          beforeScreenshotDataURI: null,
          afterScreenshotDataURI: null,
          domSnapshot: null,
          networkRequests: [],
          consoleEntries: [],
          assertion: null
        };
      }

      function registerApiExchange(entry) {
        // Attach to active I.* step if one is running; otherwise synthesize a clean API step
        if (currentStep) {
          currentStep.diagnostics.networkRequests.push(entry);
          if (!currentStep.diagnostics.pageURL) {
            currentStep.diagnostics.pageURL = entry.url;
          }
          lastApiRequestInScenario = entry;
          return null;
        }

        let targetScenario = currentScenario;
        if (!targetScenario) {
          // Capture BeforeSuite / setup HTTP calls (e.g., OAuth token fetch) in a dedicated setup bucket
          if (!suiteSetupScenario) {
            suiteSetupScenario = {
              featureTitle: currentSuiteTitle || 'Suite',
              scenarioTitle: 'Suite Setup (BeforeSuite)',
              filePath: null,
              status: 'passed',
              durationMs: 0,
              startedAt: entry.startedAt,
              _startMs: entry._startMs || Date.now(),
              finishedAt: null,
              tags: ['@setup'],
              errorMessage: null,
              errorStack: null,
              steps: []
            };
            scenarios.push(suiteSetupScenario);
          }
          targetScenario = suiteSetupScenario;
        }

        const syntheticStep = {
          text: `HTTP ${entry.method} ${safeShortUrlLabel(entry.url)}`,
          depth: 0,
          status: 'passed',
          durationMs: null,
          startedAt: entry.startedAt,
          _startMs: entry._startMs || Date.now(),
          finishedAt: null,
          targetSelector: null,
          errorMessage: null,
          diagnostics: createEmptyDiagnostics(entry.url)
        };
        syntheticStep.diagnostics.networkRequests.push(entry);
        targetScenario.steps.push(syntheticStep);
        if (currentScenario) {
          lastApiRequestInScenario = entry;
        }
        return syntheticStep;
      }

      function finalizeSyntheticStep(syntheticStep, entry) {
        if (!syntheticStep) return;
        const now = Date.now();
        syntheticStep.finishedAt = new Date(now).toISOString();
        syntheticStep.durationMs = typeof entry.durationMs === 'number'
          ? entry.durationMs
          : Math.max(0, now - (syntheticStep._startMs || now));
        if (entry.errorText) {
          syntheticStep.status = 'failed';
          syntheticStep.errorMessage = entry.errorText;
        }
        if (suiteSetupScenario && suiteSetupScenario.steps.includes(syntheticStep)) {
          suiteSetupScenario.finishedAt = syntheticStep.finishedAt;
          suiteSetupScenario.durationMs = Math.max(0, now - (suiteSetupScenario._startMs || now));
        }
      }

      // Universal Node/Bun HTTP & HTTPS interceptor (captures axios, flex-rest, CodeceptJS REST/GraphQL, got, etc.)
      function installNodeHttpInterceptor() {
        const activeState = globalThis.__ceptraHttpRecorderState || { onExchange: null, onComplete: null };
        activeState.onExchange = registerApiExchange;
        activeState.onComplete = finalizeSyntheticStep;
        globalThis.__ceptraHttpRecorderState = activeState;

        if (globalThis.__ceptraHttpPatched) return;
        globalThis.__ceptraHttpPatched = true;

        const trackedClientRequests = new WeakSet();

        function wrapModule(mod, defaultProtocol, sourceLabel) {
          const origRequest = mod.request;
          const origGet = mod.get;
          if (typeof origRequest !== 'function') return;

          function instrumentedRequest(...args) {
            const req = origRequest.apply(this, args);
            if (!req || trackedClientRequests.has(req)) return req;
            trackedClientRequests.add(req);

            const rec = globalThis.__ceptraHttpRecorderState;
            if (!rec || typeof rec.onExchange !== 'function') return req;

            const parsed = parseHttpRequestArgs(defaultProtocol, args);
            if (!parsed.url || INTERNAL_CONTROL_URL_RE.test(parsed.url)) return req;

            const startMs = Date.now();
            const entry = {
              id: genId(),
              method: parsed.method,
              url: parsed.url,
              resourceType: 'api',
              source: sourceLabel,
              status: null,
              statusText: null,
              startedAt: new Date(startMs).toISOString(),
              _startMs: startMs,
              durationMs: null,
              requestSizeBytes: 0,
              responseSizeBytes: 0,
              timings: null,
              requestHeaders: redactHeaders(parsed.headers),
              responseHeaders: {},
              requestBody: null,
              responseBody: null,
              errorText: null
            };

            const syntheticStep = rec.onExchange(entry);

            const reqChunks = [];
            let reqCapturedBytes = 0;
            let reqTotalBytes = 0;

            function captureWriteChunk(chunk, encoding) {
              if (chunk == null) return;
              try {
                const buf = Buffer.isBuffer(chunk)
                  ? chunk
                  : Buffer.from(String(chunk), typeof encoding === 'string' ? encoding : 'utf8');
                reqTotalBytes += buf.length;
                if (reqCapturedBytes < MAX_CAPTURE_BYTES) {
                  const remain = MAX_CAPTURE_BYTES - reqCapturedBytes;
                  reqChunks.push(buf.length <= remain ? buf : buf.subarray(0, remain));
                  reqCapturedBytes += Math.min(buf.length, remain);
                }
              } catch {}
            }

            const origWrite = req.write;
            if (typeof origWrite === 'function') {
              req.write = function (chunk, encoding, cb) {
                captureWriteChunk(chunk, encoding);
                return origWrite.apply(this, arguments);
              };
            }

            const origEnd = req.end;
            if (typeof origEnd === 'function') {
              req.end = function (chunk, encoding, cb) {
                if (typeof chunk !== 'function') {
                  captureWriteChunk(chunk, encoding);
                }
                try {
                  if (typeof req.getHeaders === 'function') {
                    const liveHeaders = req.getHeaders();
                    if (liveHeaders && Object.keys(liveHeaders).length > 0) {
                      entry.requestHeaders = redactHeaders(liveHeaders);
                    }
                  }
                  if (reqTotalBytes > 0) {
                    entry.requestSizeBytes = reqTotalBytes;
                    const ct = entry.requestHeaders['content-type'] || '';
                    entry.requestBody = decodeBufferToBody(Buffer.concat(reqChunks), ct, '', reqTotalBytes);
                  }
                } catch {}
                return origEnd.apply(this, arguments);
              };
            }

            let lookupMs = null;
            let connectMs = null;
            let tlsMs = null;
            let ttfbMs = null;

            req.on('socket', (socket) => {
              if (!socket || typeof socket.once !== 'function') return;
              socket.once('lookup', () => {
                if (lookupMs === null) lookupMs = Math.max(0, Date.now() - startMs);
              });
              socket.once('connect', () => {
                if (connectMs === null) connectMs = Math.max(0, Date.now() - startMs);
              });
              socket.once('secureConnect', () => {
                if (tlsMs === null) tlsMs = Math.max(0, Date.now() - startMs);
              });
            });

            // Prepend our response listener so we capture `content-encoding` BEFORE libraries like axios delete it in-place.
            const attachResponse = typeof req.prependListener === 'function'
              ? req.prependListener.bind(req)
              : req.on.bind(req);

            attachResponse('response', (res) => {
              const firstByteAt = Date.now();
              ttfbMs = Math.max(0, firstByteAt - startMs);
              entry.status = typeof res.statusCode === 'number' ? res.statusCode : null;
              entry.statusText = res.statusMessage ? String(res.statusMessage) : null;
              entry.responseHeaders = redactHeaders(res.headers || {});
              const capturedContentEncoding = String(
                (res.headers && (res.headers['content-encoding'] || res.headers['Content-Encoding'])) || ''
              );

              const resChunks = [];
              let resCapturedBytes = 0;
              let resTotalBytes = 0;

              res.on('data', (chunk) => {
                try {
                  const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
                  resTotalBytes += buf.length;
                  if (resCapturedBytes < MAX_CAPTURE_BYTES) {
                    const remain = MAX_CAPTURE_BYTES - resCapturedBytes;
                    resChunks.push(buf.length <= remain ? buf : buf.subarray(0, remain));
                    resCapturedBytes += Math.min(buf.length, remain);
                  }
                } catch {}
              });

              res.on('end', () => {
                const endAt = Date.now();
                const totalMs = Math.max(0, endAt - startMs);
                const dnsDur = lookupMs;
                const tcpDur = connectMs != null ? Math.max(0, connectMs - (lookupMs || 0)) : null;
                const tlsDur = tlsMs != null ? Math.max(0, tlsMs - (connectMs || lookupMs || 0)) : null;
                const waitDur = Math.max(0, ttfbMs - (tlsMs ?? connectMs ?? lookupMs ?? 0));
                const dlDur = Math.max(0, totalMs - ttfbMs);

                entry.durationMs = totalMs;
                entry.responseSizeBytes = resTotalBytes;
                entry.timings = {
                  dnsMs: dnsDur,
                  connectMs: tcpDur,
                  tlsMs: tlsDur,
                  ttfbMs: waitDur,
                  downloadMs: dlDur,
                  totalMs
                };
                if (resTotalBytes > 0) {
                  const ct = entry.responseHeaders['content-type'] || '';
                  const ce = capturedContentEncoding || entry.responseHeaders['content-encoding'] || '';
                  entry.responseBody = decodeBufferToBody(Buffer.concat(resChunks), ct, ce, resTotalBytes);
                }
                if (rec && typeof rec.onComplete === 'function') {
                  rec.onComplete(syntheticStep, entry);
                }
              });
            });

            req.on('error', (err) => {
              entry.durationMs = Math.max(0, Date.now() - startMs);
              entry.errorText = err && err.message ? String(err.message) : String(err || 'Request failed');
              entry.timings = { dnsMs: null, connectMs: null, tlsMs: null, ttfbMs: null, downloadMs: null, totalMs: entry.durationMs };
              if (rec && typeof rec.onComplete === 'function') {
                rec.onComplete(syntheticStep, entry);
              }
            });

            req.on('timeout', () => {
              if (!entry.errorText && entry.status == null) {
                entry.durationMs = Math.max(0, Date.now() - startMs);
                entry.errorText = 'Request timed out';
              }
            });

            return req;
          }

          mod.request = instrumentedRequest;
          if (typeof origGet === 'function') {
            mod.get = function (...args) {
              const req = mod.request.apply(this, args);
              if (req && typeof req.end === 'function') req.end();
              return req;
            };
          }
        }

        wrapModule(http, 'http:', 'http');
        wrapModule(https, 'https:', 'https');
        try {
          const nodeModule = require('node:module');
          if (nodeModule && typeof nodeModule.syncBuiltinESMExports === 'function') {
            nodeModule.syncBuiltinESMExports();
          }
        } catch {}
      }

      // Global `fetch()` interceptor (captures Node undici fetch & Bun native fetch)
      function installGlobalFetchInterceptor() {
        const activeState = globalThis.__ceptraHttpRecorderState || { onExchange: null, onComplete: null };
        activeState.onExchange = registerApiExchange;
        activeState.onComplete = finalizeSyntheticStep;
        globalThis.__ceptraHttpRecorderState = activeState;

        if (globalThis.__ceptraFetchPatched || typeof globalThis.fetch !== 'function') return;
        globalThis.__ceptraFetchPatched = true;

        const origFetch = globalThis.fetch.bind(globalThis);
        globalThis.fetch = async function ceptraInstrumentedFetch(input, init) {
          const rec = globalThis.__ceptraHttpRecorderState;
          let url = '';
          let method = 'GET';
          let rawHeaders = {};
          let reqBodyStr = null;
          let reqSize = 0;

          try {
            if (typeof input === 'string') {
              url = input;
            } else if (input instanceof URL) {
              url = input.href;
            } else if (input && typeof input === 'object') {
              url = String(input.url || '');
              if (input.method) method = String(input.method).toUpperCase();
              if (input.headers) rawHeaders = input.headers;
            }
            if (init && typeof init === 'object') {
              if (init.method) method = String(init.method).toUpperCase();
              if (init.headers) rawHeaders = init.headers;
              if (init.body != null) {
                if (typeof init.body === 'string') {
                  reqSize = Buffer.byteLength(init.body, 'utf8');
                  reqBodyStr = truncate(init.body, MAX_BODY_CHARS);
                } else if (init.body instanceof URLSearchParams) {
                  const s = init.body.toString();
                  reqSize = Buffer.byteLength(s, 'utf8');
                  reqBodyStr = truncate(s, MAX_BODY_CHARS);
                } else if (Buffer.isBuffer(init.body) || init.body instanceof Uint8Array) {
                  const buf = Buffer.from(init.body);
                  reqSize = buf.length;
                  reqBodyStr = decodeBufferToBody(buf.subarray(0, MAX_CAPTURE_BYTES), '', '', buf.length);
                }
              }
            }
          } catch {}

          if (!rec || typeof rec.onExchange !== 'function' || !url || INTERNAL_CONTROL_URL_RE.test(url)) {
            return origFetch(input, init);
          }

          const startMs = Date.now();
          const entry = {
            id: genId(),
            method,
            url,
            resourceType: 'fetch',
            source: 'fetch',
            status: null,
            statusText: null,
            startedAt: new Date(startMs).toISOString(),
            _startMs: startMs,
            durationMs: null,
            requestSizeBytes: reqSize,
            responseSizeBytes: 0,
            timings: null,
            requestHeaders: redactHeaders(rawHeaders),
            responseHeaders: {},
            requestBody: reqBodyStr,
            responseBody: null,
            errorText: null
          };

          const syntheticStep = rec.onExchange(entry);

          try {
            const response = await origFetch(input, init);
            const ttfbMs = Math.max(0, Date.now() - startMs);
            entry.status = typeof response.status === 'number' ? response.status : null;
            entry.statusText = response.statusText ? String(response.statusText) : null;
            entry.responseHeaders = redactHeaders(response.headers);

            const ct = entry.responseHeaders['content-type'] || '';
            if (typeof response.clone === 'function' && (!ct || !isLikelyBinaryContentType(ct))) {
              const cloned = response.clone();
              track(
                cloned.text().then((txt) => {
                  const endAt = Date.now();
                  const totalMs = Math.max(0, endAt - startMs);
                  entry.durationMs = totalMs;
                  if (typeof txt === 'string' && txt.length > 0) {
                    entry.responseSizeBytes = Buffer.byteLength(txt, 'utf8');
                    entry.responseBody = truncate(txt, MAX_BODY_CHARS);
                  }
                  entry.timings = {
                    dnsMs: null,
                    connectMs: null,
                    tlsMs: null,
                    ttfbMs,
                    downloadMs: Math.max(0, totalMs - ttfbMs),
                    totalMs
                  };
                  if (rec && typeof rec.onComplete === 'function') {
                    rec.onComplete(syntheticStep, entry);
                  }
                }).catch(() => {
                  entry.durationMs = ttfbMs;
                  entry.timings = { dnsMs: null, connectMs: null, tlsMs: null, ttfbMs, downloadMs: 0, totalMs: ttfbMs };
                  if (rec && typeof rec.onComplete === 'function') {
                    rec.onComplete(syntheticStep, entry);
                  }
                })
              );
            } else {
              entry.durationMs = ttfbMs;
              entry.timings = { dnsMs: null, connectMs: null, tlsMs: null, ttfbMs, downloadMs: 0, totalMs: ttfbMs };
              if (rec && typeof rec.onComplete === 'function') {
                rec.onComplete(syntheticStep, entry);
              }
            }
            return response;
          } catch (err) {
            entry.durationMs = Math.max(0, Date.now() - startMs);
            entry.errorText = err && err.message ? String(err.message) : String(err || 'Fetch failed');
            entry.timings = { dnsMs: null, connectMs: null, tlsMs: null, ttfbMs: null, downloadMs: null, totalMs: entry.durationMs };
            if (rec && typeof rec.onComplete === 'function') {
              rec.onComplete(syntheticStep, entry);
            }
            throw err;
          }
        };
      }

      installNodeHttpInterceptor();
      installGlobalFetchInterceptor();

      function attachPageListeners(page) {
        if (!page || typeof page.on !== 'function' || attachedPages.has(page)) return;
        attachedPages.add(page);
        const reqMap = new WeakMap();

        page.on('request', (req) => {
          if (!currentStep) return;
          try {
            const rawHeaders = typeof req.headers === 'function' ? req.headers() : (req.headers || {});
            const postData = typeof req.postData === 'function' ? req.postData() : null;
            const entry = {
              id: genId(),
              method: typeof req.method === 'function' ? req.method() : 'GET',
              url: typeof req.url === 'function' ? req.url() : String(req.url || ''),
              resourceType: typeof req.resourceType === 'function' ? req.resourceType() : null,
              source: 'browser',
              status: null,
              statusText: null,
              startedAt: new Date().toISOString(),
              _startMs: Date.now(),
              durationMs: null,
              requestSizeBytes: typeof postData === 'string' ? Buffer.byteLength(postData, 'utf8') : 0,
              responseSizeBytes: 0,
              timings: null,
              requestHeaders: redactHeaders(rawHeaders),
              responseHeaders: {},
              requestBody: truncate(postData, MAX_BODY_CHARS),
              responseBody: null,
              errorText: null
            };
            reqMap.set(req, entry);
            currentStep.diagnostics.networkRequests.push(entry);
          } catch {}
        });

        page.on('response', (res) => {
          try {
            const req = typeof res.request === 'function' ? res.request() : null;
            let entry = req ? reqMap.get(req) : null;
            if (!entry && currentStep) {
              entry = {
                id: genId(),
                method: req && typeof req.method === 'function' ? req.method() : 'GET',
                url: typeof res.url === 'function' ? res.url() : '',
                resourceType: req && typeof req.resourceType === 'function' ? req.resourceType() : null,
                source: 'browser',
                status: null,
                statusText: null,
                startedAt: new Date().toISOString(),
                _startMs: Date.now(),
                durationMs: null,
                requestSizeBytes: 0,
                responseSizeBytes: 0,
                timings: null,
                requestHeaders: {},
                responseHeaders: {},
                requestBody: null,
                responseBody: null,
                errorText: null
              };
              currentStep.diagnostics.networkRequests.push(entry);
            }
            if (!entry) return;
            entry.status = typeof res.status === 'function' ? res.status() : null;
            entry.statusText = typeof res.statusText === 'function' ? res.statusText() : null;
            entry.durationMs = typeof entry._startMs === 'number' ? Math.max(0, Date.now() - entry._startMs) : null;
            const rawResHeaders = typeof res.headers === 'function' ? res.headers() : (res.headers || {});
            entry.responseHeaders = redactHeaders(rawResHeaders);

            const ct = entry.responseHeaders['content-type'] || '';
            if (typeof res.text === 'function' && (!ct || TEXT_CONTENT_RE.test(ct))) {
              track(
                Promise.resolve(res.text())
                  .then((txt) => {
                    if (typeof txt === 'string' && txt.length > 0) {
                      entry.responseSizeBytes = Buffer.byteLength(txt, 'utf8');
                      entry.responseBody = truncate(txt, MAX_BODY_CHARS);
                    }
                  })
                  .catch(() => {})
              );
            }
          } catch {}
        });

        page.on('requestfailed', (req) => {
          try {
            const entry = reqMap.get(req);
            if (!entry) return;
            const failure = typeof req.failure === 'function' ? req.failure() : null;
            entry.errorText = (failure && failure.errorText) ? String(failure.errorText) : 'Request failed';
            entry.durationMs = typeof entry._startMs === 'number' ? Math.max(0, Date.now() - entry._startMs) : null;
          } catch {}
        });

        page.on('console', (msg) => {
          if (!currentStep) return;
          try {
            const loc = typeof msg.location === 'function' ? msg.location() : null;
            currentStep.diagnostics.consoleEntries.push({
              id: genId(),
              level: typeof msg.type === 'function' ? msg.type() : 'log',
              message: truncate(typeof msg.text === 'function' ? msg.text() : String(msg), MAX_CONSOLE_CHARS) || '',
              timestamp: new Date().toISOString(),
              sourceURL: loc && loc.url ? String(loc.url) : null,
              lineNumber: loc && typeof loc.lineNumber === 'number' ? loc.lineNumber : null
            });
          } catch {}
        });

        page.on('pageerror', (err) => {
          if (!currentStep) return;
          try {
            currentStep.diagnostics.consoleEntries.push({
              id: genId(),
              level: 'pageerror',
              message: truncate((err && (err.stack || err.message)) ? String(err.stack || err.message) : String(err), MAX_CONSOLE_CHARS) || 'Uncaught page error',
              timestamp: new Date().toISOString(),
              sourceURL: null,
              lineNumber: null
            });
          } catch {}
        });
      }

      function serializeScenarios() {
        return scenarios.map((sc) => ({
          featureTitle: sc.featureTitle,
          scenarioTitle: sc.scenarioTitle,
          filePath: sc.filePath,
          status: sc.status,
          durationMs: sc.durationMs,
          startedAt: sc.startedAt,
          finishedAt: sc.finishedAt,
          tags: sc.tags,
          errorMessage: sc.errorMessage,
          errorStack: sc.errorStack,
          steps: sc.steps.map((st) => ({
            text: st.text,
            depth: st.depth,
            status: st.status,
            durationMs: st.durationMs,
            startedAt: st.startedAt,
            finishedAt: st.finishedAt,
            targetSelector: st.targetSelector,
            errorMessage: st.errorMessage,
            diagnostics: {
              pageURL: st.diagnostics.pageURL,
              beforeScreenshotDataURI: st.diagnostics.beforeScreenshotDataURI,
              afterScreenshotDataURI: st.diagnostics.afterScreenshotDataURI,
              domSnapshot: st.diagnostics.domSnapshot,
              assertion: st.diagnostics.assertion || null,
              networkRequests: st.diagnostics.networkRequests.map((n) => ({
                id: n.id,
                method: n.method,
                url: n.url,
                resourceType: n.resourceType,
                source: n.source || null,
                status: n.status,
                statusText: n.statusText,
                startedAt: n.startedAt,
                durationMs: n.durationMs,
                requestSizeBytes: typeof n.requestSizeBytes === 'number' ? n.requestSizeBytes : null,
                responseSizeBytes: typeof n.responseSizeBytes === 'number' ? n.responseSizeBytes : null,
                timings: n.timings || null,
                requestHeaders: n.requestHeaders,
                responseHeaders: n.responseHeaders,
                requestBody: n.requestBody,
                responseBody: n.responseBody,
                errorText: n.errorText
              })),
              consoleEntries: st.diagnostics.consoleEntries
            }
          }))
        }));
      }

      function flushSync() {
        if (scenarios.length === 0) return;
        try {
          fs.mkdirSync(outputDir, { recursive: true });
          const payload = JSON.stringify({
            version: 1,
            workerPid: process.pid,
            scenarios: serializeScenarios()
          });
          const tmpFile = workerFile + '.tmp';
          fs.writeFileSync(tmpFile, payload, 'utf8');
          fs.renameSync(tmpFile, workerFile);
        } catch {}
      }

      if (event.suite && event.suite.before) {
        dispatcher.on(event.suite.before, (suite) => {
          currentSuiteTitle = (suite && suite.title) ? String(suite.title) : 'Suite';
          suiteSetupScenario = null;
        });
      }

      dispatcher.on(event.test.before, (test) => {
        const active = getActivePage(container);
        if (active && active.page) attachPageListeners(active.page);

        const featureTitle = (test && test.parent && test.parent.title) ? String(test.parent.title) : currentSuiteTitle;
        const scenarioTitle = (test && test.title) ? String(test.title) : 'Scenario';
        const tags = Array.isArray(test && test.tags) ? test.tags.map(String) : [];

        if (suiteSetupScenario && suiteSetupScenario.featureTitle === 'Suite' && featureTitle) {
          suiteSetupScenario.featureTitle = featureTitle;
        }
        suiteSetupScenario = null;

        currentScenario = {
          featureTitle,
          scenarioTitle,
          filePath: (test && test.file) ? String(test.file) : null,
          status: 'passed',
          durationMs: 0,
          startedAt: new Date().toISOString(),
          _startMs: Date.now(),
          finishedAt: null,
          tags,
          errorMessage: null,
          errorStack: null,
          steps: []
        };
        currentStep = null;
        lastStepRecord = null;
        lastApiRequestInScenario = null;
        scenarios.push(currentScenario);
      });

      function beginStepExecution(step) {
        if (!currentScenario) return;
        // Skip MetaStep container wrappers so child helper steps hold the real execution & HTTP trace
        if (step && step.constructor && step.constructor.name === 'MetaStep') return;

        const active = getActivePage(container);
        if (active && active.page) attachPageListeners(active.page);
        const mobile = (!active || !active.page) ? getActiveMobileTarget(container) : null;

        const method = String((step && (step.name || step.helperMethod)) || '');
        const args = Array.isArray(step && step.args) ? step.args : [];
        const targetSelector = extractTargetSelector(step);
        const depth = (step && step.metaStep) ? 1 : 0;
        const pageURL = (active && active.page && typeof active.page.url === 'function')
          ? active.page.url()
          : (mobile ? getMobileVirtualURL(mobile) : (lastApiRequestInScenario ? lastApiRequestInScenario.url : null));

        const stepRecord = {
          text: formatStepText(step),
          depth,
          status: 'passed',
          durationMs: null,
          startedAt: new Date().toISOString(),
          _startMs: Date.now(),
          finishedAt: null,
          targetSelector,
          errorMessage: null,
          diagnostics: createEmptyDiagnostics(pageURL)
        };

        if (ASSERTION_METHOD_RE.test(method)) {
          let expected = null;
          let actual = null;
          if (/^expect/i.test(method) && args.length >= 2) {
            actual = safeSerializeArg(args[0], 1024);
            expected = safeSerializeArg(args.slice(1).length === 1 ? args[1] : args.slice(1), 1024);
          } else if (args.length > 0) {
            expected = safeSerializeArg(args.length === 1 ? args[0] : args, 1024);
          }
          stepRecord.diagnostics.assertion = {
            method,
            passed: true,
            expected,
            actual,
            message: null,
            relatedRequestId: lastApiRequestInScenario ? lastApiRequestInScenario.id : null
          };
        }

        currentStep = stepRecord;
        lastStepRecord = stepRecord;
        currentScenario.steps.push(stepRecord);

        if (active && active.page) {
          track(
            captureScreenshot(active.page).then((uri) => {
              if (uri && !stepRecord.diagnostics.beforeScreenshotDataURI) {
                stepRecord.diagnostics.beforeScreenshotDataURI = uri;
              }
            })
          );
        } else if (mobile) {
          track(
            captureMobileScreenshot(mobile).then((uri) => {
              if (uri && !stepRecord.diagnostics.beforeScreenshotDataURI) {
                stepRecord.diagnostics.beforeScreenshotDataURI = uri;
              }
            })
          );
        }
      }

      function endStepExecution(step) {
        if (step && step.constructor && step.constructor.name === 'MetaStep') return;
        const stepRecord = currentStep;
        if (!stepRecord) return;
        stepRecord.finishedAt = new Date().toISOString();
        stepRecord.durationMs = Math.max(0, Date.now() - stepRecord._startMs);
        if (step && step.status === 'failed') {
          stepRecord.status = 'failed';
          if (stepRecord.diagnostics.assertion) {
            stepRecord.diagnostics.assertion.passed = false;
          }
        }

        const active = getActivePage(container);
        const mobile = (!active || !active.page) ? getActiveMobileTarget(container) : null;
        if (active && active.page) {
          try {
            if (typeof active.page.url === 'function') {
              stepRecord.diagnostics.pageURL = active.page.url();
            }
          } catch {}
          track(
            Promise.all([
              captureScreenshot(active.page),
              captureDOMSnapshot(active.page, stepRecord.targetSelector)
            ]).then(([shot, dom]) => {
              if (shot) stepRecord.diagnostics.afterScreenshotDataURI = shot;
              if (dom) stepRecord.diagnostics.domSnapshot = dom;
              flushSync();
            })
          );
        } else if (mobile) {
          if (!stepRecord.diagnostics.pageURL) {
            stepRecord.diagnostics.pageURL = getMobileVirtualURL(mobile);
          }
          track(
            Promise.all([
              captureMobileScreenshot(mobile),
              captureMobileViewTreeSnapshot(mobile, stepRecord.targetSelector)
            ]).then(([shot, dom]) => {
              if (shot) stepRecord.diagnostics.afterScreenshotDataURI = shot;
              if (dom) stepRecord.diagnostics.domSnapshot = dom;
              flushSync();
            })
          );
        }
        // Clear currentStep so subsequent direct axios/flex-rest/fetch calls get their own API step
        currentStep = null;
      }

      // In CodeceptJS 4.x `recordStep()`, `step.before` and `step.after` fire synchronously at ENQUEUE time,
      // while `step.started` and `step.finished` bracket the actual async execution of `step.run()`.
      if (event.step && event.step.started && event.step.finished) {
        dispatcher.on(event.step.started, beginStepExecution);
        dispatcher.on(event.step.finished, endStepExecution);
      } else {
        dispatcher.on(event.step.before, beginStepExecution);
        dispatcher.on(event.step.after, endStepExecution);
      }

      dispatcher.on(event.step.failed, (step, err) => {
        const targetStep = currentStep || lastStepRecord;
        if (!targetStep) return;
        targetStep.status = 'failed';
        if (err) {
          targetStep.errorMessage = err.message ? String(err.message) : String(err);
        }
        if (targetStep.diagnostics.assertion) {
          targetStep.diagnostics.assertion.passed = false;
          targetStep.diagnostics.assertion.message = targetStep.errorMessage;
        }
      });

      dispatcher.on(event.test.passed, () => {
        if (!currentScenario) return;
        currentScenario.status = 'passed';
      });

      dispatcher.on(event.test.failed, (test, err) => {
        if (!currentScenario) return;
        currentScenario.status = 'failed';
        if (err) {
          currentScenario.errorMessage = err.message ? String(err.message) : String(err);
          currentScenario.errorStack = err.stack ? String(err.stack) : currentScenario.errorMessage;
        }
      });

      if (event.test && event.test.skipped) {
        dispatcher.on(event.test.skipped, (test) => {
          if (currentScenario) {
            currentScenario.status = 'skipped';
          }
        });
      }

      dispatcher.on(event.test.after, () => {
        if (currentScenario) {
          currentScenario.finishedAt = new Date().toISOString();
          currentScenario.durationMs = Math.max(0, Date.now() - currentScenario._startMs);
        }
        currentStep = null;
        lastStepRecord = null;
        lastApiRequestInScenario = null;
        flushSync();
        track(Promise.allSettled(Array.from(pendingTasks)).then(() => flushSync()));
      });

      dispatcher.on(event.all.result, () => {
        flushSync();
        track(Promise.allSettled(Array.from(pendingTasks)).then(() => flushSync()));
      });

      process.on('beforeExit', () => {
        flushSync();
      });

      process.on('exit', () => {
        flushSync();
      });
    };
    """#

    /// Ensures the zero-dependency CodeceptJS plugin exists in a whitespace-free directory
    /// and returns its file URL.
    public static func ensurePluginFileURL(baseDirectory: URL? = nil) -> URL? {
        let candidateBase = baseDirectory ?? FileManager.default.temporaryDirectory
        let safeBase: URL
        if candidateBase.path.contains(" ") {
            safeBase = URL(fileURLWithPath: "/tmp", isDirectory: true)
        } else {
            safeBase = candidateBase
        }

        let dir = safeBase.appendingPathComponent(directoryName, isDirectory: true)
        let pluginURL = dir.appendingPathComponent(pluginFileName)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: pluginURL, encoding: .utf8)) != pluginScriptSource {
                try pluginScriptSource.write(to: pluginURL, atomically: true, encoding: .utf8)
            }
            return pluginURL
        } catch {
            return nil
        }
    }

    /// Produces the JSON payload for CodeceptJS `-o` (`--override`) that deep-merges
    /// the Ceptra Time-Travel plugin without touching existing user plugins.
    public static func overrideJSONArgument(pluginFileURL: URL) -> String {
        let payload: [String: Any] = [
            "plugins": [
                "ceptraTimeTravel": [
                    "enabled": true,
                    "require": pluginFileURL.path
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"plugins":{"ceptraTimeTravel":{"enabled":true}}}"#
        }
        return json
    }
}
