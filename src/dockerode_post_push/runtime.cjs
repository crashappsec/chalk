'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { PassThrough } = require('node:stream');
const { randomUUID } = require('node:crypto');

const PATCHED = Symbol.for('chalk.dockerode.postPush.patched.v1');
const DEFAULT_SOCKETS = new Set([
  '/var/run/docker.sock',
  path.join(os.homedir(), '.docker/run/docker.sock'),
]);
const MAX_INCOMPLETE_FRAME_BYTES = 1024 * 1024;
const MAX_POST_PUSH_TIMEOUT_MS = 5 * 60 * 1000;
const MAX_POST_PUSH_STDOUT_LINE_BYTES = 64 * 1024;
const POST_PUSH_KILL_GRACE_MS = 1000;

function diagnostic(code, fields = {}) {
  const record = {
    schema: 'chalk-dockerode-diagnostic/v1',
    time: new Date().toISOString(),
    code,
    ...fields,
  };
  const line = JSON.stringify(record) + '\n';
  const target = process.env.CHALK_DOCKERODE_LOG;
  try {
    if (target) {
      const fd = fs.openSync(target, 'a', 0o600);
      try {
        fs.fchmodSync(fd, 0o600);
        fs.writeSync(fd, line);
      } finally {
        fs.closeSync(fd);
      }
    } else process.stderr.write(line);
  } catch (_) {
    // Diagnostics must never change push behavior.
  }
}

function repositoryWithoutTag(name) {
  const digestAt = name.indexOf('@');
  const withoutDigest = digestAt === -1 ? name : name.slice(0, digestAt);
  const slash = withoutDigest.lastIndexOf('/');
  const colon = withoutDigest.lastIndexOf(':');
  return colon > slash ? withoutDigest.slice(0, colon) : withoutDigest;
}

async function supportedOperation(image, opts, meta) {
  if (process.platform !== 'linux' && process.env.CHALK_DOCKERODE_TEST_PLATFORM !== 'linux') {
    return { supported: false, code: 'unsupported_platform' };
  }
  if (!meta || !String(meta.version || '').startsWith('5.')) {
    return { supported: false, code: 'unsupported_dockerode' };
  }
  const deadline = postPushDeadline();
  if (!deadline.supported) return deadline;
  if (!opts || typeof opts.tag !== 'string' || opts.tag.length === 0) {
    return { supported: false, code: 'unsupported_missing_explicit_tag' };
  }
  if (opts.platform !== undefined) {
    return { supported: false, code: 'unsupported_platform_option' };
  }
  if (!image.modem || typeof image.modem.getSocketPath !== 'function') {
    return { supported: false, code: 'unsupported_modem' };
  }
  let socketPath;
  try {
    socketPath = await image.modem.getSocketPath();
  } catch (_) {
    return { supported: false, code: 'socket_resolution_failed' };
  }
  if (!DEFAULT_SOCKETS.has(socketPath)) {
    return { supported: false, code: 'unsupported_daemon', socketPath };
  }

  const auth = opts.authconfig;
  if (auth !== undefined && (
    !auth || typeof auth.username !== 'string' || typeof auth.password !== 'string' ||
    typeof auth.serveraddress !== 'string' || auth.username.length === 0 ||
    auth.password.length === 0 || auth.serveraddress.length === 0
  )) {
    return { supported: false, code: 'unsupported_auth_shape' };
  }

  return {
    supported: true,
    socketPath,
    repository: repositoryWithoutTag(String(image.name)),
    tag: opts.tag,
    authconfig: auth,
    timeoutMs: deadline.timeoutMs,
  };
}

function inspectTerminalFrame(raw) {
  const line = raw.toString('utf8').replace(/\r$/, '');
  if (!line.trim()) return { digest: null, error: false };
  try {
    const frame = JSON.parse(line);
    let digest = null;
    const candidate = frame && frame.aux && frame.aux.Digest;
    if (typeof candidate === 'string' && /^sha256:[0-9a-f]{64}$/.test(candidate)) {
      digest = candidate;
    }
    if (typeof frame.status === 'string') {
      const match = frame.status.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
      if (match) digest = match[1];
    }
    return {
      digest,
      error: typeof frame.error === 'string' || Boolean(frame.errorDetail),
    };
  } catch (_) {
    const match = line.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
    return { digest: match ? match[1] : null, error: false };
  }
}

function createTerminalTracker() {
  let pending = Buffer.alloc(0);
  let discardUntilNewline = false;
  let invalid = false;
  let sawError = false;
  let lastDigest = null;

  function observe(frame) {
    const found = inspectTerminalFrame(frame);
    if (found.error) sawError = true;
    if (found.digest) lastDigest = found.digest;
  }

  function write(value) {
    let chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    if (discardUntilNewline) {
      const newline = chunk.indexOf(0x0a);
      if (newline === -1) return;
      discardUntilNewline = false;
      chunk = chunk.subarray(newline + 1);
    }
    if (chunk.length === 0) return;

    let combined = pending.length === 0 ? chunk : Buffer.concat([pending, chunk]);
    let start = 0;
    for (;;) {
      const newline = combined.indexOf(0x0a, start);
      if (newline === -1) break;
      observe(combined.subarray(start, newline));
      start = newline + 1;
    }
    pending = combined.subarray(start);
    if (pending.length > MAX_INCOMPLETE_FRAME_BYTES) {
      invalid = true;
      pending = Buffer.alloc(0);
      discardUntilNewline = true;
    }
  }

  function finish() {
    if (pending.length > 0 && !discardUntilNewline) observe(pending);
    return {
      digest: invalid || sawError ? null : lastDigest,
      error: sawError,
      overflow: invalid,
    };
  }

  return { write, finish };
}

function terminalDigest(data) {
  if (data === undefined || data === null) return null;
  const tracker = createTerminalTracker();
  tracker.write(Buffer.isBuffer(data) || typeof data === 'string' ? data : JSON.stringify(data));
  return tracker.finish().digest;
}

function postPushDeadline() {
  const raw = process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
  if (raw === undefined) return { supported: false, code: 'unsupported_no_deadline' };
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > MAX_POST_PUSH_TIMEOUT_MS) {
    return { supported: false, code: 'unsupported_invalid_deadline' };
  }
  return { supported: true, timeoutMs: parsed };
}

function signalPostHook(child, signal, detached) {
  try {
    if (detached && child.pid) process.kill(-child.pid, signal);
    else child.kill(signal);
  } catch (_) {
    // A concurrent exit is equivalent to successful termination here.
  }
}

function invokePostPush(operation, digest) {
  const chalk = process.env.CHALK_DOCKERODE_CHALK || 'chalk';
  const payload = {
    schema: 'chalk-docker-post-push/v1',
    operationId: randomUUID(),
    repository: operation.repository,
    tag: operation.tag,
    digest,
    socketPath: operation.socketPath,
    authconfig: operation.authconfig,
  };

  return new Promise((resolve) => {
    let settled = false;
    let timedOut = false;
    let stderrObserved = false;
    let postHookStatus = null;
    let stdoutPending = Buffer.alloc(0);
    let killTimer = null;
    const detached = process.platform !== 'win32';
    const chalkArgs = process.env.CHALK_DOCKERODE_NO_EXTERNAL_CONFIG === '1'
      ? ['--no-use-external-config', '__', 'docker_post_push']
      : ['__', 'docker_post_push'];
    const child = spawn(chalk, chalkArgs, {
      detached,
      env: process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const forwardStdout = (value) => {
      try {
        process.stdout.write(value);
      } catch (_) {
        // A report sink must not change the original push result.
      }
    };
    const handleStdoutLine = (line) => {
      try {
        const parsed = JSON.parse(line.toString('utf8').trim());
        if (parsed && parsed.schema === 'chalk-docker-post-push-result/v1' &&
            parsed.operationId === payload.operationId && typeof parsed.status === 'string') {
          postHookStatus = parsed.status;
          return;
        }
      } catch (_) {
        // Non-result output belongs to configured Chalk report sinks.
      }
      forwardStdout(line);
    };
    const consumeStdout = (chunk) => {
      let combined = stdoutPending.length === 0 ? chunk : Buffer.concat([stdoutPending, chunk]);
      let start = 0;
      for (;;) {
        const newline = combined.indexOf(0x0a, start);
        if (newline === -1) break;
        handleStdoutLine(combined.subarray(start, newline + 1));
        start = newline + 1;
      }
      stdoutPending = combined.subarray(start);
      if (stdoutPending.length > MAX_POST_PUSH_STDOUT_LINE_BYTES) {
        forwardStdout(stdoutPending);
        stdoutPending = Buffer.alloc(0);
      }
    };
    const flushStdout = () => {
      if (stdoutPending.length > 0) {
        handleStdoutLine(stdoutPending);
        stdoutPending = Buffer.alloc(0);
      }
    };
    const settle = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      resolve();
    };
    const timer = setTimeout(() => {
      if (settled) return;
      timedOut = true;
      diagnostic('posthook_timeout', {
        operationId: payload.operationId,
        timeoutMs: operation.timeoutMs,
      });
      signalPostHook(child, 'SIGTERM', detached);
      killTimer = setTimeout(() => {
        signalPostHook(child, 'SIGKILL', detached);
        settle();
      }, POST_PUSH_KILL_GRACE_MS);
    }, operation.timeoutMs);

    child.stderr.on('data', (chunk) => {
      stderrObserved = stderrObserved || chunk.length > 0;
    });
    child.stdout.on('data', consumeStdout);
    child.on('error', (error) => {
      if (settled) return;
      diagnostic('posthook_spawn_failed', { operationId: payload.operationId, message: error.message });
      settle();
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      flushStdout();
      if (timedOut) {
        settle();
      } else if (code !== 0) {
        diagnostic('posthook_failed', {
          operationId: payload.operationId,
          exitCode: code,
          signal,
          stderrObserved,
          status: postHookStatus,
        });
      } else {
        diagnostic('posthook_complete', {
          operationId: payload.operationId,
          digest,
          status: postHookStatus,
        });
      }
      settle();
    });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

async function finishBuffered(value, operationPromise) {
  try {
    const operation = await operationPromise;
    if (!operation.supported) {
      diagnostic(operation.code, { socketPath: operation.socketPath });
      return value;
    }
    const tracker = createTerminalTracker();
    tracker.write(Buffer.isBuffer(value) || typeof value === 'string' ? value : JSON.stringify(value));
    const terminal = tracker.finish();
    if (!terminal.digest) {
      diagnostic(terminal.overflow ? 'terminal_frame_too_large' : 'missing_terminal_digest');
      return value;
    }
    await invokePostPush(operation, terminal.digest);
  } catch (error) {
    diagnostic('posthook_exception', { message: error.message });
  }
  return value;
}

function finishStream(source, operationPromise) {
  const tracker = createTerminalTracker();
  let ended = false;
  let sourceFailed = false;
  let cancelled = false;
  const proxy = new PassThrough({
    destroy(error, callback) {
      if (!ended && !sourceFailed) {
        cancelled = true;
        source.destroy(error || undefined);
      }
      callback(error);
    },
  });

  source.on('data', (chunk) => {
    tracker.write(chunk);
  });
  source.once('error', (error) => {
    sourceFailed = true;
    ended = true;
    proxy.destroy(error);
  });
  source.pipe(proxy, { end: false });
  source.once('end', async () => {
    if (sourceFailed || cancelled) return;
    try {
      const operation = await operationPromise;
      if (!operation.supported) {
        diagnostic(operation.code, { socketPath: operation.socketPath });
      } else {
        const terminal = tracker.finish();
        if (!terminal.digest) {
          diagnostic(terminal.overflow ? 'terminal_frame_too_large' : 'missing_terminal_digest');
        } else await invokePostPush(operation, terminal.digest);
      }
      ended = true;
      proxy.end();
    } catch (error) {
      diagnostic('posthook_exception', { message: error.message });
      ended = true;
      proxy.end();
    }
  });
  return proxy;
}

function patchImage(Image, meta) {
  if (!Image || !Image.prototype || typeof Image.prototype.push !== 'function') return;
  if (Image.prototype.push[PATCHED]) return;

  const original = Image.prototype.push;
  function chalkPostPush(opts, callback, auth) {
    const rawArgs = arguments;
    const normalizedOpts = typeof opts === 'function' ? {} : (opts || {});
    const callbackFn = typeof opts === 'function' ? opts : callback;
    const operationOpts = { ...normalizedOpts };
    operationOpts.authconfig = normalizedOpts.authconfig || auth;
    const operationPromise = supportedOperation(this, operationOpts, meta);

    if (callbackFn === undefined) {
      let result;
      try {
        result = original.apply(this, rawArgs);
      } catch (error) {
        throw error;
      }
      return result.then((value) => {
        if (normalizedOpts.stream === false) return finishBuffered(value, operationPromise);
        return finishStream(value, operationPromise);
      });
    }

    const self = this;
    const replacement = function (error, value) {
      if (error) return callbackFn(error, value);
      if (normalizedOpts.stream === false) {
        finishBuffered(value, operationPromise).then(
          (result) => callbackFn(null, result),
          () => callbackFn(null, value),
        );
      } else {
        callbackFn(null, finishStream(value, operationPromise));
      }
    };
    const args = Array.from(rawArgs);
    if (typeof opts === 'function') args[0] = replacement;
    else args[1] = replacement;
    return original.apply(self, args);
  }
  Object.defineProperty(chalkPostPush, PATCHED, { value: true });
  Object.defineProperty(chalkPostPush, 'name', { value: 'push' });
  Image.prototype.push = chalkPostPush;
}

module.exports = {
  createTerminalTracker,
  patchImage,
  postPushDeadline,
  repositoryWithoutTag,
  terminalDigest,
};
