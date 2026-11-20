import Foundation

/// Provides a lightweight, zero-dependency Node.js ESM loader hook (`--import`) that:
/// 1. Uses synchronous in-thread `module.registerHooks` (Node 22.15+/24/26) with automatic fallback
///    to `module.register` on older Node versions — avoiding loader-worker error serialization that
///    marks `ERR_MODULE_NOT_FOUND`'s `.stack` property read-only (which breaks CodeceptJS `fixErrorStack`
///    inside `run-workers`) and eliminating `DEP0205` deprecation warnings.
/// 2. Resolves extensionless TypeScript/JS relative imports (e.g. `../../services/keycloak.api` -> `.ts`,
///    directory `/index.ts`, `.js` -> `.ts` remapping, and `tsconfig.json` `paths`/`baseUrl` aliases)
///    when native Node ESM resolution fails inside main or `worker_threads` worker runs.
/// 3. Resolves named imports from CommonJS `node_modules` packages whose exports use
///    `Object.defineProperty` getters, `Object.assign`, or `__exportStar` (such as `uuid` v3/v7/v8).
public enum NodeCompatLoader {
    private static let directoryName = "ceptra-node-compat-v1"
    private static let preloadFileName = "ceptra-cjs-interop-preload.mjs"
    private static let hookFileName = "ceptra-cjs-interop-hook.mjs"

    public static let preloadScriptSource: String = """
    import * as mod from 'node:module';
    import { resolveSync, loadSync } from './\(hookFileName)';
    if (typeof mod.registerHooks === 'function') {
      mod.registerHooks({ resolve: resolveSync, load: loadSync });
    } else if (typeof mod.register === 'function') {
      mod.register(new URL('./\(hookFileName)', import.meta.url));
    }
    """

    public static let hookScriptSource: String = """
    import fs from 'node:fs';
    import path from 'node:path';
    import { createRequire } from 'node:module';
    import { fileURLToPath, pathToFileURL } from 'node:url';

    const JS_IDENT = /^[A-Za-z_$][\\w$]*$/;
    const RESERVED = new Set([
      'default', 'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
      'delete', 'do', 'else', 'enum', 'export', 'extends', 'false', 'finally', 'for',
      'function', 'if', 'import', 'in', 'instanceof', 'new', 'null', 'return', 'super',
      'switch', 'this', 'throw', 'true', 'try', 'typeof', 'var', 'void', 'while', 'with',
      'yield', 'let', 'static', 'implements', 'interface', 'package', 'private', 'protected',
      'public', 'await', '__esModule', 'constructor', 'toString', 'valueOf', '__proto__'
    ]);
    const FN_BUILTINS = new Set(['length', 'name', 'prototype', 'arguments', 'caller']);
    const SKIP_PACKAGES = /\\/node_modules\\/(?:codeceptjs|mocha|playwright|playwright-core|@playwright|puppeteer|puppeteer-core|webdriverio|appium|tsx|esbuild|typescript|@esbuild)\\//;
    const PROBE_EXTS = ['.ts', '.mts', '.cts', '.tsx', '.js', '.mjs', '.cjs'];
    const baseRequire = createRequire(import.meta.url);
    const tsConfigCache = new Map();

    function isRegularFile(filePath) {
      try {
        return fs.statSync(filePath).isFile();
      } catch {
        return false;
      }
    }

    function isDirectoryPath(dirPath) {
      try {
        return fs.statSync(dirPath).isDirectory();
      } catch {
        return false;
      }
    }

    function findExistingFile(basePath) {
      const lower = basePath.toLowerCase();
      // Map ESM `.js`/`.mjs`/`.cjs` specifiers to sibling `.ts` sources when compiled JS isn't emitted
      if (lower.endsWith('.js') || lower.endsWith('.mjs') || lower.endsWith('.cjs')) {
        const stem = basePath.slice(0, -path.extname(basePath).length);
        for (const tsExt of ['.ts', '.mts', '.cts', '.tsx']) {
          if (isRegularFile(stem + tsExt)) return stem + tsExt;
        }
      }
      // Probe file extensions before directory index (handles both `foo` -> `foo.ts` and dotted stems `foo.api` -> `foo.api.ts`)
      for (const ext of PROBE_EXTS) {
        if (isRegularFile(basePath + ext)) return basePath + ext;
      }
      // Directory index fallback (`./dir` -> `./dir/index.ts`)
      if (isDirectoryPath(basePath)) {
        for (const ext of PROBE_EXTS) {
          const idx = path.join(basePath, 'index' + ext);
          if (isRegularFile(idx)) return idx;
        }
      }
      return null;
    }

    function stripJsonCommentsAndTrailingCommas(raw) {
      let out = '';
      let inStr = false;
      let escaped = false;
      for (let i = 0; i < raw.length; i++) {
        const ch = raw[i];
        const next = raw[i + 1];
        if (inStr) {
          out += ch;
          if (escaped) {
            escaped = false;
          } else if (ch === '\\\\') {
            escaped = true;
          } else if (ch === '"') {
            inStr = false;
          }
          continue;
        }
        if (ch === '"') {
          inStr = true;
          out += ch;
          continue;
        }
        if (ch === '/' && next === '/') {
          while (i < raw.length && raw[i] !== '\\n') i++;
          out += '\\n';
          continue;
        }
        if (ch === '/' && next === '*') {
          i += 2;
          while (i < raw.length && !(raw[i] === '*' && raw[i + 1] === '/')) i++;
          i++;
          continue;
        }
        out += ch;
      }
      return out.replace(/,\\s*([}\\]])/g, '$1');
    }

    function findNearestTsConfig(startDir) {
      if (tsConfigCache.has(startDir)) return tsConfigCache.get(startDir);
      let dir = startDir;
      const visited = [];
      let found = null;
      while (true) {
        if (tsConfigCache.has(dir)) {
          found = tsConfigCache.get(dir);
          break;
        }
        visited.push(dir);
        const candidate = path.join(dir, 'tsconfig.json');
        if (isRegularFile(candidate)) {
          try {
            const parsed = JSON.parse(stripJsonCommentsAndTrailingCommas(fs.readFileSync(candidate, 'utf8')));
            found = { configDir: dir, compilerOptions: parsed?.compilerOptions || {} };
          } catch {
            found = null;
          }
          break;
        }
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
      }
      for (const v of visited) tsConfigCache.set(v, found);
      return found;
    }

    function resolveFallbackPath(specifier, parentURL) {
      if (!parentURL || !parentURL.startsWith('file://') || parentURL.includes('/node_modules/')) {
        return null;
      }
      if (!specifier || specifier.startsWith('node:') || specifier.startsWith('data:') || specifier.startsWith('file:')) {
        return null;
      }
      let parentDir;
      try {
        parentDir = path.dirname(fileURLToPath(parentURL));
      } catch {
        return null;
      }

      if (specifier.startsWith('./') || specifier.startsWith('../') || specifier.startsWith('/')) {
        const basePath = specifier.startsWith('/') ? specifier : path.resolve(parentDir, specifier);
        return findExistingFile(basePath);
      }

      // Check tsconfig.json paths / baseUrl aliases
      const tsInfo = findNearestTsConfig(parentDir);
      if (!tsInfo) return null;
      const { configDir, compilerOptions } = tsInfo;
      const baseDir = compilerOptions.baseUrl ? path.resolve(configDir, compilerOptions.baseUrl) : configDir;

      if (compilerOptions.paths && typeof compilerOptions.paths === 'object') {
        for (const [pattern, targets] of Object.entries(compilerOptions.paths)) {
          if (!Array.isArray(targets) || targets.length === 0) continue;
          const starIdx = pattern.indexOf('*');
          let matchedWildcard = null;
          if (starIdx === -1) {
            if (specifier === pattern) matchedWildcard = '';
          } else {
            const prefix = pattern.slice(0, starIdx);
            const suffix = pattern.slice(starIdx + 1);
            if (specifier.startsWith(prefix) && specifier.endsWith(suffix) && specifier.length >= prefix.length + suffix.length) {
              matchedWildcard = specifier.slice(prefix.length, specifier.length - suffix.length);
            }
          }
          if (matchedWildcard === null) continue;
          for (const target of targets) {
            if (typeof target !== 'string') continue;
            const expanded = target.replace('*', matchedWildcard);
            const candidateBase = path.resolve(baseDir, expanded);
            if (isRegularFile(candidateBase)) return candidateBase;
            const found = findExistingFile(candidateBase);
            if (found) return found;
          }
        }
      }

      if (compilerOptions.baseUrl) {
        const candidateBase = path.resolve(baseDir, specifier);
        if (isRegularFile(candidateBase)) return candidateBase;
        return findExistingFile(candidateBase);
      }
      return null;
    }

    function maybeWrapCommonJSResult(url, result) {
      if (!result || result.format !== 'commonjs' || !url.startsWith('file://')) {
        return result;
      }
      if (!url.includes('/node_modules/') || SKIP_PACKAGES.test(url)) {
        return result;
      }

      try {
        const filePath = fileURLToPath(url);
        const rawSource = fs.readFileSync(filePath, 'utf8');
        const needsInterop =
          rawSource.includes('Object.defineProperty(exports') ||
          rawSource.includes('Object.defineProperty(module.exports') ||
          rawSource.includes('Object.assign(exports') ||
          rawSource.includes('Object.assign(module.exports') ||
          rawSource.includes('__exportStar') ||
          rawSource.includes('__reExport') ||
          /module\\.exports\\s*=/.test(rawSource);

        if (!needsInterop) {
          return result;
        }

        const loaded = baseRequire(filePath);
        if (!loaded || (typeof loaded !== 'object' && typeof loaded !== 'function')) {
          return result;
        }

        const names = new Set();
        for (const key of Object.keys(loaded)) {
          if (JS_IDENT.test(key) && !RESERVED.has(key)) {
            names.add(key);
          }
        }
        for (const key of Object.getOwnPropertyNames(loaded)) {
          if (JS_IDENT.test(key) && !RESERVED.has(key) && !FN_BUILTINS.has(key)) {
            names.add(key);
          }
        }

        if (names.size === 0) {
          return result;
        }

        const safePath = JSON.stringify(filePath);
        const namedExports = Array.from(names)
          .map(n => `export const ${n} = __mod[${JSON.stringify(n)}];`)
          .join('\\n');

        return {
          format: 'module',
          shortCircuit: true,
          source: `import { createRequire as __cr } from 'node:module';\\nconst __mod = __cr(import.meta.url)(${safePath});\\nexport default __mod;\\n${namedExports}\\n`
        };
      } catch {
        return result;
      }
    }

    // Synchronous hooks for Node 22.15+ / 24+ / 26+ `module.registerHooks`
    export function resolveSync(specifier, context, nextResolve) {
      try {
        return nextResolve(specifier, context);
      } catch (err) {
        const fallbackPath = resolveFallbackPath(specifier, context?.parentURL);
        if (fallbackPath) {
          return nextResolve(pathToFileURL(fallbackPath).href, context);
        }
        throw err;
      }
    }

    export function loadSync(url, context, nextLoad) {
      const result = nextLoad(url, context);
      return maybeWrapCommonJSResult(url, result);
    }

    // Legacy async hooks for older Node versions falling back to `module.register`
    export async function resolve(specifier, context, nextResolve) {
      try {
        return await nextResolve(specifier, context);
      } catch (err) {
        const fallbackPath = resolveFallbackPath(specifier, context?.parentURL);
        if (fallbackPath) {
          return await nextResolve(pathToFileURL(fallbackPath).href, context);
        }
        throw err;
      }
    }

    export async function load(url, context, nextLoad) {
      const result = await nextLoad(url, context);
      return maybeWrapCommonJSResult(url, result);
    }
    """

    /// Ensures the Node ESM/CJS interop loader scripts exist in a whitespace-free directory
    /// (required because `NODE_OPTIONS` tokenizes on whitespace) and returns the preload `file://` URL.
    public static func ensurePreloadFileURL(baseDirectory: URL? = nil) -> URL? {
        let candidateBase = baseDirectory ?? FileManager.default.temporaryDirectory
        let safeBase: URL
        if candidateBase.path.contains(" ") {
            safeBase = URL(fileURLWithPath: "/tmp", isDirectory: true)
        } else {
            safeBase = candidateBase
        }

        let dir = safeBase.appendingPathComponent(directoryName, isDirectory: true)
        let preloadURL = dir.appendingPathComponent(preloadFileName)
        let hookURL = dir.appendingPathComponent(hookFileName)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: hookURL, encoding: .utf8)) != hookScriptSource {
                try hookScriptSource.write(to: hookURL, atomically: true, encoding: .utf8)
            }
            if (try? String(contentsOf: preloadURL, encoding: .utf8)) != preloadScriptSource {
                try preloadScriptSource.write(to: preloadURL, atomically: true, encoding: .utf8)
            }
            return preloadURL
        } catch {
            return nil
        }
    }

    /// Appends `--import <preloadFileURL>` to `NODE_OPTIONS` without duplicating or clobbering existing flags.
    public static func mergedNodeOptions(existing: String?, preloadFileURL: URL) -> String {
        let flag = "--import \(preloadFileURL.absoluteString)"
        let trimmed = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return flag
        }
        if trimmed.contains(preloadFileName) {
            return trimmed
        }
        return "\(trimmed) \(flag)"
    }
}
