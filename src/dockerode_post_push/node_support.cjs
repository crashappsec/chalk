'use strict';

// Keep this policy aligned with the official Node.js release schedule.
// Last reviewed: 2026-08-10.
const NODE_RELEASE_SCHEDULE_URL = 'https://github.com/nodejs/Release#release-schedule';
const NODE_SUPPORT_LAST_REVIEWED = '2026-08-10';

function disabled(version, code, reason) {
  return { enabled: false, mode: 'disabled', version, code, reason };
}

function classifyNodeSupport(version, registerHooks) {
  const normalized = String(version || '');
  const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(normalized);
  if (!match) {
    return disabled(normalized, 'invalid_version', 'the Node version is invalid');
  }

  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);
  if (![major, minor, patch].every(Number.isSafeInteger)) {
    return disabled(normalized, 'invalid_version', 'the Node version is invalid');
  }
  let mode;

  if (major <= 21 || major === 23 || major === 25) {
    return disabled(normalized, 'eol_release', `Node ${major} is excluded because it is end-of-life`);
  }
  if (major === 22 && minor < 15) {
    return disabled(normalized, 'below_minimum', 'Node 22.15.0 or newer is required');
  }
  if (major === 22 || major === 24 || major === 26) {
    mode = 'supported';
  } else if (major > 26) {
    mode = 'best_effort';
  } else {
    return disabled(normalized, 'unsupported_release', `Node ${major} is not in the supported release set`);
  }

  if (typeof registerHooks !== 'function') {
    return disabled(normalized, 'missing_capability', 'module.registerHooks() is unavailable');
  }

  return { enabled: true, mode, version: normalized, code: mode };
}

function diagnosticForNodeSupport(classification) {
  const prefix = `[chalk-dockerode] Node ${classification.version || '<invalid>'}`;
  const review = `policy last reviewed ${NODE_SUPPORT_LAST_REVIEWED}; ${NODE_RELEASE_SCHEDULE_URL}`;
  switch (classification.code) {
    case 'eol_release':
      return `${prefix} is excluded as end-of-life; instrumentation skipped (${review})`;
    case 'missing_capability':
      return `${prefix} module.registerHooks() is unavailable; instrumentation skipped`;
    case 'best_effort':
      return `${prefix} is newer than the reviewed support set; enabling best-effort instrumentation (${review})`;
    case 'below_minimum':
    case 'unsupported_release':
    case 'invalid_version':
      return `${prefix} is unsupported: ${classification.reason}; instrumentation skipped (${review})`;
    default:
      return null;
  }
}

module.exports = {
  NODE_RELEASE_SCHEDULE_URL,
  NODE_SUPPORT_LAST_REVIEWED,
  classifyNodeSupport,
  diagnosticForNodeSupport,
};
