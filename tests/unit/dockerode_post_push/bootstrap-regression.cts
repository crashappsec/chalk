// This helper itself runs on Node 12, so do not use the `node:` specifier here.
import assertModule = require('assert');
import fs = require('fs');
import os = require('os');
import path = require('path');
import { spawnSync } from 'child_process';

const assert: typeof assertModule.strict = assertModule.strict;

const emittedBootstrap = path.resolve(
  __dirname,
  '..',
  '..',
  '..',
  'src',
  'dockerode_post_push',
  'register.cjs',
);

function assertBootstrapShape(source: string): void {
  const requires = [...source.matchAll(/\brequire\s*\(\s*(['"])(.*?)\1\s*\)/g)];
  assert.deepEqual(requires.map((match) => match[2]), ['./register_impl.cjs']);
  assert.doesNotMatch(source, /\b(?:__awaiter|__generator|__importDefault|__importStar)\b/);

  const executable = source
    .replace(/\/\/[^\n]*/g, '')
    .replace(/^\s*["']use strict["'];?\s*/u, '')
    .trim();
  assert.match(
    executable,
    /^try\s*\{\s*require\(['"]\.\/register_impl\.cjs['"]\);?\s*\}\s*catch\s*\(_\)\s*\{\s*\}$/u,
    'bootstrap must execute nothing outside the guarded implementation require',
  );
}

function runFailOpenCase(implementation: 'missing' | 'corrupt'): void {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chalk-bootstrap-regression-'));
  try {
    const bootstrap = path.join(dir, 'register.cjs');
    fs.copyFileSync(emittedBootstrap, bootstrap);
    if (implementation === 'corrupt') {
      fs.writeFileSync(path.join(dir, 'register_impl.cjs'), 'this is not valid javascript !!!\n');
    }
    const application = path.join(dir, 'application.cjs');
    fs.writeFileSync(application, "process.stdout.write('application-output\\n'); process.exit(37);\n");
    const result = spawnSync(process.execPath, [`--require=${bootstrap}`, application], {
      encoding: 'utf8',
    });
    assert.equal(result.status, 37, result.stderr || result.stdout);
    assert.equal(result.stdout, 'application-output\n');
    assert.equal(result.stderr, '');
  } finally {
    if (typeof fs.rmSync === 'function') fs.rmSync(dir, { recursive: true, force: true });
    else fs.rmdirSync(dir, { recursive: true });
  }
}

function verifyEmittedBootstrap(): void {
  assertBootstrapShape(fs.readFileSync(emittedBootstrap, 'utf8'));
  runFailOpenCase('missing');
  runFailOpenCase('corrupt');
}

if (require.main === module) {
  verifyEmittedBootstrap();
  process.stdout.write(`bootstrap regression passed on ${process.version}\n`);
}

export { assertBootstrapShape, runFailOpenCase, verifyEmittedBootstrap };
