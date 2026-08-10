'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

test('registerHooks patches every resolved dockerode 5.x copy, not the shim dependency tree', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chalk-register-hooks-'));
  try {
    const copies = ['one/node_modules/dockerode', 'two/node_modules/dockerode'];
    for (const relative of copies) {
      const root = path.join(dir, relative);
      fs.mkdirSync(path.join(root, 'lib'), { recursive: true });
      fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ name: 'dockerode', version: '5.0.1' }));
      fs.writeFileSync(path.join(root, 'lib/image.js'), [
        'function Image() {}',
        'Image.prototype.push = function originalPush() { return Promise.resolve(); };',
        'module.exports = Image;',
        '',
      ].join('\n'));
    }
    const oldRoot = path.join(dir, 'old/node_modules/dockerode');
    fs.mkdirSync(path.join(oldRoot, 'lib'), { recursive: true });
    fs.writeFileSync(path.join(oldRoot, 'package.json'), JSON.stringify({ name: 'dockerode', version: '4.0.9' }));
    fs.writeFileSync(path.join(oldRoot, 'lib/image.js'), 'function Image() {}\nImage.prototype.push = function originalPush() {};\nmodule.exports = Image;\n');
    const probe = path.join(dir, 'probe.cjs');
    fs.writeFileSync(probe, [
      "const path = require('node:path');",
      "for (const copy of ['one', 'two']) {",
      "  const Image = require(path.join(process.cwd(), copy, 'node_modules/dockerode/lib/image.js'));",
      "  const symbols = Object.getOwnPropertySymbols(Image.prototype.push).map(String);",
      "  if (!symbols.some(s => s.includes('chalk.dockerode.postPush.patched.v1'))) { console.error(copy, symbols); process.exit(2); }",
      "}",
      "const OldImage = require(path.join(process.cwd(), 'old/node_modules/dockerode/lib/image.js'));",
      "if (Object.getOwnPropertySymbols(OldImage.prototype.push).length !== 0) process.exit(3);",
      '',
    ].join('\n'));

    const preload = path.resolve(__dirname, '..', '..', '..', 'src', 'dockerode_post_push', 'register.cjs');
    const result = spawnSync(process.execPath, [`--require=${preload}`, probe], {
      cwd: dir,
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
