import Foundation

/// Generates and caches a zero-dependency CommonJS Playwright Test custom reporter
/// (`--reporter=list,<path>`) that captures every test, nested `test.step` / `page.*` /
/// `expect` step, duration, console output, error stack, and screenshot/trace attachment
/// into Ceptra's native `TimeTravelTraceBundle` JSON schema — with zero edits to the
/// user's `playwright.config.*`.
public enum PlaywrightTimeTravelReporterLoader {
    private static let directoryName = "ceptra-pw-time-travel-v1"
    private static let reporterFileName = "ceptra-pw-time-travel-reporter.cjs"

    public static let reporterScriptSource: String = #"""
    'use strict';

    const fs = require('node:fs');
    const path = require('node:path');
    const crypto = require('node:crypto');
    const zlib = require('node:zlib');

    const MAX_ATTACHMENT_BYTES = 1536 * 1024;
    const MAX_ZIP_BYTES = 64 * 1024 * 1024;
    const MAX_ERROR_CHARS = 8192;
    const MAX_CONSOLE_CHARS = 4096;
    const MAX_DOM_CHARS = 160 * 1024;
    const MAX_API_BODY_CHARS = 128 * 1024;
    const MAX_BROWSER_BODY_CHARS = 32 * 1024;
    const MAX_BROWSER_NET_PER_STEP = 40;
    const ANSI_RE = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;
    const SENSITIVE_HEADER_RE = /^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token|x-access-token|x-csrf-token|x-xsrf-token)$/i;
    const VOID_HTML_TAGS = new Set([
      'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
      'link', 'meta', 'param', 'source', 'track', 'wbr'
    ]);
    const INTERNAL_HOOK_TITLES = new Set([
      'Before Hooks', 'After Hooks', 'Worker Cleanup'
    ]);
    const INTERNAL_PW_API_TITLES = new Set([
      'Launch browser', 'Create context', 'Create page', 'Close context', 'Close page',
      'Create request context', 'Dispose request context',
      'browserType.launch', 'browser.newContext', 'browserContext.newPage',
      'browserContext.close', 'page.close', 'apiRequest.newContext', 'apiRequestContext.dispose'
    ]);
    const WEB_ASSERTION_PATTERNS = [
      'tobevisible', 'tobehidden', 'tobeenabled', 'tobedisabled', 'tobechecked',
      'tobefocused', 'tobeattached', 'tobeeditable', 'tobeempty', 'tobeinviewport',
      'tohavetext', 'tocontaintext', 'tohavevalue', 'tohavevalues', 'tohaveattribute',
      'tohaveclass', 'tohavecount', 'tohavecss', 'tohaveid', 'tohavejsproperty',
      'tohaveurl', 'tohavetitle', 'tohavescreenshot', 'tohaveaccessible', 'tomatcharia'
    ];

    function stripAnsi(str) {
      if (typeof str !== 'string') return '';
      return str.replace(ANSI_RE, '');
    }

    function genId() {
      return crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    }

    function truncate(str, max) {
      if (typeof str !== 'string') return null;
      if (str.length <= max) return str;
      return str.slice(0, max) + '\n/* [truncated by Ceptra] */';
    }

    function extractSelectorFromTitle(title) {
      if (typeof title !== 'string' || !title) return null;
      const m = title.match(/\((['"`])([^'"`\n]{1,180})\1/);
      return m ? m[2] : null;
    }

    function extractPageURLFromTitle(title) {
      if (typeof title !== 'string' || !title) return null;
      const gotoMatch = title.match(/page\.goto\((['"`])([^'"`\n]+)\1/);
      if (gotoMatch) return gotoMatch[2];
      const navMatch = title.match(/^Navigate to (['"`])([^'"`\n]+)\1/i);
      if (navMatch) return navMatch[2];
      return null;
    }

    function extractAssertionMethod(title) {
      if (typeof title !== 'string' || !title) return 'expect';
      const quoted = title.match(/Expect\s+["']([^"']+)["']/i);
      if (quoted) return quoted[1].trim();
      const chained = title.match(/\)\.((?:not\.)?[A-Za-z0-9_]+)\s*\(/);
      if (chained) return chained[1].trim();
      return title.split('(')[0].trim() || 'expect';
    }

    function isWebAssertionMethod(method) {
      const lower = String(method || '').toLowerCase();
      return WEB_ASSERTION_PATTERNS.some((p) => lower.includes(p));
    }

    function isNoisyInternalStep(category, title) {
      if (category === 'fixture' || category === 'pw:api:internal') return true;
      if (category === 'hook' && INTERNAL_HOOK_TITLES.has(title)) return true;
      if (INTERNAL_PW_API_TITLES.has(title)) return true;
      if (/^(?:Fixture|Attach)\s+["']/.test(title)) return true;
      return false;
    }

    function isApiRequestStepTitle(title) {
      if (typeof title !== 'string' || !title) return false;
      if (/^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)(?:\s|$)/i.test(title.trim())) return true;
      if (/^(?:apiRequestContext|request)\.(?:get|post|put|patch|delete|head|fetch)\b/i.test(title)) return true;
      return false;
    }

    function extractInlineTags(text) {
      if (typeof text !== 'string') return [];
      return text.split(/\s+/).filter((t) => t.startsWith('@'));
    }

    function mapStatus(pwStatus) {
      switch (pwStatus) {
        case 'passed': return 'passed';
        case 'skipped': return 'skipped';
        case 'failed':
        case 'timedOut':
        case 'interrupted':
          return 'failed';
        default:
          return 'failed';
      }
    }

    function attachmentToDataURI(att) {
      if (!att) return null;
      const mime = String(att.contentType || '').toLowerCase();
      if (!mime.startsWith('image/')) return null;
      try {
        let buf = null;
        if (att.body && Buffer.isBuffer(att.body)) {
          buf = att.body;
        } else if (att.path && fs.existsSync(att.path)) {
          const st = fs.statSync(att.path);
          if (st.size > 0 && st.size <= MAX_ATTACHMENT_BYTES) {
            buf = fs.readFileSync(att.path);
          }
        }
        if (!buf || buf.length === 0 || buf.length > MAX_ATTACHMENT_BYTES) return null;
        return `data:${mime};base64,${buf.toString('base64')}`;
      } catch {
        return null;
      }
    }

    // Zero-dependency ZIP reader for Playwright trace.zip attachments (STORED & DEFLATE)
    function openZip(zipPath) {
      try {
        if (!zipPath || !fs.existsSync(zipPath)) return null;
        const st = fs.statSync(zipPath);
        if (st.size < 22 || st.size > MAX_ZIP_BYTES) return null;
        const buf = fs.readFileSync(zipPath);

        // Locate End of Central Directory (0x06054b50)
        const minOffset = Math.max(0, buf.length - 65558);
        let eocd = -1;
        for (let i = buf.length - 22; i >= minOffset; i--) {
          if (buf.readUInt32LE(i) === 0x06054b50) {
            eocd = i;
            break;
          }
        }
        if (eocd < 0) return null;

        const entryCount = buf.readUInt16LE(eocd + 10);
        const cdOffset = buf.readUInt32LE(eocd + 16);
        const entries = new Map();
        let pos = cdOffset;
        for (let i = 0; i < entryCount && pos + 46 <= buf.length; i++) {
          if (buf.readUInt32LE(pos) !== 0x02014b50) break;
          const compression = buf.readUInt16LE(pos + 10);
          const compSize = buf.readUInt32LE(pos + 20);
          const uncompSize = buf.readUInt32LE(pos + 24);
          const nameLen = buf.readUInt16LE(pos + 28);
          const extraLen = buf.readUInt16LE(pos + 30);
          const commentLen = buf.readUInt16LE(pos + 32);
          const localOffset = buf.readUInt32LE(pos + 42);
          const name = buf.toString('utf8', pos + 46, pos + 46 + nameLen);
          entries.set(name, { name, compression, compSize, uncompSize, localOffset });
          pos += 46 + nameLen + extraLen + commentLen;
        }

        function getBuffer(name) {
          const entry = entries.get(name);
          if (!entry) return null;
          const off = entry.localOffset;
          if (off + 30 > buf.length || buf.readUInt32LE(off) !== 0x04034b50) return null;
          const localNameLen = buf.readUInt16LE(off + 26);
          const localExtraLen = buf.readUInt16LE(off + 28);
          const dataStart = off + 30 + localNameLen + localExtraLen;
          const dataEnd = dataStart + entry.compSize;
          if (dataEnd > buf.length) return null;
          const slice = buf.subarray(dataStart, dataEnd);
          try {
            if (entry.compression === 0) return Buffer.from(slice);
            if (entry.compression === 8) return zlib.inflateRawSync(slice);
            return null;
          } catch {
            return null;
          }
        }

        return {
          names: Array.from(entries.keys()),
          getBuffer,
          getText(name) {
            const b = getBuffer(name);
            return b ? b.toString('utf8') : null;
          }
        };
      } catch {
        return null;
      }
    }

    function escapeHtmlAttr(val) {
      return String(val)
        .replace(/&/g, '&amp;')
        .replace(/"/g, '&quot;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
    }

    function escapeHtmlText(val) {
      return String(val)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
    }

    function serializePlaywrightDomNode(node, budget, depth) {
      if (!node || budget.len >= MAX_DOM_CHARS || depth > 48) return '';
      if (typeof node === 'string') {
        const escaped = escapeHtmlText(node);
        budget.len += escaped.length;
        return escaped;
      }
      if (!Array.isArray(node) || node.length === 0) return '';
      // Skip incremental snapshot numeric references ([snapIndex, nodeIndex])
      if (typeof node[0] !== 'string') return '';

      const rawTag = node[0];
      const tag = rawTag.toLowerCase();
      if (tag === 'script' || tag === 'noscript') return '';

      const attrs = (node[1] && typeof node[1] === 'object' && !Array.isArray(node[1])) ? node[1] : null;
      let attrStr = '';
      if (attrs) {
        for (const [k, v] of Object.entries(attrs)) {
          if (k.startsWith('__playwright_')) continue;
          if (v === '' || v === true) {
            attrStr += ` ${k}`;
          } else if (v != null && v !== false) {
            attrStr += ` ${k}="${escapeHtmlAttr(v)}"`;
          }
        }
      }

      if (VOID_HTML_TAGS.has(tag)) {
        const out = `<${tag}${attrStr}>`;
        budget.len += out.length;
        return out;
      }

      const openTag = `<${tag}${attrStr}>`;
      budget.len += openTag.length;
      const startIdx = attrs ? 2 : 1;
      let inner = '';
      for (let i = startIdx; i < node.length && budget.len < MAX_DOM_CHARS; i++) {
        inner += serializePlaywrightDomNode(node[i], budget, depth + 1);
      }
      const closeTag = `</${tag}>`;
      budget.len += closeTag.length;
      return `${openTag}${inner}${closeTag}`;
    }

    function extractTitleFromHtml(html) {
      if (typeof html !== 'string' || !html) return null;
      const m = html.match(/<title[^>]*>([^<]{1,200})<\/title>/i);
      return m ? m[1].trim() : null;
    }

    function redactHeadersArray(headersArr) {
      const out = {};
      if (!Array.isArray(headersArr)) return out;
      for (const h of headersArr) {
        if (!h || !h.name) continue;
        const name = String(h.name);
        if (name.startsWith(':')) continue;
        out[name] = SENSITIVE_HEADER_RE.test(name) ? '[REDACTED]' : String(h.value ?? '');
      }
      return out;
    }

    function guessResourceType(mimeType, url) {
      const mime = String(mimeType || '').toLowerCase();
      if (mime.includes('json') || mime.includes('graphql')) return 'fetch';
      if (mime.includes('html')) return 'document';
      if (mime.includes('javascript')) return 'script';
      if (mime.includes('css')) return 'stylesheet';
      if (mime.startsWith('image/')) return 'image';
      if (mime.startsWith('font/')) return 'font';
      if (/\.(?:js|mjs)(?:[?#]|$)/i.test(url || '')) return 'script';
      if (/\.css(?:[?#]|$)/i.test(url || '')) return 'stylesheet';
      return 'other';
    }

    function isTextMime(mimeType) {
      const m = String(mimeType || '').toLowerCase();
      return m.includes('json') || m.includes('xml') || m.includes('text/') ||
        m.includes('javascript') || m.includes('graphql') || m.includes('form-urlencoded');
    }

    function roundPositiveMs(val) {
      return (typeof val === 'number' && Number.isFinite(val) && val > 0) ? Math.round(val) : null;
    }

    function parsePlaywrightTraceZip(zipPath) {
      const zip = openZip(zipPath);
      if (!zip) return null;

      let viewport = null;
      const screencastFrames = [];
      const actionsByCallId = new Map();
      const inputBoxByCallId = new Map();
      const frameSnapshots = [];
      const consoleEvents = [];
      const networkEntries = [];

      // 1. Parse all *.trace NDJSON files (test.trace, 0-trace.trace, 1-trace.trace, ...)
      const traceFiles = zip.names.filter((n) => n.endsWith('.trace') && !n.endsWith('.stacks'));
      for (const fileName of traceFiles) {
        const content = zip.getText(fileName);
        if (!content) continue;
        let baseWallTime = null;
        let baseMonotonic = null;

        const toWallMs = (ev) => {
          if (typeof ev.frameSwapWallTime === 'number' && ev.frameSwapWallTime > 1e12) return ev.frameSwapWallTime;
          if (typeof ev.wallTime === 'number' && ev.wallTime > 1e12) return ev.wallTime;
          const mono = typeof ev.timestamp === 'number' ? ev.timestamp
            : (typeof ev.startTime === 'number' ? ev.startTime : (typeof ev.time === 'number' ? ev.time : null));
          if (mono != null && baseWallTime != null && baseMonotonic != null) {
            return baseWallTime + (mono - baseMonotonic);
          }
          return null;
        };

        for (const rawLine of content.split('\n')) {
          if (!rawLine || rawLine[0] !== '{') continue;
          let ev;
          try { ev = JSON.parse(rawLine); } catch { continue; }
          if (!ev || !ev.type) continue;

          if (ev.type === 'context-options') {
            if (typeof ev.wallTime === 'number') baseWallTime = ev.wallTime;
            if (typeof ev.monotonicTime === 'number') baseMonotonic = ev.monotonicTime;
            if (!viewport && ev.options && ev.options.viewport) {
              viewport = {
                width: Number(ev.options.viewport.width) || 1280,
                height: Number(ev.options.viewport.height) || 720
              };
            }
          } else if (ev.type === 'screencast-frame') {
            const wallMs = toWallMs(ev);
            if (ev.file) {
              if (!viewport && ev.width && ev.height) {
                viewport = { width: Number(ev.width), height: Number(ev.height) };
              }
              screencastFrames.push({
                file: ev.file,
                width: Number(ev.width) || (viewport ? viewport.width : 1280),
                height: Number(ev.height) || (viewport ? viewport.height : 720),
                wallTime: wallMs,
                monotonic: typeof ev.timestamp === 'number' ? ev.timestamp : 0
              });
            }
          } else if (ev.type === 'before' && ev.callId) {
            const wallMs = toWallMs(ev);
            actionsByCallId.set(ev.callId, {
              callId: ev.callId,
              apiName: ev.apiName || '',
              title: ev.title || '',
              method: ev.method || '',
              selector: (ev.params && typeof ev.params.selector === 'string') ? ev.params.selector : null,
              url: (ev.params && typeof ev.params.url === 'string') ? ev.params.url : null,
              startWallMs: wallMs,
              endWallMs: wallMs,
              startMono: typeof ev.startTime === 'number' ? ev.startTime : null
            });
          } else if (ev.type === 'after' && ev.callId) {
            const act = actionsByCallId.get(ev.callId);
            if (act && typeof ev.endTime === 'number' && act.startMono != null && act.startWallMs != null) {
              act.endWallMs = act.startWallMs + Math.max(0, ev.endTime - act.startMono);
            }
          } else if (ev.type === 'input' && ev.callId) {
            if (ev.box && typeof ev.box.x === 'number') {
              inputBoxByCallId.set(ev.callId, {
                x: ev.box.x,
                y: ev.box.y,
                width: ev.box.width || 24,
                height: ev.box.height || 24
              });
            } else if (ev.point && typeof ev.point.x === 'number') {
              inputBoxByCallId.set(ev.callId, {
                x: Math.max(0, ev.point.x - 16),
                y: Math.max(0, ev.point.y - 16),
                width: 32,
                height: 32
              });
            }
          } else if (ev.type === 'frame-snapshot' && ev.snapshot) {
            const snap = ev.snapshot;
            if (snap.isMainFrame === false) continue;
            const snapWall = (typeof snap.timestamp === 'number' && baseWallTime != null && baseMonotonic != null)
              ? baseWallTime + (snap.timestamp - baseMonotonic)
              : toWallMs(ev);
            frameSnapshots.push({
              callId: snap.callId || null,
              phase: snap.snapshotName ? (String(snap.snapshotName).startsWith('before') ? 'before' : 'after') : 'after',
              frameUrl: snap.frameUrl || null,
              viewport: snap.viewport || viewport,
              wallTime: snapWall,
              htmlNode: snap.html || null
            });
          } else if (ev.type === 'console') {
            const wallMs = toWallMs(ev);
            const lvl = String(ev.messageType || 'log').toLowerCase();
            consoleEvents.push({
              wallTime: wallMs,
              entry: {
                id: genId(),
                level: lvl === 'warning' ? 'warn' : (['log', 'info', 'warn', 'error', 'debug'].includes(lvl) ? lvl : 'log'),
                message: truncate(stripAnsi(String(ev.text || '')), MAX_CONSOLE_CHARS) || '',
                timestamp: wallMs ? new Date(wallMs).toISOString() : new Date().toISOString(),
                sourceURL: ev.location && ev.location.url ? String(ev.location.url) : null,
                lineNumber: ev.location && typeof ev.location.lineNumber === 'number' ? ev.location.lineNumber : null
              }
            });
          } else if (ev.type === 'event' && ev.method === 'pageError' && ev.params && ev.params.error) {
            const wallMs = toWallMs(ev);
            const errObj = ev.params.error.error || ev.params.error;
            const msg = errObj.stack || errObj.message || String(errObj);
            consoleEvents.push({
              wallTime: wallMs,
              entry: {
                id: genId(),
                level: 'pageerror',
                message: truncate(stripAnsi(String(msg)), MAX_CONSOLE_CHARS) || 'Uncaught page error',
                timestamp: wallMs ? new Date(wallMs).toISOString() : new Date().toISOString(),
                sourceURL: null,
                lineNumber: null
              }
            });
          }
        }
      }

      // 2. Parse all *.network NDJSON files (0-trace.network, 1-trace.network, ...)
      const networkFiles = zip.names.filter((n) => n.endsWith('.network'));
      for (const fileName of networkFiles) {
        const content = zip.getText(fileName);
        if (!content) continue;
        for (const rawLine of content.split('\n')) {
          if (!rawLine || rawLine[0] !== '{') continue;
          let ev;
          try { ev = JSON.parse(rawLine); } catch { continue; }
          if (!ev || ev.type !== 'resource-snapshot' || !ev.snapshot) continue;
          const snap = ev.snapshot;
          const req = snap.request || {};
          const res = snap.response || {};
          const isApi = Boolean(snap._apiRequestRef);
          const url = String(req.url || '');
          if (!url || url.startsWith('data:')) continue;

          const startedAtMs = snap.startedDateTime ? Date.parse(snap.startedDateTime) : null;
          const totalMs = (typeof snap.time === 'number' && Number.isFinite(snap.time) && snap.time >= 0)
            ? Math.round(snap.time)
            : null;

          // Request body
          let requestBody = null;
          if (req.postData) {
            if (typeof req.postData.text === 'string' && req.postData.text.length > 0) {
              requestBody = truncate(req.postData.text, isApi ? MAX_API_BODY_CHARS : MAX_BROWSER_BODY_CHARS);
            } else if (req.postData._sha1) {
              const b = zip.getBuffer(`resources/${req.postData._sha1}`);
              if (b && b.length > 0) {
                requestBody = truncate(b.toString('utf8'), isApi ? MAX_API_BODY_CHARS : MAX_BROWSER_BODY_CHARS);
              }
            }
          }

          // Response body (always decode for Playwright API calls; for browser calls, decode text/JSON only)
          let responseBody = null;
          const resContent = res.content || {};
          const mimeType = String(resContent.mimeType || '');
          const resourceKey = resContent._file
            ? String(resContent._file)
            : (resContent._sha1 ? `resources/${resContent._sha1}` : null);
          if (typeof resContent.text === 'string' && resContent.text.length > 0) {
            if (isApi || isTextMime(mimeType)) {
              const rawTxt = resContent.encoding === 'base64'
                ? Buffer.from(resContent.text, 'base64').toString('utf8')
                : resContent.text;
              responseBody = truncate(rawTxt, isApi ? MAX_API_BODY_CHARS : MAX_BROWSER_BODY_CHARS);
            }
          } else if (resourceKey && (isApi || isTextMime(mimeType))) {
            const b = zip.getBuffer(resourceKey);
            if (b && b.length > 0) {
              responseBody = truncate(b.toString('utf8'), isApi ? MAX_API_BODY_CHARS : MAX_BROWSER_BODY_CHARS);
            }
          }

          const t = snap.timings || {};
          const dnsMs = roundPositiveMs(t.dns);
          const connectMs = roundPositiveMs(t.connect);
          const tlsMs = roundPositiveMs(t.ssl);
          const ttfbMs = roundPositiveMs(t.wait);
          const downloadMs = roundPositiveMs(t.receive);
          const hasTimings = dnsMs != null || connectMs != null || tlsMs != null || ttfbMs != null || downloadMs != null;

          const statusNum = (typeof res.status === 'number' && res.status > 0) ? res.status : null;
          const failureText = res._failureText ? String(res._failureText) : null;

          networkEntries.push({
            startedAtMs: Number.isFinite(startedAtMs) ? startedAtMs : null,
            isApi,
            entry: {
              id: genId(),
              method: String(req.method || 'GET').toUpperCase(),
              url,
              resourceType: isApi ? 'api' : guessResourceType(mimeType, url),
              source: isApi ? 'playwright-api' : 'playwright-browser',
              status: statusNum,
              statusText: res.statusText ? String(res.statusText) : null,
              startedAt: Number.isFinite(startedAtMs) ? new Date(startedAtMs).toISOString() : null,
              durationMs: totalMs,
              requestSizeBytes: typeof req.bodySize === 'number' && req.bodySize > 0
                ? req.bodySize
                : (requestBody ? Buffer.byteLength(requestBody, 'utf8') : null),
              responseSizeBytes: typeof resContent.size === 'number' && resContent.size > 0
                ? resContent.size
                : (responseBody ? Buffer.byteLength(responseBody, 'utf8') : null),
              timings: (hasTimings || totalMs != null)
                ? { dnsMs, connectMs, tlsMs, ttfbMs, downloadMs, totalMs }
                : null,
              requestHeaders: redactHeadersArray(req.headers),
              responseHeaders: redactHeadersArray(res.headers),
              requestBody,
              responseBody,
              errorText: failureText
            }
          });
        }
      }

      screencastFrames.sort((a, b) => (a.wallTime ?? a.monotonic) - (b.wallTime ?? b.monotonic));
      frameSnapshots.sort((a, b) => (a.wallTime ?? 0) - (b.wallTime ?? 0));

      const frameDataURICache = new Map();
      function getFrameDataURI(frame) {
        if (!frame || !frame.file) return null;
        if (frameDataURICache.has(frame.file)) return frameDataURICache.get(frame.file);
        const buf = zip.getBuffer(frame.file);
        if (!buf || buf.length === 0 || buf.length > MAX_ATTACHMENT_BYTES) {
          frameDataURICache.set(frame.file, null);
          return null;
        }
        const ext = path.extname(frame.file).toLowerCase();
        const mime = ext === '.png' ? 'image/png' : (ext === '.webp' ? 'image/webp' : 'image/jpeg');
        const uri = `data:${mime};base64,${buf.toString('base64')}`;
        frameDataURICache.set(frame.file, uri);
        return uri;
      }

      const domHtmlCache = new WeakMap();
      function serializeSnapshot(snap) {
        if (!snap || !snap.htmlNode) return null;
        if (domHtmlCache.has(snap)) return domHtmlCache.get(snap);
        const html = serializePlaywrightDomNode(snap.htmlNode, { len: 0 }, 0);
        const result = html && html.length > 0
          ? { html, title: extractTitleFromHtml(html), url: snap.frameUrl || null }
          : null;
        domHtmlCache.set(snap, result);
        return result;
      }

      return {
        viewport,
        screencastFrames,
        actions: Array.from(actionsByCallId.values()),
        inputBoxByCallId,
        frameSnapshots,
        consoleEvents,
        networkEntries,
        getFrameDataURI,
        serializeSnapshot
      };
    }

    function enrichRecordFromTraceZip(record, stepMetaMap, zipPath) {
      const parsed = parsePlaywrightTraceZip(zipPath);
      if (!parsed) return;

      const steps = record.steps;
      if (steps.length === 0) return;

      // Identify non-container leaf steps (avoid double-attaching onto parent test.step wrappers)
      const hasChildren = new Set();
      for (let i = 0; i < steps.length - 1; i++) {
        if ((steps[i + 1].depth || 0) > (steps[i].depth || 0)) {
          hasChildren.add(steps[i]);
        }
      }
      const leafSteps = steps.filter((s) => !hasChildren.has(s));
      const candidateSteps = leafSteps.length > 0 ? leafSteps : steps;

      const getMeta = (s) => stepMetaMap.get(s) || { startMs: Date.parse(s.startedAt) || 0, endMs: Date.parse(s.finishedAt || s.startedAt) || 0, category: '' };

      // 1. Attach Playwright screencast frames (Web before/after screenshots)
      if (parsed.screencastFrames.length > 0) {
        const frames = parsed.screencastFrames;
        for (const step of candidateSteps) {
          const meta = getMeta(step);
          if (!meta.startMs) continue;
          let beforeFrame = null;
          let afterFrame = null;
          for (const f of frames) {
            if (f.wallTime == null) continue;
            if (f.wallTime <= meta.startMs + 40) {
              beforeFrame = f;
            }
            if (f.wallTime <= meta.endMs + 250) {
              afterFrame = f;
            }
          }
          if (!afterFrame) {
            // Grab first frame shortly after step finished (e.g. fast page.goto before first paint)
            afterFrame = frames.find((f) => f.wallTime != null && f.wallTime >= meta.startMs) || frames[frames.length - 1];
          }
          if (!step.diagnostics.beforeScreenshotDataURI && beforeFrame && beforeFrame !== afterFrame) {
            step.diagnostics.beforeScreenshotDataURI = parsed.getFrameDataURI(beforeFrame);
          }
          if (!step.diagnostics.afterScreenshotDataURI && afterFrame) {
            step.diagnostics.afterScreenshotDataURI = parsed.getFrameDataURI(afterFrame);
          }
        }
      }

      // 2. Attach DOM snapshots, pageURL, and target element bounding boxes
      if (parsed.frameSnapshots.length > 0 || parsed.actions.length > 0) {
        let lastKnownURL = null;
        for (const step of candidateSteps) {
          const meta = getMeta(step);
          // Find closest Playwright action for target bounding box & callId match
          let matchedAction = null;
          let bestActDist = Infinity;
          for (const act of parsed.actions) {
            if (act.startWallMs == null) continue;
            const dist = Math.abs(act.startWallMs - meta.startMs);
            if (dist < 400 && dist < bestActDist) {
              bestActDist = dist;
              matchedAction = act;
            }
          }

          let chosenSnap = null;
          if (matchedAction) {
            chosenSnap = parsed.frameSnapshots.find((sn) => sn.callId === matchedAction.callId && sn.phase === 'after')
              || parsed.frameSnapshots.find((sn) => sn.callId === matchedAction.callId);
          }
          if (!chosenSnap && parsed.frameSnapshots.length > 0) {
            // Latest snapshot at or before step end
            for (const sn of parsed.frameSnapshots) {
              if (sn.wallTime != null && sn.wallTime <= meta.endMs + 250) {
                chosenSnap = sn;
              }
            }
            if (!chosenSnap) chosenSnap = parsed.frameSnapshots[0];
          }

          if (chosenSnap) {
            const domData = parsed.serializeSnapshot(chosenSnap);
            const rawBox = matchedAction ? parsed.inputBoxByCallId.get(matchedAction.callId) : null;
            const vp = chosenSnap.viewport || parsed.viewport;
            const bbox = rawBox ? {
              x: rawBox.x,
              y: rawBox.y,
              width: rawBox.width,
              height: rawBox.height,
              viewportWidth: vp ? vp.width : null,
              viewportHeight: vp ? vp.height : null
            } : null;

            if (domData) {
              if (!step.diagnostics.domSnapshot) {
                step.diagnostics.domSnapshot = {
                  html: domData.html,
                  url: domData.url,
                  title: domData.title,
                  targetSelector: step.targetSelector || (matchedAction ? matchedAction.selector : null),
                  targetOuterHTML: null,
                  targetBoundingBox: bbox,
                  matchedCount: null
                };
              }
              if (domData.url) lastKnownURL = domData.url;
            } else if (chosenSnap.frameUrl) {
              lastKnownURL = chosenSnap.frameUrl;
            }
          }

          if (step.diagnostics.pageURL) {
            lastKnownURL = step.diagnostics.pageURL;
          } else if (lastKnownURL && !isApiRequestStepTitle(step.text)) {
            step.diagnostics.pageURL = lastKnownURL;
          }

          // Enrich bare Playwright 1.50+ titles ("Navigate", "Click") with URL / selector from trace.zip
          if (matchedAction) {
            if (!step.targetSelector && matchedAction.selector) {
              step.targetSelector = matchedAction.selector;
            }
            if (step.text === 'Navigate' && (matchedAction.url || step.diagnostics.pageURL)) {
              step.text = `Navigate "${matchedAction.url || step.diagnostics.pageURL}"`;
            } else if (/^(?:Click|Dblclick|Fill|Type|Press|Hover|Check|Uncheck|Select option)$/i.test(step.text) && matchedAction.selector) {
              step.text = `${step.text} ${matchedAction.selector}`;
            }
          }
        }
      }

      // 3. Attach API & Browser network exchanges
      const apiEntries = parsed.networkEntries.filter((n) => n.isApi);
      const browserEntries = parsed.networkEntries.filter((n) => !n.isApi);

      for (const item of apiEntries) {
        let targetStep = null;
        // Prefer an explicit API request step overlapping startedAtMs
        const apiCandidates = candidateSteps.filter((s) => isApiRequestStepTitle(s.text));
        const pool = apiCandidates.length > 0 ? apiCandidates : candidateSteps;

        if (item.startedAtMs != null) {
          let bestDist = Infinity;
          for (const s of pool) {
            const m = getMeta(s);
            if (item.startedAtMs >= m.startMs - 250 && item.startedAtMs <= m.endMs + 250) {
              const dist = Math.abs(item.startedAtMs - m.startMs);
              if (dist < bestDist) {
                bestDist = dist;
                targetStep = s;
              }
            }
          }
          if (!targetStep) {
            for (const s of pool) {
              const m = getMeta(s);
              const dist = Math.abs(item.startedAtMs - m.startMs);
              if (dist < bestDist) {
                bestDist = dist;
                targetStep = s;
              }
            }
          }
        }
        if (!targetStep) targetStep = pool[0];
        targetStep.diagnostics.networkRequests.push(item.entry);
        // Enrich bare HTTP method step titles (e.g. "GET" -> "GET /todos/1")
        if (/^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$/i.test(targetStep.text.trim()) && item.entry.url) {
          try {
            const u = new URL(item.entry.url);
            targetStep.text = `${item.entry.method} ${u.pathname}${u.search}`;
          } catch {
            targetStep.text = `${item.entry.method} ${item.entry.url}`;
          }
        }
      }

      if (browserEntries.length > 0) {
        // Prioritize document/fetch/xhr and HTTP errors first so the per-step cap keeps high-value traffic
        const priority = (e) => {
          if (e.entry.errorText || (e.entry.status != null && e.entry.status >= 400)) return 0;
          if (e.entry.resourceType === 'fetch' || e.entry.resourceType === 'xhr' || e.entry.resourceType === 'document') return 1;
          return 2;
        };
        const sortedBrowser = [...browserEntries].sort((a, b) => priority(a) - priority(b));
        for (const item of sortedBrowser) {
          let targetStep = null;
          if (item.startedAtMs != null) {
            for (const s of candidateSteps) {
              const m = getMeta(s);
              if (item.startedAtMs >= m.startMs - 150 && item.startedAtMs <= m.endMs + 250) {
                targetStep = s;
                break;
              }
            }
          }
          if (!targetStep) targetStep = candidateSteps[0];
          if (targetStep.diagnostics.networkRequests.length < MAX_BROWSER_NET_PER_STEP) {
            targetStep.diagnostics.networkRequests.push(item.entry);
          }
        }
      }

      // 4. Attach browser console & pageerror events
      for (const c of parsed.consoleEvents) {
        if (!c.entry.message) continue;
        let targetStep = null;
        if (c.wallTime != null) {
          for (const s of candidateSteps) {
            const m = getMeta(s);
            if (c.wallTime >= m.startMs - 150 && c.wallTime <= m.endMs + 250) {
              targetStep = s;
              break;
            }
          }
        }
        if (!targetStep) targetStep = candidateSteps[candidateSteps.length - 1];
        targetStep.diagnostics.consoleEntries.push(c.entry);
      }
    }

    function linkApiAssertions(record) {
      let lastApiRequestId = null;
      for (const step of record.steps) {
        const apiReqs = (step.diagnostics.networkRequests || []).filter((r) => r.source === 'playwright-api' || r.resourceType === 'api');
        if (apiReqs.length > 0) {
          lastApiRequestId = apiReqs[apiReqs.length - 1].id;
        }
        if (step.diagnostics.assertion && !step.diagnostics.assertion.relatedRequestId && lastApiRequestId) {
          if (!isWebAssertionMethod(step.diagnostics.assertion.method)) {
            step.diagnostics.assertion.relatedRequestId = lastApiRequestId;
          }
        }
      }
    }

    function extractFeatureAndTitle(test) {
      const titlePath = typeof test.titlePath === 'function' ? test.titlePath() : [];
      // Playwright titlePath: [rootTitle, projectName, filePath, ...describeTitles, testTitle]
      const cleaned = titlePath.filter((seg) => typeof seg === 'string' && seg.length > 0);
      const testTitle = test.title || (cleaned.length > 0 ? cleaned[cleaned.length - 1] : 'Test');
      const projectName = (typeof test.parent?.project === 'function' ? test.parent.project()?.name : null)
        || (titlePath.length >= 2 && titlePath[1] ? titlePath[1] : null);

      const filePath = test.location && test.location.file ? String(test.location.file) : null;
      let describes = [];
      if (titlePath.length >= 4) {
        // Skip root(0), project(1), file(2), and testTitle(last)
        describes = titlePath.slice(3, titlePath.length - 1).filter(Boolean);
      }

      let featureTitle = describes.length > 0
        ? describes.join(' › ')
        : (filePath ? path.basename(filePath).replace(/\.(?:spec|test)\.[^.]+$/i, '') : 'Playwright');

      // Always include [projectName] when present so featureTitle matches Playwright's list reporter output
      if (projectName) {
        featureTitle = `[${projectName}] ${featureTitle}`;
      }
      return { featureTitle, scenarioTitle: testTitle, filePath };
    }

    function createEmptyDiagnostics() {
      return {
        pageURL: null,
        beforeScreenshotDataURI: null,
        afterScreenshotDataURI: null,
        domSnapshot: null,
        networkRequests: [],
        consoleEntries: [],
        assertion: null
      };
    }

    class CeptraPlaywrightTimeTravelReporter {
      constructor() {
        this.outputDir = process.env.CEPTRA_TIME_TRAVEL_DIR || '';
        this.workerFile = this.outputDir
          ? path.join(this.outputDir, `worker-${process.pid}-${crypto.randomBytes(4).toString('hex')}.json`)
          : '';
        this.scenarios = [];
        this.activeByTest = new WeakMap();
      }

      onBegin() {}

      onTestBegin(test, result) {
        const meta = extractFeatureAndTitle(test);
        const startDate = (result && result.startTime instanceof Date) ? result.startTime : new Date();
        const rawTags = Array.isArray(test.tags) ? test.tags : [];
        const tags = Array.from(new Set([...rawTags, ...extractInlineTags(meta.scenarioTitle)])).sort();

        const record = {
          featureTitle: meta.featureTitle,
          scenarioTitle: meta.scenarioTitle,
          filePath: meta.filePath,
          status: 'passed',
          durationMs: 0,
          startedAt: startDate.toISOString(),
          finishedAt: null,
          tags,
          errorMessage: null,
          errorStack: null,
          steps: []
        };

        this.scenarios.push(record);
        this.activeByTest.set(test, {
          record,
          stepMap: new WeakMap(),
          stepMetaMap: new WeakMap(),
          activeStepStack: [],
          pendingConsole: []
        });
      }

      onStepBegin(test, _result, step) {
        const state = this.activeByTest.get(test);
        if (!state || !step) return;

        const category = String(step.category || '');
        const title = String(step.title || 'Step');
        // Skip noisy internal Playwright fixture/lifecycle wrappers unless they error in onStepEnd
        if (isNoisyInternalStep(category, title)) return;

        let depth = 0;
        let p = step.parent;
        while (p) {
          const pCat = String(p.category || '');
          const pTitle = String(p.title || '');
          if (!isNoisyInternalStep(pCat, pTitle)) depth++;
          p = p.parent;
        }

        const startDate = (step.startTime instanceof Date) ? step.startTime : new Date();
        const startMs = startDate.getTime();
        const stepRecord = {
          text: title,
          depth: Math.min(depth, 6),
          status: 'passed',
          durationMs: null,
          startedAt: startDate.toISOString(),
          finishedAt: null,
          targetSelector: extractSelectorFromTitle(title),
          errorMessage: null,
          diagnostics: createEmptyDiagnostics()
        };

        if (category === 'expect') {
          stepRecord.diagnostics.assertion = {
            method: extractAssertionMethod(title),
            passed: true,
            expected: null,
            actual: null,
            message: null,
            relatedRequestId: null
          };
        }

        const pageURL = extractPageURLFromTitle(title);
        if (pageURL) {
          stepRecord.diagnostics.pageURL = pageURL;
        }

        if (state.pendingConsole.length > 0) {
          stepRecord.diagnostics.consoleEntries.push(...state.pendingConsole.splice(0));
        }

        state.record.steps.push(stepRecord);
        state.stepMap.set(step, stepRecord);
        state.stepMetaMap.set(stepRecord, { startMs, endMs: startMs, category });
        state.activeStepStack.push(stepRecord);
      }

      onStepEnd(test, _result, step) {
        const state = this.activeByTest.get(test);
        if (!state || !step) return;

        let stepRecord = state.stepMap.get(step);
        if (!stepRecord && step.error) {
          const startDate = step.startTime instanceof Date ? step.startTime : new Date();
          const dur = typeof step.duration === 'number' ? Math.max(0, Math.round(step.duration)) : 0;
          const startMs = startDate.getTime();
          // Promote failed fixture/internal step so failure diagnostics are never lost
          stepRecord = {
            text: String(step.title || 'Fixture step'),
            depth: 0,
            status: 'failed',
            durationMs: dur,
            startedAt: startDate.toISOString(),
            finishedAt: new Date(startMs + dur).toISOString(),
            targetSelector: null,
            errorMessage: null,
            diagnostics: createEmptyDiagnostics()
          };
          state.record.steps.push(stepRecord);
          state.stepMetaMap.set(stepRecord, { startMs, endMs: startMs + dur, category: String(step.category || '') });
        }
        if (!stepRecord) return;

        const dur = typeof step.duration === 'number' ? Math.max(0, Math.round(step.duration)) : 0;
        stepRecord.durationMs = dur;
        const startMs = step.startTime instanceof Date ? step.startTime.getTime() : Date.now() - dur;
        stepRecord.finishedAt = new Date(startMs + dur).toISOString();
        const meta = state.stepMetaMap.get(stepRecord);
        if (meta) {
          meta.startMs = startMs;
          meta.endMs = startMs + dur;
        }

        if (step.error) {
          stepRecord.status = 'failed';
          const rawMsg = stripAnsi(step.error.message || step.error.value || String(step.error));
          stepRecord.errorMessage = truncate(rawMsg, MAX_ERROR_CHARS);
          if (stepRecord.diagnostics.assertion) {
            stepRecord.diagnostics.assertion.passed = false;
            stepRecord.diagnostics.assertion.message = stepRecord.errorMessage;
          }
        }

        const idx = state.activeStepStack.lastIndexOf(stepRecord);
        if (idx >= 0) state.activeStepStack.splice(idx, 1);
      }

      onStdOut(chunk, test) {
        this._recordStdIO(chunk, test, 'log');
      }

      onStdErr(chunk, test) {
        this._recordStdIO(chunk, test, 'error');
      }

      _recordStdIO(chunk, test, level) {
        if (!test) return;
        const state = this.activeByTest.get(test);
        if (!state) return;
        const text = stripAnsi(Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk || '')).trim();
        if (!text) return;
        const entry = {
          id: genId(),
          level,
          message: truncate(text, MAX_CONSOLE_CHARS),
          timestamp: new Date().toISOString(),
          sourceURL: null,
          lineNumber: null
        };
        const currentStep = state.activeStepStack.length > 0
          ? state.activeStepStack[state.activeStepStack.length - 1]
          : (state.record.steps.length > 0 ? state.record.steps[state.record.steps.length - 1] : null);
        if (currentStep) {
          currentStep.diagnostics.consoleEntries.push(entry);
        } else {
          state.pendingConsole.push(entry);
        }
      }

      onTestEnd(test, result) {
        const state = this.activeByTest.get(test);
        if (!state) return;
        const record = state.record;

        record.status = mapStatus(result && result.status);
        record.durationMs = (result && typeof result.duration === 'number') ? Math.max(0, Math.round(result.duration)) : 0;
        const startMs = (result && result.startTime instanceof Date) ? result.startTime.getTime() : Date.now() - record.durationMs;
        record.finishedAt = new Date(startMs + record.durationMs).toISOString();

        const primaryError = (result && result.error) || (result && Array.isArray(result.errors) ? result.errors[0] : null);
        if (primaryError) {
          const msg = stripAnsi(primaryError.message || primaryError.value || String(primaryError));
          const stack = stripAnsi(primaryError.stack || msg);
          record.errorMessage = truncate(msg, MAX_ERROR_CHARS);
          record.errorStack = truncate(stack, MAX_ERROR_CHARS);
        }

        // Ensure at least one step exists if attachments or errors occurred without explicit steps
        const attachments = (result && Array.isArray(result.attachments)) ? result.attachments : [];
        if (attachments.length > 0 && record.steps.length === 0) {
          const fallbackStep = {
            text: record.scenarioTitle,
            depth: 0,
            status: record.status === 'failed' ? 'failed' : 'passed',
            durationMs: record.durationMs,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            targetSelector: null,
            errorMessage: record.errorMessage,
            diagnostics: createEmptyDiagnostics()
          };
          record.steps.push(fallbackStep);
          state.stepMetaMap.set(fallbackStep, { startMs, endMs: startMs + record.durationMs, category: '' });
        }

        // 1. Parse Playwright trace.zip attachments for screencast screenshots, DOM snapshots,
        //    bounding boxes, console/pageerror logs, and API/browser HTTP exchanges.
        for (const att of attachments) {
          if (att && att.path && (att.name === 'trace' || String(att.contentType || '').toLowerCase() === 'application/zip' || String(att.path).endsWith('.zip'))) {
            enrichRecordFromTraceZip(record, state.stepMetaMap, att.path);
          }
        }

        // 2. Attach direct image attachments (e.g. failure screenshots) as well
        if (attachments.length > 0 && record.steps.length > 0) {
          const targetStep = record.steps.find((s) => s.status === 'failed') || record.steps[record.steps.length - 1];
          for (const att of attachments) {
            const dataURI = attachmentToDataURI(att);
            if (dataURI) {
              if (!targetStep.diagnostics.afterScreenshotDataURI) {
                targetStep.diagnostics.afterScreenshotDataURI = dataURI;
              } else if (!targetStep.diagnostics.beforeScreenshotDataURI) {
                targetStep.diagnostics.beforeScreenshotDataURI = targetStep.diagnostics.afterScreenshotDataURI;
                targetStep.diagnostics.afterScreenshotDataURI = dataURI;
              }
            }
          }
        }

        // 3. Link API assertions to their preceding Playwright APIRequestContext exchange
        linkApiAssertions(record);

        if (state.pendingConsole.length > 0 && record.steps.length > 0) {
          record.steps[record.steps.length - 1].diagnostics.consoleEntries.push(...state.pendingConsole.splice(0));
        }

        this.flushSync();
      }

      onEnd() {
        this.flushSync();
      }

      flushSync() {
        if (!this.outputDir || !this.workerFile) return;
        try {
          fs.mkdirSync(this.outputDir, { recursive: true });
          const payload = {
            version: 1,
            workerPid: process.pid,
            scenarios: this.scenarios
          };
          const tmpFile = `${this.workerFile}.tmp`;
          fs.writeFileSync(tmpFile, JSON.stringify(payload), 'utf8');
          fs.renameSync(tmpFile, this.workerFile);
        } catch {}
      }
    }

    module.exports = CeptraPlaywrightTimeTravelReporter;
    """#

    /// Ensures the zero-dependency Playwright Test reporter exists in a whitespace-free directory
    /// and returns its file URL.
    public static func ensureReporterFileURL(baseDirectory: URL? = nil) -> URL? {
        let candidateBase = baseDirectory ?? FileManager.default.temporaryDirectory
        let safeBase: URL
        if candidateBase.path.contains(" ") {
            safeBase = URL(fileURLWithPath: "/tmp", isDirectory: true)
        } else {
            safeBase = candidateBase
        }

        let dir = safeBase.appendingPathComponent(directoryName, isDirectory: true)
        let reporterURL = dir.appendingPathComponent(reporterFileName)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: reporterURL, encoding: .utf8)) != reporterScriptSource {
                try reporterScriptSource.write(to: reporterURL, atomically: true, encoding: .utf8)
            }
            return reporterURL
        } catch {
            return nil
        }
    }
}
