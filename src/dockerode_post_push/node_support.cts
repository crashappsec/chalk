// Keep this policy aligned with the official Node.js release schedule.
// Last reviewed: 2026-08-11.
const NODE_RELEASE_SCHEDULE_URL = 'https://github.com/nodejs/Release#release-schedule';
const NODE_SUPPORT_LAST_REVIEWED = '2026-08-11';

type NodeSupportMode = 'disabled' | 'supported' | 'best_effort';
type NodeSupportCode =
  | 'below_minimum'
  | 'best_effort'
  | 'eol_release'
  | 'invalid_version'
  | 'missing_capability'
  | 'non_lts_release'
  | 'prerelease'
  | 'supported';

interface NodeSupport {
  enabled: boolean;
  mode: NodeSupportMode;
  version: string;
  code: NodeSupportCode;
  reason?: string;
}

type RegisterHooksCapability = unknown;

function disabled(version: string, code: NodeSupportCode, reason: string): NodeSupport {
  return { enabled: false, mode: 'disabled', version, code, reason };
}

function classifyNodeSupport(version: unknown, registerHooks: RegisterHooksCapability): NodeSupport {
  const normalized = String(version || '');
  const match = /^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(normalized);
  if (!match) {
    return disabled(normalized, 'invalid_version', 'the Node version is invalid');
  }

  const major = Number(match[1]!);
  const minor = Number(match[2]!);
  const patch = Number(match[3]!);
  if (![major, minor, patch].every(Number.isSafeInteger)) {
    return disabled(normalized, 'invalid_version', 'the Node version is invalid');
  }
  if (match[4]) {
    return disabled(normalized, 'prerelease', 'prerelease builds are not supported');
  }
  let mode: 'supported' | 'best_effort';

  if (major <= 21 || major === 23 || major === 25) {
    return disabled(normalized, 'eol_release', `Node ${major} is excluded because it is end-of-life`);
  }
  if (major === 22 && minor < 15) {
    return disabled(normalized, 'below_minimum', 'Node 22.15.0 or newer is required');
  }
  if (major === 22 || major === 24 || major === 26) {
    mode = 'supported';
  } else if (major > 26 && major % 2 === 0) {
    mode = 'best_effort';
  } else {
    return disabled(normalized, 'non_lts_release', `Node ${major} is an odd-numbered non-LTS release`);
  }

  if (typeof registerHooks !== 'function') {
    return disabled(normalized, 'missing_capability', 'module.registerHooks() is unavailable');
  }

  return { enabled: true, mode, version: normalized, code: mode };
}

function diagnosticForNodeSupport(classification: NodeSupport): string | null {
  const prefix = `[chalk-dockerode] Node ${classification.version || '<invalid>'}`;
  const review = `policy last reviewed ${NODE_SUPPORT_LAST_REVIEWED}; ${NODE_RELEASE_SCHEDULE_URL}`;
  switch (classification.code) {
    case 'eol_release':
      return `${prefix} is excluded as end-of-life; instrumentation skipped (${review})`;
    case 'non_lts_release':
      return `${prefix} is excluded as an odd-numbered non-LTS release; instrumentation skipped (${review})`;
    case 'missing_capability':
      return `${prefix} module.registerHooks() is unavailable; instrumentation skipped`;
    case 'best_effort':
      return `${prefix} is newer than the reviewed support set; enabling best-effort instrumentation (${review})`;
    case 'below_minimum':
    case 'prerelease':
    case 'invalid_version':
      return `${prefix} is unsupported: ${classification.reason}; instrumentation skipped (${review})`;
    default:
      return null;
  }
}

export {
  NODE_RELEASE_SCHEDULE_URL,
  NODE_SUPPORT_LAST_REVIEWED,
  classifyNodeSupport,
  diagnosticForNodeSupport,
};
