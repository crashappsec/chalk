'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const test = require('node:test');
const {
  createTerminalTracker,
  patchImage,
  postPushDeadline,
  repositoryWithoutTag,
  terminalDigest,
} = require('../../../src/dockerode_post_push/runtime.cjs');

const DIGEST = `sha256:${'a'.repeat(64)}`;
const BODY = Buffer.from(`${JSON.stringify({ status: 'Pushed' })}\r\n${JSON.stringify({ aux: { Digest: DIGEST } })}\r\n`);

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chalk-dockerode-test-'));
  const payloads = path.join(dir, 'payloads.jsonl');
  const hook = path.join(dir, 'chalk-hook');
  fs.writeFileSync(hook, [
    '#!/usr/bin/env node',
    "'use strict';",
    "const fs = require('node:fs');",
    "const { spawn } = require('node:child_process');",
    "let data = '';",
    "process.stdin.on('data', chunk => { data += chunk; });",
    "process.stdin.on('end', () => {",
    "  fs.appendFileSync(process.env.TEST_PAYLOADS, data + '\\n');",
    "  if (process.env.TEST_HOOK_STDOUT) {",
    "    const payload = JSON.parse(data);",
    "    process.stdout.write(process.env.TEST_HOOK_STDOUT + '\\n');",
    "    process.stdout.write(JSON.stringify({ schema: 'chalk-docker-post-push-result/v1', status: 'complete', operationId: payload.operationId }) + '\\n');",
    "  }",
    "  if (process.env.TEST_DESCENDANT_PID) {",
    "    const child = spawn(process.execPath, ['-e', 'process.on(\"SIGTERM\", () => {}); setInterval(() => {}, 1000)']);",
    "    fs.writeFileSync(process.env.TEST_DESCENDANT_PID, String(child.pid));",
    "    process.on('SIGTERM', () => {});",
    "  }",
    "  setTimeout(() => process.exit(Number(process.env.TEST_HOOK_EXIT || 0)), Number(process.env.TEST_HOOK_DELAY || 0));",
    "});",
    '',
  ].join('\n'), { mode: 0o700 });
  return { dir, payloads, hook };
}

function environment(fx) {
  const prior = { ...process.env };
  process.env.CHALK_DOCKERODE_TEST_PLATFORM = 'linux';
  process.env.CHALK_DOCKERODE_CHALK = fx.hook;
  process.env.CHALK_DOCKERODE_LOG = path.join(fx.dir, 'diagnostics.jsonl');
  process.env.TEST_PAYLOADS = fx.payloads;
  process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = '5000';
  return () => {
    for (const key of Object.keys(process.env)) {
      if (!(key in prior)) delete process.env[key];
    }
    Object.assign(process.env, prior);
    fs.rmSync(fx.dir, { recursive: true, force: true });
  };
}

function imageClass({ stream = true, fail = false, body = BODY } = {}) {
  function Image(modem, name) {
    this.modem = modem;
    this.name = name;
    this.calls = 0;
  }
  Image.prototype.push = function (opts, callback) {
    this.calls += 1;
    const value = stream ? Readable.from([body]) : body;
    const error = fail ? new Error('engine push failed') : null;
    if (callback === undefined) return error ? Promise.reject(error) : Promise.resolve(value);
    process.nextTick(() => callback(error, error ? undefined : value));
    return undefined;
  };
  return Image;
}

function modem() {
  return { getSocketPath: () => Promise.resolve('/var/run/docker.sock') };
}

test('reference helpers parse registry ports, tags, and terminal digests', () => {
  assert.equal(repositoryWithoutTag('registry.example:5000/team/app:old'), 'registry.example:5000/team/app');
  assert.equal(repositoryWithoutTag('team/app@sha256:deadbeef'), 'team/app');
  assert.equal(terminalDigest(BODY), DIGEST);
  assert.equal(terminalDigest(Buffer.from(`${JSON.stringify({ status: `tag: digest: ${DIGEST} size: 1` })}\n`)), DIGEST);
  assert.equal(terminalDigest(Buffer.from('{"error":"denied"}\n')), null);
});

test('incremental parser finds a tail digest after more than 1 MiB of progress', () => {
  const tracker = createTerminalTracker();
  const progress = Buffer.from(`${JSON.stringify({ status: 'Pushing', progress: 'x'.repeat(1024) })}\n`);
  let total = 0;
  while (total <= 1024 * 1024) {
    tracker.write(progress);
    total += progress.length;
  }
  const terminal = Buffer.from(`${JSON.stringify({ aux: { Digest: DIGEST } })}\n`);
  for (let offset = 0; offset < terminal.length; offset += 7) {
    tracker.write(terminal.subarray(offset, offset + 7));
  }
  assert.deepEqual(tracker.finish(), { digest: DIGEST, error: false, overflow: false });
});

test('incremental parser remembers errors and rejects an oversized unfinished frame', () => {
  const errorThenDigest = createTerminalTracker();
  errorThenDigest.write(Buffer.from('{"error":"denied"}\n'));
  errorThenDigest.write(Buffer.from(`${JSON.stringify({ aux: { Digest: DIGEST } })}\n`));
  assert.deepEqual(errorThenDigest.finish(), { digest: null, error: true, overflow: false });

  const oversized = createTerminalTracker();
  oversized.write(Buffer.alloc(1024 * 1024 + 1, 0x78));
  oversized.write(Buffer.from(`\n${JSON.stringify({ aux: { Digest: DIGEST } })}\n`));
  assert.deepEqual(oversized.finish(), { digest: null, error: false, overflow: true });
});

test('deadline is required, positive, and capped at five minutes', () => {
  const prior = process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
  try {
    delete process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
    assert.deepEqual(postPushDeadline(), { supported: false, code: 'unsupported_no_deadline' });
    for (const invalid of ['', '0', '-1', '1.5', '300001', 'not-a-number']) {
      process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = invalid;
      assert.deepEqual(postPushDeadline(), { supported: false, code: 'unsupported_invalid_deadline' });
    }
    process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = '300000';
    assert.deepEqual(postPushDeadline(), { supported: true, timeoutMs: 300000 });
  } finally {
    if (prior === undefined) delete process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
    else process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = prior;
  }
});

test('stream contract performs one push, preserves bytes, and delays end for the post-hook', async () => {
  const fx = fixture();
  const restore = environment(fx);
  process.env.TEST_HOOK_DELAY = '80';
  try {
    const Image = imageClass();
    patchImage(Image, { version: '5.0.1', packageRoot: '/fixture/dockerode' });
    const image = new Image(modem(), 'registry.example:5000/team/app:ignored');
    const start = Date.now();
    const stream = await image.push({
      tag: 'release-1',
      authconfig: { username: 'AWS', password: 'secret', serveraddress: 'registry.example:5000' },
    });
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), BODY);
    assert.equal(image.calls, 1);
    assert.ok(Date.now() - start >= 70, 'proxy must not end before the post-hook');

    const payload = JSON.parse(fs.readFileSync(fx.payloads, 'utf8').trim());
    assert.equal(payload.schema, 'chalk-docker-post-push/v1');
    assert.equal(payload.repository, 'registry.example:5000/team/app');
    assert.equal(payload.tag, 'release-1');
    assert.equal(payload.digest, DIGEST);
    assert.equal(payload.authconfig.password, 'secret');
  } finally {
    restore();
  }
});

test('stream contract preserves and instruments a response larger than 1 MiB', async () => {
  const fx = fixture();
  const restore = environment(fx);
  const progress = Buffer.from(`${JSON.stringify({ status: 'Pushing', progress: 'x'.repeat(2048) })}\n`);
  const pieces = [];
  let bytes = 0;
  while (bytes <= 1024 * 1024) {
    pieces.push(progress);
    bytes += progress.length;
  }
  pieces.push(Buffer.from(`${JSON.stringify({ aux: { Digest: DIGEST } })}\n`));
  const largeBody = Buffer.concat(pieces);
  try {
    const Image = imageClass({ body: largeBody });
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const chunks = [];
    for await (const chunk of await image.push({ tag: 'one' })) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), largeBody);
    assert.equal(image.calls, 1);
    assert.equal(JSON.parse(fs.readFileSync(fx.payloads, 'utf8')).digest, DIGEST);
  } finally {
    restore();
  }
});

test('missing deadline skips the post-hook without changing push success', async () => {
  const fx = fixture();
  const restore = environment(fx);
  delete process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
  try {
    const Image = imageClass();
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const chunks = [];
    for await (const chunk of await image.push({ tag: 'one' })) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), BODY);
    assert.equal(image.calls, 1);
    assert.equal(fs.existsSync(fx.payloads), false);
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"code":"unsupported_no_deadline"/);
  } finally {
    restore();
  }
});

test('buffered callback preserves identity and waits for a fail-open hook', async () => {
  const fx = fixture();
  const restore = environment(fx);
  process.env.TEST_HOOK_EXIT = '1';
  try {
    const Image = imageClass({ stream: false });
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const value = await new Promise((resolve, reject) => {
      const returned = image.push({ tag: 'one', stream: false }, (error, data) => {
        if (error) reject(error);
        else resolve(data);
      });
      assert.equal(returned, undefined);
    });
    assert.equal(value, BODY);
    assert.equal(image.calls, 1);
    const diagnostics = fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8');
    assert.match(diagnostics, /"code":"posthook_failed"/);
  } finally {
    restore();
  }
});

test('configured stdout reports are forwarded while the internal result is consumed', async () => {
  const fx = fixture();
  const restore = environment(fx);
  const originalWrite = process.stdout.write;
  const writes = [];
  process.env.TEST_HOOK_STDOUT = 'configured-report-output';
  process.stdout.write = function (chunk, encoding, callback) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, typeof encoding === 'string' ? encoding : undefined);
    if (value.includes('configured-report-output') || value.includes('chalk-docker-post-push-result/v1')) {
      writes.push(value);
      if (typeof encoding === 'function') encoding();
      else if (typeof callback === 'function') callback();
      return true;
    }
    return originalWrite.apply(this, arguments);
  };
  try {
    try {
      const Image = imageClass({ stream: false });
      patchImage(Image, { version: '5.0.1' });
      const image = new Image(modem(), 'team/app');
      assert.equal(await image.push({ tag: 'one', stream: false }), BODY);
    } finally {
      process.stdout.write = originalWrite;
    }
    assert.equal(Buffer.concat(writes).toString('utf8'), 'configured-report-output\n');
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"status":"complete"/);
  } finally {
    process.stdout.write = originalWrite;
    restore();
  }
});

test('unsupported, custom-socket, and failed pushes never invoke the post-hook', async () => {
  const fx = fixture();
  const restore = environment(fx);
  try {
    const Unsupported = imageClass({ stream: false });
    patchImage(Unsupported, { version: '5.0.1' });
    const unsupported = new Unsupported(modem(), 'team/app');
    assert.equal(await unsupported.push({ stream: false }), BODY);

    const CustomSocket = imageClass({ stream: false });
    patchImage(CustomSocket, { version: '5.0.1' });
    const customSocket = new CustomSocket(
      { getSocketPath: () => Promise.resolve('/tmp/other-docker.sock') },
      'team/app',
    );
    assert.equal(await customSocket.push({ tag: 'one', stream: false }), BODY);

    const Failing = imageClass({ fail: true });
    patchImage(Failing, { version: '5.0.1' });
    const failing = new Failing(modem(), 'team/app');
    await assert.rejects(failing.push({ tag: 'one' }), /engine push failed/);

    assert.equal(fs.existsSync(fx.payloads), false);
    assert.equal(unsupported.calls, 1);
    assert.equal(customSocket.calls, 1);
    assert.equal(failing.calls, 1);
    assert.match(
      fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'),
      /"code":"unsupported_daemon".*"socketPath":"\/tmp\/other-docker\.sock"/,
    );
  } finally {
    restore();
  }
});

test('all guarded option and runtime shapes skip instrumentation fail-open', async () => {
  const fx = fixture();
  const restore = environment(fx);
  try {
    const cases = [
      { meta: { version: '4.0.0' }, opts: { tag: 'one', stream: false } },
      { meta: { version: '5.0.1' }, opts: { tag: 'one', platform: 'linux/arm64', stream: false } },
      { meta: { version: '5.0.1' }, opts: { tag: 'one', authconfig: {}, stream: false } },
      {
        meta: { version: '5.0.1' },
        opts: { tag: 'one', authconfig: { username: '', password: 'secret', serveraddress: 'registry.example' }, stream: false },
      },
      {
        meta: { version: '5.0.1' },
        opts: { tag: 'one', authconfig: { username: 'user', password: '', serveraddress: 'registry.example' }, stream: false },
      },
      {
        meta: { version: '5.0.1' },
        opts: { tag: 'one', authconfig: { username: 'user', password: 'secret', serveraddress: '' }, stream: false },
      },
    ];
    for (const item of cases) {
      const Image = imageClass({ stream: false });
      patchImage(Image, item.meta);
      const image = new Image(modem(), 'team/app');
      assert.equal(await image.push(item.opts), BODY);
      assert.equal(image.calls, 1);
    }
    assert.equal(fs.existsSync(fx.payloads), false);
    const diagnostics = fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8');
    assert.match(diagnostics, /"code":"unsupported_dockerode"/);
    assert.match(diagnostics, /"code":"unsupported_platform_option"/);
    assert.match(diagnostics, /"code":"unsupported_auth_shape"/);
  } finally {
    restore();
  }
});

test('synchronous throws and stream failures preserve the original failure and skip the post-hook', async () => {
  const fx = fixture();
  const restore = environment(fx);
  try {
    const syncError = new Error('synchronous engine failure');
    function ThrowingImage(modemValue, name) {
      this.modem = modemValue;
      this.name = name;
      this.calls = 0;
    }
    ThrowingImage.prototype.push = function () {
      this.calls += 1;
      throw syncError;
    };
    patchImage(ThrowingImage, { version: '5.0.1' });
    const throwing = new ThrowingImage(modem(), 'team/app');
    assert.throws(() => throwing.push({ tag: 'one' }), (error) => error === syncError);
    assert.equal(throwing.calls, 1);

    const streamError = new Error('response stream failed');
    function StreamingImage(modemValue, name) {
      this.modem = modemValue;
      this.name = name;
      this.calls = 0;
    }
    StreamingImage.prototype.push = function () {
      this.calls += 1;
      const source = new Readable({ read() {} });
      process.nextTick(() => {
        source.push(BODY);
        source.destroy(streamError);
      });
      return Promise.resolve(source);
    };
    patchImage(StreamingImage, { version: '5.0.1' });
    const streaming = new StreamingImage(modem(), 'team/app');
    let observed;
    try {
      for await (const _chunk of await streaming.push({ tag: 'one' })) {
        // Consume until the original stream error is delivered.
      }
    } catch (error) {
      observed = error;
    }
    assert.equal(observed, streamError);
    assert.equal(streaming.calls, 1);
    await new Promise((resolve) => setTimeout(resolve, 25));
    assert.equal(fs.existsSync(fx.payloads), false);
  } finally {
    restore();
  }
});

test('post-hook spawn failure is diagnostic-only', async () => {
  const fx = fixture();
  const restore = environment(fx);
  process.env.CHALK_DOCKERODE_CHALK = path.join(fx.dir, 'missing-chalk');
  try {
    const Image = imageClass();
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const chunks = [];
    for await (const chunk of await image.push({ tag: 'one' })) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), BODY);
    assert.equal(image.calls, 1);
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"code":"posthook_spawn_failed"/);
  } finally {
    restore();
  }
});

test('instrumentation exceptions are fail-open for buffered promises', async () => {
  const fx = fixture();
  const restore = environment(fx);
  try {
    const Image = imageClass({ stream: false });
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    Object.defineProperty(image, 'name', {
      get() { throw new Error('instrumentation-only failure'); },
    });
    assert.equal(await image.push({ tag: 'one', stream: false }), BODY);
    assert.equal(image.calls, 1);
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"code":"instrumentation_exception"/);
  } finally {
    restore();
  }
});

test('destroying the proxy aborts the Engine stream and skips post-push', async () => {
  const fx = fixture();
  const restore = environment(fx);
  let source;
  try {
    function StreamingImage(modemValue, name) {
      this.modem = modemValue;
      this.name = name;
      this.calls = 0;
    }
    StreamingImage.prototype.push = function () {
      this.calls += 1;
      source = new Readable({ read() {} });
      return Promise.resolve(source);
    };
    patchImage(StreamingImage, { version: '5.0.1' });
    const image = new StreamingImage(modem(), 'team/app');
    const stream = await image.push({ tag: 'one' });
    const closed = new Promise((resolve) => stream.once('close', resolve));
    stream.destroy();
    await closed;
    assert.equal(source.destroyed, true);
    assert.equal(image.calls, 1);
    await new Promise((resolve) => setTimeout(resolve, 25));
    assert.equal(fs.existsSync(fx.payloads), false);
  } finally {
    restore();
  }
});

test('post-hook deadline delays only to the deadline and preserves stream success', async () => {
  const fx = fixture();
  const restore = environment(fx);
  process.env.TEST_HOOK_DELAY = '1000';
  process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = '50';
  try {
    const Image = imageClass();
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const start = Date.now();
    const stream = await image.push({ tag: 'one' });
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    const elapsed = Date.now() - start;
    assert.deepEqual(Buffer.concat(chunks), BODY);
    assert.ok(elapsed >= 40 && elapsed < 700, `unexpected timeout completion: ${elapsed}ms`);
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"code":"posthook_timeout"/);
    assert.equal(fs.statSync(process.env.CHALK_DOCKERODE_LOG).mode & 0o777, 0o600);
  } finally {
    restore();
  }
});

test('post-hook timeout terminates its process group, including descendants', async () => {
  const fx = fixture();
  const restore = environment(fx);
  const descendantPid = path.join(fx.dir, 'descendant.pid');
  process.env.TEST_HOOK_DELAY = '10000';
  process.env.TEST_DESCENDANT_PID = descendantPid;
  process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS = '500';
  try {
    const Image = imageClass();
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    const chunks = [];
    for await (const chunk of await image.push({ tag: 'one' })) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), BODY);
    assert.match(fs.readFileSync(process.env.CHALK_DOCKERODE_LOG, 'utf8'), /"code":"posthook_timeout"/);
    assert.equal(fs.existsSync(descendantPid), true);
    const pid = Number(fs.readFileSync(descendantPid, 'utf8'));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    restore();
  }
});

test('callback error is the original object and does not invoke the post-hook', async () => {
  const fx = fixture();
  const restore = environment(fx);
  let unhandled;
  const observeUnhandled = (error) => { unhandled = error; };
  process.on('unhandledRejection', observeUnhandled);
  try {
    const Image = imageClass({ fail: true });
    patchImage(Image, { version: '5.0.1' });
    const image = new Image(modem(), 'team/app');
    Object.defineProperty(image, 'name', {
      get() { throw new Error('unused instrumentation failure'); },
    });
    const error = await new Promise((resolve) => {
      image.push({ tag: 'one' }, (found) => resolve(found));
    });
    assert.equal(error.message, 'engine push failed');
    await new Promise((resolve) => setTimeout(resolve, 25));
    assert.equal(unhandled, undefined);
    assert.equal(fs.existsSync(fx.payloads), false);
  } finally {
    process.removeListener('unhandledRejection', observeUnhandled);
    restore();
  }
});
