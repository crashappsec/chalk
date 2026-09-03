// registerHooks is synchronous, so it applies to both subsequent require()
// and import() calls without racing application startup.
import fs = require('node:fs');
import path = require('node:path');
import { fileURLToPath } from 'node:url';
import type { LoadHookSync } from 'node:module';
const runtime = require('./runtime.cjs') as typeof import('./runtime.cjs');
const { classifyNodeSupport, diagnosticForNodeSupport } = require('./node_support.cjs') as typeof import('./node_support.cjs');

interface LegacyModule {
  exports: unknown;
}

type LegacyJsLoader = (module: LegacyModule, filename: string) => void;

interface NodeModuleApi {
  _extensions?: Record<string, LegacyJsLoader | undefined>;
  registerHooks?: (hooks: { load: LoadHookSync }) => unknown;
}

const nodeModule = require('node:module') as NodeModuleApi;

interface DockerodePackage {
  root: string;
  version: string;
}

interface PackageManifest {
  name?: unknown;
  version?: unknown;
}

const PATCH_SYMBOL = Symbol.for('chalk.dockerode.postPush.patch.v1');
const LEGACY_LOADER_SYMBOL = Symbol.for('chalk.dockerode.postPush.legacyLoader.v1');
(globalThis as typeof globalThis & Record<symbol, unknown>)[PATCH_SYMBOL] = runtime.patchImage;

const packageCache = new Map<string, DockerodePackage>();

function dockerodePackageFor(filename: string): DockerodePackage | null {
  let dir = path.dirname(filename);
  while (dir !== path.dirname(dir)) {
    if (packageCache.has(dir)) return packageCache.get(dir)!;
    const manifest = path.join(dir, 'package.json');
    try {
      const parsed = JSON.parse(fs.readFileSync(manifest, 'utf8')) as PackageManifest;
      if (parsed.name === 'dockerode') {
        const found = { root: dir, version: String(parsed.version || '') };
        packageCache.set(dir, found);
        return found;
      }
    } catch (_) {
      // Most ancestor directories are not package roots.
    }
    dir = path.dirname(dir);
  }
  return null;
}

function isDockerodeImage(filename: string): boolean {
  return path.basename(filename) === 'image.js' && path.basename(path.dirname(filename)) === 'lib';
}

function installLegacyLoader(originalLoader: LegacyJsLoader): void {
  const state = globalThis as typeof globalThis & Record<symbol, unknown>;
  if (state[LEGACY_LOADER_SYMBOL]) return;
  const extensions = nodeModule._extensions;
  if (!extensions) return;
  extensions['.js'] = function chalkDockerodeLoader(module, filename) {
    originalLoader(module, filename);
    try {
      if (!isDockerodeImage(filename)) return;
      const pkg = dockerodePackageFor(filename);
      if (!pkg || !runtime.isSupportedDockerodeVersion(pkg.version)) return;
      runtime.patchImage(module.exports as Parameters<typeof runtime.patchImage>[0], pkg);
    } catch (_) {
      return;
    }
  };
  state[LEGACY_LOADER_SYMBOL] = true;
}

const legacyJsLoader = nodeModule._extensions?.['.js'];
const nodeSupport = classifyNodeSupport(process.versions.node, {
  registerHooks: nodeModule.registerHooks,
  legacyJsLoader,
});
const nodeSupportDiagnostic = diagnosticForNodeSupport(nodeSupport);
if (nodeSupportDiagnostic) process.stderr.write(`${nodeSupportDiagnostic}\n`);
if (nodeSupport.enabled && nodeSupport.loader === 'legacy' && legacyJsLoader) {
  installLegacyLoader(legacyJsLoader);
}
if (nodeSupport.enabled && nodeSupport.loader === 'hooks' && nodeModule.registerHooks) nodeModule.registerHooks({
  load(url: string, context: Parameters<LoadHookSync>[1], nextLoad: Parameters<LoadHookSync>[2]) {
    const loaded = nextLoad(url, context);
    try {
      if (process.env.CHALK_DOCKERODE_HOOK_DEBUG) {
        process.stderr.write(`[chalk-hook-debug] ${loaded.format} ${url}\n`);
      }
      if (!url.startsWith('file:')) return loaded;

      const filename = fileURLToPath(url);
      if (!isDockerodeImage(filename)) return loaded;

      const pkg = dockerodePackageFor(filename);
      if (!pkg || !runtime.isSupportedDockerodeVersion(pkg.version)) return loaded;
      if (loaded.format !== undefined && loaded.format !== 'commonjs') return loaded;

      const rawSource = loaded.source == null ? fs.readFileSync(filename) : loaded.source;
      const source = Buffer.isBuffer(rawSource)
        ? rawSource.toString('utf8')
        : String(rawSource);
      const footer = [
        '',
        ';globalThis[Symbol.for("chalk.dockerode.postPush.patch.v1")](',
        '  module.exports,',
        `  ${JSON.stringify({ packageRoot: pkg.root, version: pkg.version })}`,
        ');',
        '',
      ].join('\n');
      return { ...loaded, format: 'commonjs', source: source + footer };
    } catch (_) {
      return loaded;
    }
  },
});
