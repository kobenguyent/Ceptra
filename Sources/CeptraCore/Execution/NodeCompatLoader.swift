import Foundation

/// Provides a lightweight, zero-dependency Node.js ESM/CJS loader hook (`--import`) that:
/// 1. Uses synchronous in-thread `module.registerHooks` (Node 22.15+/24/26) with automatic fallback
///    to `module.register` on older Node versions — and ensures `Error.stack` remains writable on
///    resolution failures so CodeceptJS's `fixErrorStack` never crashes with
///    `TypeError: Cannot assign to read only property 'stack'` inside `run-workers`.
/// 2. Resolves complicated upstream & downstream extensionless TypeScript/JS relative imports
///    (`../../../../utils`, `../../services/keycloak.api`, `../../pages` -> `/index.ts`,
///    `.js` -> `.ts`, symlinked paths, query-string URLs, and `tsconfig.json` `paths`/`baseUrl`)
///    for both ESM `import` and dynamic CJS `require()`.
/// 3. Transpiles project `.ts`/`.tsx`/`.mts`/`.cts` files in-memory with the project's local
///    `typescript` compiler when present — erasing non-`type` interface/type imports, supporting
///    `enum` and `export =`, and providing safe `require()` / `__dirname` / `__filename` shims.
/// 4. Resolves named imports from CommonJS `node_modules` packages whose exports use
///    `Object.defineProperty` getters, `Object.assign`, or `__exportStar` (such as `uuid` v3/v7/v8).
public enum NodeCompatLoader {
    private static let directoryName = "ceptra-node-compat-v1"
    private static let preloadFileName = "ceptra-cjs-interop-preload.mjs"
    private static let hookFileName = "ceptra-cjs-interop-hook.mjs"

    public static let preloadScriptSource: String = """
    import * as mod from 'node:module';
    import { installCjsResolveFallback, resolveSync, loadSync } from './\(hookFileName)';
    installCjsResolveFallback(mod);
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
    const TS_EXTS = new Set(['.ts', '.mts', '.cts', '.tsx']);
    const baseRequire = createRequire(import.meta.url);
    const tsConfigCache = new Map();
    const tsCompilerCache = new Map();

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

    function makeStackWritable(err) {
      if (!err || typeof err !== 'object') return;
      try {
        const desc = Object.getOwnPropertyDescriptor(err, 'stack');
        if (desc && desc.writable === false && desc.configurable) {
          Object.defineProperty(err, 'stack', {
            value: desc.value,
            writable: true,
            enumerable: desc.enumerable,
            configurable: true
          });
        }
      } catch {}
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

    function getTypeScriptCompiler(fromFilePath) {
      const dir = path.dirname(fromFilePath);
      if (tsCompilerCache.has(dir)) return tsCompilerCache.get(dir);
      let ts = null;
      try {
        ts = createRequire(pathToFileURL(fromFilePath).href)('typescript');
      } catch {
        try {
          ts = createRequire(pathToFileURL(path.join(process.cwd(), 'package.json')).href)('typescript');
        } catch {
          ts = null;
        }
      }
      tsCompilerCache.set(dir, ts);
      return ts;
    }

    function resolveFallbackPath(specifier, parentURL) {
      if (!parentURL || !parentURL.startsWith('file://') || parentURL.includes('/node_modules/')) {
        return null;
      }
      if (!specifier || specifier.startsWith('node:') || specifier.startsWith('data:')) {
        return null;
      }

      let cleanSpec = specifier;
      const qIdx = cleanSpec.search(/[?#]/);
      const suffix = qIdx >= 0 ? cleanSpec.slice(qIdx) : '';
      if (qIdx >= 0) cleanSpec = cleanSpec.slice(0, qIdx);

      if (cleanSpec.startsWith('file:')) {
        try {
          const p = fileURLToPath(cleanSpec);
          const found = isRegularFile(p) ? p : findExistingFile(p);
          return found ? { filePath: found, suffix } : null;
        } catch {
          return null;
        }
      }

      let parentDir;
      try {
        parentDir = path.dirname(fileURLToPath(parentURL));
      } catch {
        return null;
      }

      if (cleanSpec.startsWith('./') || cleanSpec.startsWith('../') || cleanSpec.startsWith('/')) {
        const basePath = cleanSpec.startsWith('/') ? cleanSpec : path.resolve(parentDir, cleanSpec);
        const found = findExistingFile(basePath);
        if (found) return { filePath: found, suffix };
        try {
          const realParent = fs.realpathSync(parentDir);
          if (realParent !== parentDir) {
            const realFound = findExistingFile(path.resolve(realParent, cleanSpec));
            if (realFound) return { filePath: realFound, suffix };
          }
        } catch {}
        return null;
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
            if (cleanSpec === pattern) matchedWildcard = '';
          } else {
            const prefix = pattern.slice(0, starIdx);
            const suffixPat = pattern.slice(starIdx + 1);
            if (cleanSpec.startsWith(prefix) && cleanSpec.endsWith(suffixPat) && cleanSpec.length >= prefix.length + suffixPat.length) {
              matchedWildcard = cleanSpec.slice(prefix.length, cleanSpec.length - suffixPat.length);
            }
          }
          if (matchedWildcard === null) continue;
          for (const target of targets) {
            if (typeof target !== 'string') continue;
            const expanded = target.replace('*', matchedWildcard);
            const candidateBase = path.resolve(baseDir, expanded);
            if (isRegularFile(candidateBase)) return { filePath: candidateBase, suffix };
            const found = findExistingFile(candidateBase);
            if (found) return { filePath: found, suffix };
          }
        }
      }

      if (compilerOptions.baseUrl) {
        const candidateBase = path.resolve(baseDir, cleanSpec);
        if (isRegularFile(candidateBase)) return { filePath: candidateBase, suffix };
        const found = findExistingFile(candidateBase);
        if (found) return { filePath: found, suffix };
      }
      return null;
    }

    function unwrapRequiredModule(res) {
      if (res && typeof res === 'object' && Object.prototype.toString.call(res) === '[object Module]') {
        const keys = Object.keys(res);
        if ('default' in res && keys.every(k => k === 'default' || k === '__esModule')) {
          return res.default;
        }
        const copy = {};
        if (res.default && typeof res.default === 'object') {
          Object.assign(copy, res.default);
        }
        for (const k of keys) {
          copy[k] = res[k];
        }
        return copy;
      }
      return res;
    }

    if (typeof globalThis.__ceptraMakeRequire !== 'function') {
      globalThis.__ceptraMakeRequire = function(fromFileUrl) {
        const rawReq = createRequire(fromFileUrl);
        const fromDir = path.dirname(fileURLToPath(fromFileUrl));
        const wrapped = (id) => {
          try {
            return unwrapRequiredModule(rawReq(id));
          } catch (err) {
            if (typeof id === 'string' && (id.startsWith('./') || id.startsWith('../') || id.startsWith('/'))) {
              const base = id.startsWith('/') ? id : path.resolve(fromDir, id);
              const found = isRegularFile(base) ? base : findExistingFile(base);
              if (found) {
                return unwrapRequiredModule(rawReq(found));
              }
            }
            throw err;
          }
        };
        wrapped.resolve = rawReq.resolve;
        wrapped.cache = rawReq.cache;
        return wrapped;
      };
    }

    export function installCjsResolveFallback(modApi) {
      const ModuleClass = modApi?.Module || modApi?.default;
      const origResolve = ModuleClass?._resolveFilename;
      if (typeof origResolve !== 'function' || origResolve.__ceptraPatched) return;
      const patched = function(request, parent, isMain, options) {
        try {
          return origResolve.call(this, request, parent, isMain, options);
        } catch (err) {
          if (typeof request === 'string' && (request.startsWith('./') || request.startsWith('../') || request.startsWith('/'))) {
            const parentFile = parent && typeof parent.filename === 'string' ? parent.filename : null;
            if (!parentFile || !parentFile.includes('/node_modules/')) {
              const fromDir = parentFile ? path.dirname(parentFile) : process.cwd();
              const base = request.startsWith('/') ? request : path.resolve(fromDir, request);
              const found = findExistingFile(base);
              if (found) {
                return origResolve.call(this, found, parent, isMain, options);
              }
            }
          }
          throw err;
        }
      };
      patched.__ceptraPatched = true;
      ModuleClass._resolveFilename = patched;
    }

    function maybeTranspileProjectTypeScript(url) {
      if (!url.startsWith('file://') || url.includes('/node_modules/')) return null;
      let filePath;
      try {
        filePath = fileURLToPath(url);
      } catch {
        return null;
      }
      const lower = filePath.toLowerCase();
      if (lower.endsWith('.d.ts') || lower.endsWith('.d.mts') || lower.endsWith('.d.cts')) return null;
      const ext = path.extname(lower);
      if (!TS_EXTS.has(ext)) return null;

      const ts = getTypeScriptCompiler(filePath);
      if (!ts || typeof ts.transpileModule !== 'function') return null;

      try {
        let rawSource = fs.readFileSync(filePath, 'utf8');
        rawSource = rawSource.replace(/^(\\s*)export\\s*=\\s*/m, '$1export default ');
        const transpiled = ts.transpileModule(rawSource, {
          fileName: filePath,
          compilerOptions: {
            module: ts.ModuleKind?.ESNext ?? 99,
            target: ts.ScriptTarget?.ESNext ?? 99,
            jsx: ext === '.tsx' ? (ts.JsxEmit?.ReactJSX ?? 4) : undefined,
            esModuleInterop: true,
            allowSyntheticDefaultImports: true,
            verbatimModuleSyntax: false,
            isolatedModules: false,
            sourceMap: true,
            inlineSourceMap: true,
            inlineSources: true
          }
        });

        let code = transpiled.outputText;
        const usesRequire = /\\brequire\\s*\\(/.test(code);
        const usesDirname = /\\b__dirname\\b/.test(code);
        const usesFilename = /\\b__filename\\b/.test(code);
        const usesModuleExports = /\\b(?:module\\.exports|exports\\.)/.test(code);

        let prefix = '';
        if ((usesRequire || usesModuleExports) && !/\\b(?:const|let|var|function)\\s+require\\b/.test(code)) {
          prefix += `const require = globalThis.__ceptraMakeRequire(${JSON.stringify(pathToFileURL(filePath).href)});\\n`;
        }
        if (usesFilename && !/\\b(?:const|let|var)\\s+__filename\\b/.test(code)) {
          prefix += `const __filename = ${JSON.stringify(filePath)};\\n`;
        }
        if (usesDirname && !/\\b(?:const|let|var)\\s+__dirname\\b/.test(code)) {
          prefix += `const __dirname = ${JSON.stringify(path.dirname(filePath))};\\n`;
        }
        if (usesModuleExports && !/\\b(?:const|let|var)\\s+module\\b/.test(code)) {
          prefix += `const module = { exports: {} };\\nconst exports = module.exports;\\n`;
        }
        if (prefix) code = prefix + code;
        if (usesModuleExports && !/\\bexport\\s+default\\b/.test(code)) {
          code += '\\nexport default module.exports;\\n';
        }
        return { format: 'module', shortCircuit: true, source: code };
      } catch {
        return null;
      }
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
        const resolved = resolveFallbackPath(specifier, context?.parentURL);
        if (resolved) {
          return nextResolve(pathToFileURL(resolved.filePath).href + resolved.suffix, context);
        }
        makeStackWritable(err);
        throw err;
      }
    }

    export function loadSync(url, context, nextLoad) {
      const tsResult = maybeTranspileProjectTypeScript(url);
      if (tsResult) return tsResult;
      const result = nextLoad(url, context);
      return maybeWrapCommonJSResult(url, result);
    }

    // Legacy async hooks for older Node versions falling back to `module.register`
    export async function resolve(specifier, context, nextResolve) {
      try {
        return await nextResolve(specifier, context);
      } catch (err) {
        const resolved = resolveFallbackPath(specifier, context?.parentURL);
        if (resolved) {
          return await nextResolve(pathToFileURL(resolved.filePath).href + resolved.suffix, context);
        }
        makeStackWritable(err);
        throw err;
      }
    }

    export async function load(url, context, nextLoad) {
      const tsResult = maybeTranspileProjectTypeScript(url);
      if (tsResult) return tsResult;
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
