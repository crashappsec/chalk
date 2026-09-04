import assert = require('node:assert/strict');
import fs = require('node:fs');
import os = require('node:os');
import path = require('node:path');
import { Readable } from 'node:stream';
import test = require('node:test');
import Dockerode = require('dockerode');
import { patchImage } from '../../../src/dockerode_post_push/runtime.cjs';

const Image = require('dockerode/lib/image');

const DIGEST = `sha256:${'b'.repeat(64)}`;
const BODY = Buffer.from(`${JSON.stringify({ status: 'Pushed' })}\n${JSON.stringify({ aux: { Digest: DIGEST } })}\n`);

function isObservedModem(value: unknown): value is { socketPath: unknown; getSocketPath?: unknown } {
  return typeof value === 'object' && value !== null && 'socketPath' in value;
}

function terminalDigest(frames: unknown[]): unknown {
  const terminal = frames.at(-1);
  if (typeof terminal !== 'object' || terminal === null || !('aux' in terminal)) return undefined;
  const aux = terminal.aux;
  return typeof aux === 'object' && aux !== null && 'Digest' in aux ? aux.Digest : undefined;
}

test('published Dockerode 3.3.5 reaches post-push through its real modem shape', async () => {
  assert.equal(require('dockerode/package.json').version, '3.3.5');
  assert.equal(require('docker-modem/package.json').version, '3.0.8');

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chalk-real-dockerode-'));
  const hook = path.join(dir, 'chalk-hook');
  const payloads = path.join(dir, 'payloads.jsonl');
  const diagnostics = path.join(dir, 'diagnostics.jsonl');
  const prior = { ...process.env };
  fs.writeFileSync(hook, [
    '#!/usr/bin/env node',
    "const fs = require('node:fs');",
    "let input = '';",
    "process.stdin.on('data', chunk => { input += chunk; });",
    "process.stdin.on('end', () => {",
    "  fs.appendFileSync(process.env.TEST_PAYLOADS, input + '\\n');",
    "  const payload = JSON.parse(input);",
    "  process.stdout.write(JSON.stringify({ schema: 'chalk-docker-post-push-result/v1', status: 'complete', operationId: payload.operationId }) + '\\n');",
    '});',
    '',
  ].join('\n'), { mode: 0o700 });

  process.env.CHALK_DOCKERODE_TEST_PLATFORM = 'linux';
  process.env.CHALK_DOCKERODE_CHALK = hook;
  process.env.CHALK_DOCKERODE_LOG = diagnostics;
  process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = '5000';
  process.env.TEST_PAYLOADS = payloads;

  const originalPush = Image.prototype.push;
  try {
    const docker = new Dockerode();
    assert.equal(isObservedModem(docker.modem), true);
    if (!isObservedModem(docker.modem)) throw new Error('Docker Modem shape was not observed');
    assert.equal(docker.modem.socketPath, '/var/run/docker.sock');
    assert.equal(typeof docker.modem.getSocketPath, 'undefined');

    let enginePushes = 0;
    docker.modem.dial = ((_options: unknown, callback: (error: Error | null, value: Readable) => void) => {
      enginePushes += 1;
      process.nextTick(() => callback(null, Readable.from([BODY])));
    }) as typeof docker.modem.dial;

    patchImage(Image, { version: '3.3.5', packageRoot: path.dirname(require.resolve('dockerode/package.json')) });
    patchImage(Image, { version: '3.3.5', packageRoot: path.dirname(require.resolve('dockerode/package.json')) });
    const stream = await docker.getImage('registry.example/team/app:old').push({
      tag: 'release-1',
      authconfig: {
        username: 'user',
        password: 'secret',
        serveraddress: 'registry.example',
      },
    });
    const frames = await new Promise<unknown[]>((resolve, reject) => {
      docker.modem.followProgress(stream, (error, found) => error ? reject(error) : resolve(found));
    });

    assert.equal(enginePushes, 1);
    assert.equal(terminalDigest(frames), DIGEST);
    assert.equal(
      fs.existsSync(payloads),
      true,
      fs.existsSync(diagnostics) ? fs.readFileSync(diagnostics, 'utf8') : 'no diagnostic was written',
    );
    assert.equal(JSON.parse(fs.readFileSync(payloads, 'utf8')).digest, DIGEST);
    assert.match(fs.readFileSync(diagnostics, 'utf8'), /"code":"posthook_complete"/);
  } finally {
    Image.prototype.push = originalPush;
    for (const key of Object.keys(process.env)) {
      if (!(key in prior)) delete process.env[key];
    }
    Object.assign(process.env, prior);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
