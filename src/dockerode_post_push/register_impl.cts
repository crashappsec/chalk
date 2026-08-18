// registerHooks is synchronous, so it applies to both subsequent require()
// and import() calls without racing application startup.
import fs = require('node:fs');
import path = require('node:path');
import { fileURLToPath } from 'node:url';
import { registerHooks } from 'node:module';
import type { LoadHookSync } from 'node:module';
const runtime = require('./runtime.cjs') as typeof import('./runtime.cjs');
const { classifyNodeSupport, diagnosticForNodeSupport } = require('./node_support.cjs') as typeof import('./node_support.cjs');

interface DockerodePackage {
  root: string;
  version: string;
}

interface PackageManifest {
  name?: unknown;
  version?: unknown;
}

const PATCH_SYMBOL = Symbol.for('chalk.dockerode.postPush.patch.v1');
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

const nodeSupport = classifyNodeSupport(process.versions.node, registerHooks);
const nodeSupportDiagnostic = diagnosticForNodeSupport(nodeSupport);
if (nodeSupportDiagnostic) process.stderr.write(`${nodeSupportDiagnostic}\n`);
if (nodeSupport.enabled) registerHooks({
  load(url: string, context: Parameters<LoadHookSync>[1], nextLoad: Parameters<LoadHookSync>[2]) {
    const loaded = nextLoad(url, context);
    try {
      if (process.env.CHALK_DOCKERODE_HOOK_DEBUG) {
        process.stderr.write(`[chalk-hook-debug] ${loaded.format} ${url}\n`);
      }
      if (!url.startsWith('file:')) return loaded;

      const filename = fileURLToPath(url);
      if (path.basename(filename) !== 'image.js' || path.basename(path.dirname(filename)) !== 'lib') {
        return loaded;
      }

      const pkg = dockerodePackageFor(filename);
      if (!pkg || !pkg.version.startsWith('5.')) return loaded;
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
