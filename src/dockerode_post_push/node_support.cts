// Keep this policy aligned with the official Node.js release schedule.
// Last reviewed: 2026-08-11.
const NODE_RELEASE_SCHEDULE_URL = 'https://github.com/nodejs/Release#release-schedule';
const NODE_SUPPORT_LAST_REVIEWED = '2026-08-11';

type DisabledNodeSupportCode =
  | 'below_minimum'
  | 'invalid_version'
  | 'missing_capability'
  | 'outside_reviewed_set'
  | 'prerelease';

interface NodeCapabilities {
  registerHooks?: unknown;
  legacyJsLoader?: unknown;
}

interface DisabledNodeSupport {
  enabled: false;
  mode: 'disabled';
  version: string;
  code: DisabledNodeSupportCode;
  reason: string;
}

interface SupportedNodeSupport {
  enabled: true;
  mode: 'supported';
  version: string;
  code: 'supported';
  loader: 'hooks' | 'legacy';
}

type NodeSupport = DisabledNodeSupport | SupportedNodeSupport;

function disabled(version: string, code: DisabledNodeSupportCode, reason: string): NodeSupport {
  return { enabled: false, mode: 'disabled', version, code, reason };
}

function classifyNodeSupport(version: unknown, capabilities: NodeCapabilities): NodeSupport {
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
  if (major === 22 && minor < 15) {
    return disabled(normalized, 'below_minimum', 'Node 22.15.0 or newer is required');
  }
  if (major !== 20 && major !== 22 && major !== 24 && major !== 26) {
    return disabled(normalized, 'outside_reviewed_set', `Node ${major} is outside the reviewed support set`);
  }

  const loader = major === 20 ? 'legacy' : 'hooks';
  const capability = loader === 'legacy' ? capabilities.legacyJsLoader : capabilities.registerHooks;
  if (typeof capability !== 'function') {
    return disabled(normalized, 'missing_capability', 'the required module loader is unavailable');
  }

  return { enabled: true, mode: 'supported', version: normalized, code: 'supported', loader };
}

function diagnosticForNodeSupport(classification: NodeSupport): string | null {
  const prefix = `[chalk-dockerode] Node ${classification.version || '<invalid>'}`;
  const review = `policy last reviewed ${NODE_SUPPORT_LAST_REVIEWED}; ${NODE_RELEASE_SCHEDULE_URL}`;
  switch (classification.code) {
    case 'outside_reviewed_set':
      return `${prefix} is outside the reviewed support set; instrumentation skipped (${review})`;
    case 'missing_capability':
      return `${prefix} required module loader is unavailable; instrumentation skipped`;
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
