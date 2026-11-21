import Foundation

/// Generates and caches a zero-dependency CodeceptJS plugin that captures per-step
/// time-travel telemetry (before/after screenshots, DOM snapshots with target highlighting,
/// HTTP/XHR/REST network traffic with credential redaction, and browser console/page errors)
/// without modifying the user's `codecept.conf.*`.
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

    const MAX_DOM_CHARS = 256 * 1024;
    const MAX_BODY_CHARS = 32 * 1024;
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
      'fillField', 'appendField', 'clearField', 'selectOption', 'checkOption',
      'uncheckOption', 'attachFile', 'focus', 'blur', 'moveCursorTo', 'scrollTo',
      'seeElement', 'dontSeeElement', 'seeElementInDOM', 'dontSeeElementInDOM',
      'seeInField', 'dontSeeInField', 'seeCheckboxIsChecked', 'dontSeeCheckboxIsChecked',
      'waitForElement', 'waitForVisible', 'waitForInvisible', 'waitForClickable',
      'waitForEnabled', 'waitForDetached', 'waitToHide', 'grabTextFrom',
      'grabTextFromAll', 'grabAttributeFrom', 'grabValueFrom', 'grabHTMLFrom',
      'grabNumberOfVisibleElements', 'pressKey', 'type', 'see', 'dontSee'
    ]);

    const TEXT_CONTENT_RE = /(?:json|text|xml|javascript|ecmascript|x-www-form-urlencoded|graphql)/i;

    function resolveCodeceptJS() {
      try {
        return require('codeceptjs');
      } catch {}
      try {
        return require(path.join(process.cwd(), 'node_modules', 'codeceptjs'));
      } catch {}
      return null;
    }

    function truncate(str, max) {
      if (typeof str !== 'string') return null;
      if (str.length <= max) return str;
      return str.slice(0, max) + '\n/* [truncated by Ceptra] */';
    }

    function redactHeaders(raw) {
      const out = {};
      if (!raw || typeof raw !== 'object') return out;
      for (const [k, v] of Object.entries(raw)) {
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

    function extractTargetSelector(step) {
      if (!step) return null;
      const method = String(step.name || step.helperMethod || '');
      const args = Array.isArray(step.args) ? step.args : [];
      if (!args.length) return null;

      // For `see("Text", "#container")`, prefer explicit 2nd locator argument if present
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
        if (typeof arg.id === 'string') return arg.id.startsWith('#') ? arg.id : '#' + arg.id;
        if (typeof arg.xpath === 'string') return arg.xpath;
        if (typeof arg.name === 'string') return `[name="${arg.name}"]`;
        if (typeof arg.pw === 'string') return arg.pw;
        if (typeof arg.value === 'string') return arg.value;
      }
      return null;
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

    async function captureScreenshot(page) {
      if (!page || typeof page.screenshot !== 'function') return null;
      try {
        let buf;
        try {
          buf = await page.screenshot({ type: 'jpeg', quality: 68 });
        } catch {
          buf = await page.screenshot();
        }
        if (!buf) return null;
        const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf, 'base64');
        if (b.length === 0) return null;
        const isPNG = b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
        const mime = isPNG ? 'image/png' : 'image/jpeg';
        return `data:${mime};base64,${b.toString('base64')}`;
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
      let currentScenario = null;
      let currentStep = null;
      const attachedPages = new WeakSet();
      const pendingTasks = new Set();

      function track(promise) {
        if (!promise || typeof promise.then !== 'function') return;
        pendingTasks.add(promise);
        promise.finally(() => pendingTasks.delete(promise));
      }

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
              id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
              method: typeof req.method === 'function' ? req.method() : 'GET',
              url: typeof req.url === 'function' ? req.url() : String(req.url || ''),
              resourceType: typeof req.resourceType === 'function' ? req.resourceType() : null,
              status: null,
              statusText: null,
              startedAt: new Date().toISOString(),
              _startMs: Date.now(),
              durationMs: null,
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
                id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
                method: req && typeof req.method === 'function' ? req.method() : 'GET',
                url: typeof res.url === 'function' ? res.url() : '',
                resourceType: req && typeof req.resourceType === 'function' ? req.resourceType() : null,
                status: null,
                statusText: null,
                startedAt: new Date().toISOString(),
                _startMs: Date.now(),
                durationMs: null,
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
              id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
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
              id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
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
              networkRequests: st.diagnostics.networkRequests.map((n) => ({
                id: n.id,
                method: n.method,
                url: n.url,
                resourceType: n.resourceType,
                status: n.status,
                statusText: n.statusText,
                startedAt: n.startedAt,
                durationMs: n.durationMs,
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

      dispatcher.on(event.test.before, (test) => {
        const active = getActivePage(container);
        if (active && active.page) attachPageListeners(active.page);

        const featureTitle = (test && test.parent && test.parent.title) ? String(test.parent.title) : 'Suite';
        const scenarioTitle = (test && test.title) ? String(test.title) : 'Scenario';
        const tags = Array.isArray(test && test.tags) ? test.tags.map(String) : [];

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
        scenarios.push(currentScenario);
      });

      dispatcher.on(event.step.before, (step) => {
        if (!currentScenario) return;
        const active = getActivePage(container);
        if (active && active.page) attachPageListeners(active.page);

        const targetSelector = extractTargetSelector(step);
        const depth = (step && step.metaStep) ? 1 : 0;
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
          diagnostics: {
            pageURL: (active && active.page && typeof active.page.url === 'function') ? active.page.url() : null,
            beforeScreenshotDataURI: null,
            afterScreenshotDataURI: null,
            domSnapshot: null,
            networkRequests: [],
            consoleEntries: []
          }
        };
        currentStep = stepRecord;
        currentScenario.steps.push(stepRecord);

        if (active && active.page) {
          track(
            captureScreenshot(active.page).then((uri) => {
              if (uri && !stepRecord.diagnostics.beforeScreenshotDataURI) {
                stepRecord.diagnostics.beforeScreenshotDataURI = uri;
              }
            })
          );
        }
      });

      dispatcher.on(event.step.failed, (step, err) => {
        if (!currentStep) return;
        currentStep.status = 'failed';
        if (err) {
          currentStep.errorMessage = err.message ? String(err.message) : String(err);
        }
      });

      dispatcher.on(event.step.after, (step) => {
        const stepRecord = currentStep;
        if (!stepRecord) return;
        stepRecord.finishedAt = new Date().toISOString();
        stepRecord.durationMs = Math.max(0, Date.now() - stepRecord._startMs);
        if (step && step.status === 'failed') {
          stepRecord.status = 'failed';
        }

        const active = getActivePage(container);
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
            })
          );
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

      dispatcher.on(event.test.after, () => {
        if (currentScenario) {
          currentScenario.finishedAt = new Date().toISOString();
          currentScenario.durationMs = Math.max(0, Date.now() - currentScenario._startMs);
        }
        currentStep = null;
        track(Promise.allSettled(Array.from(pendingTasks)).then(() => flushSync()));
      });

      dispatcher.on(event.all.result, () => {
        track(Promise.allSettled(Array.from(pendingTasks)).then(() => flushSync()));
      });

      process.on('beforeExit', () => {
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
