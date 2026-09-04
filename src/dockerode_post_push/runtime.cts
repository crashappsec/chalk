import fs = require('node:fs');
import { spawn } from 'node:child_process';
import { PassThrough } from 'node:stream';
import { randomUUID } from 'node:crypto';
import type Dockerode = require('dockerode');
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { Readable } from 'node:stream';

type DiagnosticFields = Record<string, unknown>;
type DiagnosticCode =
  | 'instrumentation_exception'
  | 'missing_terminal_digest'
  | 'posthook_complete'
  | 'posthook_exception'
  | 'posthook_failed'
  | 'posthook_spawn_failed'
  | 'posthook_timeout'
  | 'terminal_frame_too_large'
  | 'unsupported_auth_shape'
  | 'unsupported_daemon'
  | 'unsupported_dockerode'
  | 'unsupported_invalid_deadline'
  | 'unsupported_missing_explicit_tag'
  | 'unsupported_modem'
  | 'unsupported_no_deadline'
  | 'unsupported_platform'
  | 'unsupported_platform_option';

interface DiagnosticRecord extends DiagnosticFields {
  schema: 'chalk-dockerode-diagnostic/v1';
  time: string;
  code: DiagnosticCode;
}

interface PushOptions {
  tag?: unknown;
  platform?: unknown;
  authconfig?: unknown;
  stream?: unknown;
  [key: string]: unknown;
}

interface DockerodeImageLike {
  modem?: { socketPath?: unknown; host?: unknown };
  name?: unknown;
}

interface OperationMetadata {
  packageRoot?: string;
  version?: string;
}

interface SupportedOperation {
  supported: true;
  socketPath: string;
  repository: string;
  tag: string;
  authconfig: Dockerode.AuthConfig | undefined;
  timeoutMs: number;
}

interface UnsupportedOperation {
  supported: false;
  code: DiagnosticCode;
  socketPath?: string;
  message?: string;
}

type Operation = SupportedOperation | UnsupportedOperation;
type Deadline = { supported: true; timeoutMs: number } | UnsupportedOperation;

interface TerminalFrame {
  aux?: { Digest?: unknown };
  status?: unknown;
  error?: unknown;
  errorDetail?: unknown;
}

interface TerminalResult {
  digest: string | null;
  error: boolean;
  overflow: boolean;
}

interface TerminalTracker {
  write(value: Buffer | string): void;
  finish(): TerminalResult;
}

interface PostPushPayload {
  schema: 'chalk-docker-post-push/v1';
  operationId: string;
  repository: string;
  tag: string;
  digest: string;
  socketPath: string;
  authconfig: Dockerode.AuthConfig | undefined;
}

interface PostPushResult {
  schema: 'chalk-docker-post-push-result/v1';
  operationId: string;
  status: string;
}

type PushResult = NodeJS.ReadableStream | Buffer | string | object;
type PushCallback = (error: Error | null, value?: PushResult) => void;
type PushArguments =
  | [options?: Dockerode.ImagePushOptions]
  | [options: Dockerode.ImagePushOptions, callback: PushCallback, auth?: Dockerode.AuthConfig]
  | [callback: PushCallback, auth?: Dockerode.AuthConfig];
type PushFunction = (this: DockerodeImageLike, ...args: PushArguments) => Promise<PushResult> | void;
interface ImageConstructor {
  prototype: DockerodeImageLike & { push: PushFunction };
}

const PATCHED = Symbol.for('chalk.dockerode.postPush.patched.v1');
const SUPPORTED_DOCKERODE_VERSION = '3.3.5';
const SUPPORTED_SOCKET = '/var/run/docker.sock';
const MAX_INCOMPLETE_FRAME_BYTES = 1024 * 1024;
const MAX_POST_PUSH_TIMEOUT_MS = 5 * 60 * 1000;
const MAX_POST_PUSH_STDOUT_LINE_BYTES = 64 * 1024;
const POST_PUSH_KILL_GRACE_MS = 1000;

function isSupportedDockerodeVersion(version: unknown): boolean {
  return version === SUPPORTED_DOCKERODE_VERSION;
}

function diagnostic(code: DiagnosticCode, fields: DiagnosticFields = {}): void {
  const record: DiagnosticRecord = {
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

function repositoryWithoutTag(name: string): string {
  const digestAt = name.indexOf('@');
  const withoutDigest = digestAt === -1 ? name : name.slice(0, digestAt);
  const slash = withoutDigest.lastIndexOf('/');
  const colon = withoutDigest.lastIndexOf(':');
  return colon > slash ? withoutDigest.slice(0, colon) : withoutDigest;
}

function supportedOperation(
  image: DockerodeImageLike,
  opts: PushOptions,
  meta?: OperationMetadata,
): Operation {
  if (process.platform !== 'linux' && process.env.CHALK_DOCKERODE_TEST_PLATFORM !== 'linux') {
    return { supported: false, code: 'unsupported_platform' };
  }
  if (!meta || !isSupportedDockerodeVersion(meta.version)) {
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
  if (!image.modem || typeof image.modem !== 'object') {
    return { supported: false, code: 'unsupported_modem' };
  }
  const socketPath = image.modem.socketPath;
  if (typeof socketPath !== 'string') {
    return { supported: false, code: 'unsupported_modem' };
  }
  if (socketPath !== SUPPORTED_SOCKET) {
    return { supported: false, code: 'unsupported_daemon', socketPath };
  }

  const auth = opts.authconfig;
  const authFields = auth as {
    username?: unknown;
    password?: unknown;
    serveraddress?: unknown;
  };
  if (auth !== undefined && (
    !auth || typeof authFields.username !== 'string' || typeof authFields.password !== 'string' ||
    typeof authFields.serveraddress !== 'string' || authFields.username.length === 0 ||
    authFields.password.length === 0 || authFields.serveraddress.length === 0
  )) {
    return { supported: false, code: 'unsupported_auth_shape' };
  }

  return {
    supported: true,
    socketPath,
    repository: repositoryWithoutTag(String(image.name)),
    tag: opts.tag,
    authconfig: auth as Dockerode.AuthConfig | undefined,
    timeoutMs: deadline.timeoutMs,
  };
}

function inspectTerminalFrame(raw: Buffer): Omit<TerminalResult, 'overflow'> {
  const line = raw.toString('utf8').replace(/\r$/, '');
  if (!line.trim()) return { digest: null, error: false };
  try {
    const frame = JSON.parse(line) as TerminalFrame;
    let digest: string | null = null;
    const candidate = frame && frame.aux && frame.aux.Digest;
    if (typeof candidate === 'string' && /^sha256:[0-9a-f]{64}$/.test(candidate)) {
      digest = candidate;
    }
    if (typeof frame.status === 'string') {
      const match = frame.status.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
      if (match) digest = match[1]!;
    }
    return {
      digest,
      error: typeof frame.error === 'string' || Boolean(frame.errorDetail),
    };
  } catch (_) {
    const match = line.match(/digest:\s*(sha256:[0-9a-f]{64})(?:\s|$)/);
    return { digest: match ? match[1]! : null, error: false };
  }
}

function createTerminalTracker(): TerminalTracker {
  let pending: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  let discardUntilNewline = false;
  let invalid = false;
  let sawError = false;
  let lastDigest: string | null = null;

  function observe(frame: Buffer): void {
    const found = inspectTerminalFrame(frame);
    if (found.error) sawError = true;
    if (found.digest) lastDigest = found.digest;
  }

  function write(value: Buffer | string): void {
    let chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    if (discardUntilNewline) {
      const newline = chunk.indexOf(0x0a);
      if (newline === -1) return;
      discardUntilNewline = false;
      chunk = chunk.subarray(newline + 1);
    }
    if (chunk.length === 0) return;

    const combined = pending.length === 0 ? chunk : Buffer.concat([pending, chunk]);
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

  function finish(): TerminalResult {
    if (pending.length > 0 && !discardUntilNewline) observe(pending);
    return {
      digest: invalid || sawError ? null : lastDigest,
      error: sawError,
      overflow: invalid,
    };
  }

  return { write, finish };
}

function terminalDigest(data: unknown): string | null {
  if (data === undefined || data === null) return null;
  const tracker = createTerminalTracker();
  tracker.write(Buffer.isBuffer(data) || typeof data === 'string' ? data : JSON.stringify(data));
  return tracker.finish().digest;
}

function postPushDeadline(): Deadline {
  const raw = process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS;
  if (raw === undefined) return { supported: false, code: 'unsupported_no_deadline' };
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > MAX_POST_PUSH_TIMEOUT_MS) {
    return { supported: false, code: 'unsupported_invalid_deadline' };
  }
  return { supported: true, timeoutMs: parsed };
}

function signalPostHook(
  child: ChildProcessWithoutNullStreams,
  signal: NodeJS.Signals,
  detached: boolean,
): void {
  try {
    if (detached && child.pid) process.kill(-child.pid, signal);
    else child.kill(signal);
  } catch (_) {
    // A concurrent exit is equivalent to successful termination here.
  }
}

function invokePostPush(operation: SupportedOperation, digest: string): Promise<void> {
  const chalk = process.env.CHALK_DOCKERODE_CHALK || 'chalk';
  const payload: PostPushPayload = {
    schema: 'chalk-docker-post-push/v1',
    operationId: randomUUID(),
    repository: operation.repository,
    tag: operation.tag,
    digest,
    socketPath: operation.socketPath,
    authconfig: operation.authconfig,
  };

  return new Promise<void>((resolve) => {
    let settled = false;
    let timedOut = false;
    let stderrObserved = false;
    let postHookStatus: string | null = null;
    let stdoutPending: Buffer<ArrayBufferLike> = Buffer.alloc(0);
    let killTimer: NodeJS.Timeout | null = null;
    const detached = process.platform !== 'win32';
    const chalkArgs = process.env.CHALK_DOCKERODE_NO_EXTERNAL_CONFIG === '1'
      ? ['--no-use-external-config', '__', 'docker_post_push']
      : ['__', 'docker_post_push'];
    const child = spawn(chalk, chalkArgs, {
      detached,
      env: process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const forwardStdout = (value: Buffer): void => {
      try {
        process.stdout.write(value);
      } catch (_) {
        // A report sink must not change the original push result.
      }
    };
    const handleStdoutLine = (line: Buffer): void => {
      try {
        const parsed = JSON.parse(line.toString('utf8').trim()) as Partial<PostPushResult>;
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
    const consumeStdout = (chunk: Buffer): void => {
      const combined = stdoutPending.length === 0 ? chunk : Buffer.concat([stdoutPending, chunk]);
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
    const flushStdout = (): void => {
      if (stdoutPending.length > 0) {
        handleStdoutLine(stdoutPending);
        stdoutPending = Buffer.alloc(0);
      }
    };
    const settle = (): void => {
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

    child.stderr.on('data', (chunk: Buffer) => {
      stderrObserved = stderrObserved || chunk.length > 0;
    });
    child.stdout.on('data', consumeStdout);
    child.on('error', (error: Error) => {
      if (settled) return;
      diagnostic('posthook_spawn_failed', { operationId: payload.operationId, message: error.message });
      settle();
    });
    child.on('close', (code: number | null, signal: NodeJS.Signals | null) => {
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

async function finishBuffered<T>(value: T, operation: Operation): Promise<T> {
  try {
    if (!operation.supported) {
      diagnostic(operation.code, { socketPath: operation.socketPath, message: operation.message });
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
    diagnostic('posthook_exception', { message: error instanceof Error ? error.message : String(error) });
  }
  return value;
}

function finishStream(source: Readable, operation: Operation): Readable {
  const tracker = createTerminalTracker();
  let ended = false;
  let sourceFailed = false;
  let cancelled = false;
  const proxy = new PassThrough({
    destroy(error: Error | null, callback: (error?: Error | null) => void) {
      if (!ended && !sourceFailed) {
        cancelled = true;
        source.destroy(error || undefined);
      }
      callback(error);
    },
  });

  source.on('data', (chunk: Buffer | string) => {
    tracker.write(chunk);
  });
  source.once('error', (error: Error) => {
    sourceFailed = true;
    ended = true;
    proxy.destroy(error);
  });
  source.pipe(proxy, { end: false });
  source.once('end', async () => {
    if (sourceFailed || cancelled) return;
    try {
      if (!operation.supported) {
        diagnostic(operation.code, { socketPath: operation.socketPath, message: operation.message });
      } else {
        const terminal = tracker.finish();
        if (!terminal.digest) {
          diagnostic(terminal.overflow ? 'terminal_frame_too_large' : 'missing_terminal_digest');
        } else await invokePostPush(operation, terminal.digest);
      }
      if (!cancelled && !proxy.destroyed) {
        ended = true;
        proxy.end();
      }
    } catch (error) {
      diagnostic('posthook_exception', { message: error instanceof Error ? error.message : String(error) });
      if (!cancelled && !proxy.destroyed) {
        ended = true;
        proxy.end();
      }
    }
  });
  return proxy;
}

function patchImage(Image: unknown, meta?: OperationMetadata): void {
  if (typeof Image !== 'function' || !('prototype' in Image)) return;
  const imageConstructor = Image as ImageConstructor;
  if (!imageConstructor.prototype || typeof imageConstructor.prototype.push !== 'function') return;
  if ((imageConstructor.prototype.push as PushFunction & Record<symbol, unknown>)[PATCHED]) return;

  const original = imageConstructor.prototype.push;
  function chalkPostPush(
    this: DockerodeImageLike,
    opts?: Dockerode.ImagePushOptions | PushCallback,
    callback?: PushCallback | Dockerode.AuthConfig,
    auth?: Dockerode.AuthConfig,
  ): Promise<PushResult> | void {
    const rawArgs = Array.from(arguments) as PushArguments;
    const normalizedOpts = typeof opts === 'function' ? {} : (opts || {});
    const callbackFn = typeof opts === 'function' ? opts : callback as PushCallback | undefined;
    const operationOpts: PushOptions = { ...normalizedOpts };
    operationOpts.authconfig = normalizedOpts.authconfig ||
      (typeof callback === 'function' ? auth : callback);
    let operation: Operation;
    try {
      operation = supportedOperation(this, operationOpts, meta);
    } catch (error) {
      operation = {
        supported: false,
        code: 'instrumentation_exception',
        message: error instanceof Error ? error.message : String(error),
      };
    }

    if (callbackFn === undefined) {
      let result: Promise<PushResult> | void;
      try {
        result = original.apply(this, rawArgs);
      } catch (error) {
        throw error;
      }
      if (!result || typeof result.then !== 'function') return result;
      return result.then((value: PushResult) => {
        if (normalizedOpts.stream === false) return finishBuffered(value, operation);
        return finishStream(value as Readable, operation);
      });
    }

    const self = this;
    const replacement: PushCallback = function (error, value) {
      if (error) return callbackFn(error, value);
      if (normalizedOpts.stream === false) {
        finishBuffered(value, operation).then(
          (result) => callbackFn(null, result),
          () => callbackFn(null, value),
        );
      } else {
        callbackFn(null, finishStream(value as Readable, operation));
      }
    };
    const args = Array.from(rawArgs) as PushArguments;
    if (typeof opts === 'function') args[0] = replacement;
    else args[1] = replacement;
    return original.apply(self, args);
  }
  Object.defineProperty(chalkPostPush, PATCHED, { value: true });
  Object.defineProperty(chalkPostPush, 'name', { value: 'push' });
  imageConstructor.prototype.push = chalkPostPush;
}

export {
  createTerminalTracker,
  isSupportedDockerodeVersion,
  patchImage,
  postPushDeadline,
  repositoryWithoutTag,
  terminalDigest,
};
