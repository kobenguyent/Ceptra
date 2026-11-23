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

    const MAX_ATTACHMENT_BYTES = 1536 * 1024;
    const MAX_ERROR_CHARS = 8192;
    const MAX_CONSOLE_CHARS = 4096;
    const ANSI_RE = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;

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

    function extractFeatureAndTitle(test, multiProject) {
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

      if (multiProject && projectName) {
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
        this.multiProject = false;
        this.scenarios = [];
        this.activeByTest = new WeakMap();
      }

      onBegin(config) {
        if (config && Array.isArray(config.projects) && config.projects.length > 1) {
          this.multiProject = true;
        }
      }

      onTestBegin(test, result) {
        const meta = extractFeatureAndTitle(test, this.multiProject);
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
          activeStepStack: [],
          pendingConsole: []
        });
      }

      onStepBegin(test, _result, step) {
        const state = this.activeByTest.get(test);
        if (!state || !step) return;

        const category = String(step.category || '');
        // Skip noisy internal Playwright fixture setup unless it errors in onStepEnd
        if (category === 'fixture' || category === 'pw:api:internal') return;

        let depth = 0;
        let p = step.parent;
        while (p) {
          if (String(p.category || '') !== 'fixture') depth++;
          p = p.parent;
        }

        const title = String(step.title || 'Step');
        const startDate = (step.startTime instanceof Date) ? step.startTime : new Date();
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
            method: title.split('(')[0].trim() || 'expect',
            passed: true,
            expected: null,
            actual: null,
            message: null,
            relatedRequestId: null
          };
        }

        if (title.startsWith('page.goto(')) {
          const m = title.match(/page\.goto\((['"`])([^'"`\n]+)\1/);
          if (m) stepRecord.diagnostics.pageURL = m[2];
        }

        if (state.pendingConsole.length > 0) {
          stepRecord.diagnostics.consoleEntries.push(...state.pendingConsole.splice(0));
        }

        state.record.steps.push(stepRecord);
        state.stepMap.set(step, stepRecord);
        state.activeStepStack.push(stepRecord);
      }

      onStepEnd(test, _result, step) {
        const state = this.activeByTest.get(test);
        if (!state || !step) return;

        let stepRecord = state.stepMap.get(step);
        if (!stepRecord && step.error) {
          // Promote failed fixture/internal step so failure diagnostics are never lost
          stepRecord = {
            text: String(step.title || 'Fixture step'),
            depth: 0,
            status: 'failed',
            durationMs: typeof step.duration === 'number' ? Math.max(0, Math.round(step.duration)) : 0,
            startedAt: (step.startTime instanceof Date ? step.startTime : new Date()).toISOString(),
            finishedAt: new Date().toISOString(),
            targetSelector: null,
            errorMessage: null,
            diagnostics: createEmptyDiagnostics()
          };
          state.record.steps.push(stepRecord);
        }
        if (!stepRecord) return;

        const dur = typeof step.duration === 'number' ? Math.max(0, Math.round(step.duration)) : 0;
        stepRecord.durationMs = dur;
        const startMs = step.startTime instanceof Date ? step.startTime.getTime() : Date.now() - dur;
        stepRecord.finishedAt = new Date(startMs + dur).toISOString();

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

        // Attach any screenshots & trace metadata from Playwright result.attachments
        const attachments = (result && Array.isArray(result.attachments)) ? result.attachments : [];
        if (attachments.length > 0) {
          if (record.steps.length === 0) {
            record.steps.push({
              text: record.scenarioTitle,
              depth: 0,
              status: record.status === 'failed' ? 'failed' : 'passed',
              durationMs: record.durationMs,
              startedAt: record.startedAt,
              finishedAt: record.finishedAt,
              targetSelector: null,
              errorMessage: record.errorMessage,
              diagnostics: createEmptyDiagnostics()
            });
          }
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
            } else if (att && att.name === 'trace' && att.path) {
              targetStep.diagnostics.consoleEntries.push({
                id: genId(),
                level: 'info',
                message: `Playwright Trace saved: ${att.path}`,
                timestamp: new Date().toISOString(),
                sourceURL: null,
                lineNumber: null
              });
            }
          }
        }

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
