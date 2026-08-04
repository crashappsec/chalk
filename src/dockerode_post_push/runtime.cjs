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
const MAX_DIGEST_SCAN_BYTES = 1024 * 1024;

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
    typeof auth.serveraddress !== 'string'
  )) {
    return { supported: false, code: 'unsupported_auth_shape' };
  }

  return {
    supported: true,
    socketPath,
    repository: repositoryWithoutTag(String(image.name)),
    tag: opts.tag,
    authconfig: auth,
  };
}

function terminalDigest(data) {
  let text;
  if (Buffer.isBuffer(data)) text = data.toString('utf8');
  else if (typeof data === 'string') text = data;
  else if (data && typeof data === 'object') text = JSON.stringify(data);
  else return null;

  let found = null;
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const frame = JSON.parse(line);
      const candidate = frame && frame.aux && frame.aux.Digest;
      if (typeof candidate === 'string' && /^sha256:[0-9a-f]{64}$/.test(candidate)) {
        found = candidate;
      }
      if (typeof frame.status === 'string') {
        const match = frame.status.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
        if (match) found = match[1];
      }
      if (typeof frame.error === 'string' || frame.errorDetail) return null;
    } catch (_) {
      const match = line.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
      if (match) found = match[1];
    }
  }
  return found;
}

function timeoutMs() {
  const raw = process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
  if (raw === undefined) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
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
    let stderrObserved = false;
    const chalkArgs = process.env.CHALK_DOCKERODE_NO_EXTERNAL_CONFIG === '1'
      ? ['--no-use-external-config', '__', 'docker_post_push']
      : ['__', 'docker_post_push'];
    const child = spawn(chalk, chalkArgs, {
      env: process.env,
      stdio: ['pipe', 'ignore', 'pipe'],
    });
    const limit = timeoutMs();
    const timer = limit === null ? null : setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGTERM');
      diagnostic('posthook_timeout', { operationId: payload.operationId, timeoutMs: limit });
      resolve();
    }, limit);

    child.stderr.on('data', (chunk) => {
      stderrObserved = stderrObserved || chunk.length > 0;
    });
    child.on('error', (error) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      diagnostic('posthook_spawn_failed', { operationId: payload.operationId, message: error.message });
      resolve();
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (code !== 0) {
        diagnostic('posthook_failed', {
          operationId: payload.operationId,
          exitCode: code,
          signal,
          stderrObserved,
        });
      } else {
        diagnostic('posthook_complete', { operationId: payload.operationId, digest });
      }
      resolve();
    });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

async function finishBuffered(value, operationPromise) {
  const operation = await operationPromise;
  if (!operation.supported) {
    diagnostic(operation.code, { socketPath: operation.socketPath });
    return value;
  }
  const digest = terminalDigest(value);
  if (!digest) {
    diagnostic('missing_terminal_digest');
    return value;
  }
  await invokePostPush(operation, digest);
  return value;
}

function finishStream(source, operationPromise) {
  const proxy = new PassThrough();
  const chunks = [];
  let bytes = 0;
  let ended = false;

  source.on('data', (chunk) => {
    if (bytes < MAX_DIGEST_SCAN_BYTES) {
      const copy = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = MAX_DIGEST_SCAN_BYTES - bytes;
      chunks.push(copy.subarray(0, remaining));
      bytes += Math.min(copy.length, remaining);
    }
  });
  source.once('error', (error) => {
    if (!ended) proxy.destroy(error);
  });
  source.pipe(proxy, { end: false });
  source.once('end', async () => {
    try {
      const operation = await operationPromise;
      if (!operation.supported) {
        diagnostic(operation.code, { socketPath: operation.socketPath });
      } else {
        const digest = terminalDigest(Buffer.concat(chunks));
        if (!digest) diagnostic('missing_terminal_digest');
        else await invokePostPush(operation, digest);
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
  patchImage,
  repositoryWithoutTag,
  terminalDigest,
};
