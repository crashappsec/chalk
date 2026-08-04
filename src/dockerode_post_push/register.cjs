'use strict';

// Loaded with --require. registerHooks is synchronous, so it applies to both
// subsequent require() and import() calls without racing application startup.
const fs = require('node:fs');
const path = require('node:path');
const { fileURLToPath } = require('node:url');
const { registerHooks } = require('node:module');
const runtime = require('./runtime.cjs');

const PATCH_SYMBOL = Symbol.for('chalk.dockerode.postPush.patch.v1');
globalThis[PATCH_SYMBOL] = runtime.patchImage;

const packageCache = new Map();

function dockerodePackageFor(filename) {
  let dir = path.dirname(filename);
  while (dir !== path.dirname(dir)) {
    if (packageCache.has(dir)) return packageCache.get(dir);
    const manifest = path.join(dir, 'package.json');
    try {
      const parsed = JSON.parse(fs.readFileSync(manifest, 'utf8'));
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

const [nodeMajor, nodeMinor] = process.versions.node.split('.').map(Number);
const supportedNode = (nodeMajor === 22 && nodeMinor >= 15) || nodeMajor === 24;
if (!supportedNode || typeof registerHooks !== 'function') {
  process.stderr.write(`[chalk-dockerode] unsupported Node ${process.versions.node}; instrumentation skipped\n`);
} else registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context);
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
  },
});
