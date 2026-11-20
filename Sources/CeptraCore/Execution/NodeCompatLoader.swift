import Foundation

/// Provides a lightweight, zero-dependency Node.js ESM loader hook (`--import`) that resolves
/// named imports from CommonJS `node_modules` packages whose exports use `Object.defineProperty`
/// getters, `Object.assign`, or `__exportStar` (such as `uuid` v3/v7/v8 and Babel/TS-compiled CJS libraries).
///
/// Without this interop hook, running CodeceptJS 4.x (ESM / `tsx/esm`) against a CJS-only `uuid`
/// package fails with: `SyntaxError: The requested module 'uuid' does not provide an export named 'v4'`.
public enum NodeCompatLoader {
    private static let directoryName = "ceptra-node-compat-v1"
    private static let preloadFileName = "ceptra-cjs-interop-preload.mjs"
    private static let hookFileName = "ceptra-cjs-interop-hook.mjs"

    public static let preloadScriptSource: String = """
    import * as mod from 'node:module';
    if (typeof mod.register === 'function') {
      mod.register(new URL('./\(hookFileName)', import.meta.url));
    }
    """

    public static let hookScriptSource: String = """
    import fs from 'node:fs';
    import { createRequire } from 'node:module';
    import { fileURLToPath } from 'node:url';

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
    const baseRequire = createRequire(import.meta.url);

    export async function load(url, context, nextLoad) {
      const result = await nextLoad(url, context);
      if (result.format !== 'commonjs' || !url.startsWith('file://')) {
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
