import assert = require('node:assert/strict');
import test = require('node:test');
import {
  NODE_RELEASE_SCHEDULE_URL,
  NODE_SUPPORT_LAST_REVIEWED,
  classifyNodeSupport,
  diagnosticForNodeSupport,
} from '../../../src/dockerode_post_push/node_support.cjs';

const capabilities = {
  registerHooks: () => {},
  legacyJsLoader: () => {},
};

function supportDiagnostic(result: ReturnType<typeof classifyNodeSupport>): string {
  const message = diagnosticForNodeSupport(result);
  assert.notEqual(message, null);
  return message!;
}

test('the reviewed Node releases are supported with their required loader', () => {
  for (const version of ['20.0.0', '20.99.0', '22.15.0', '22.99.0', '24.0.0', '26.0.0']) {
    assert.deepEqual(classifyNodeSupport(version, capabilities), {
      enabled: true,
      mode: 'supported',
      version,
      code: 'supported',
      loader: version.startsWith('20.') ? 'legacy' : 'hooks',
    });
  }
});

test('releases outside the reviewed set stay disabled', () => {
  for (const version of ['18.20.0', '21.7.3', '23.11.1', '25.8.0', '27.0.0', '28.0.0']) {
    const result = classifyNodeSupport(version, capabilities);
    assert.equal(result.enabled, false);
    assert.match(supportDiagnostic(result), /outside the reviewed support set/);
  }
});

test('Node 22 before 22.15 is below the minimum', () => {
  const result = classifyNodeSupport('22.14.0', capabilities);
  assert.equal(result.enabled, false);
  assert.equal(result.code, 'below_minimum');
  assert.match(supportDiagnostic(result), /Node 22\.15\.0 or newer is required/);
});

test('prereleases stay disabled while build metadata preserves release support', () => {
  for (const version of ['22.15.0-rc.1', '26.0.0-nightly20260101']) {
    const result = classifyNodeSupport(version, capabilities);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'prerelease');
    assert.match(supportDiagnostic(result), /prerelease builds are not supported/);
  }
  assert.equal(classifyNodeSupport('22.15.0+build.1', capabilities).mode, 'supported');
  assert.equal(classifyNodeSupport('26.0.0+meta', capabilities).mode, 'supported');
});

test('a missing version-specific loader fails open', () => {
  for (const [version, available] of [
    ['20.19.0', { registerHooks: capabilities.registerHooks }],
    ['22.15.0', { legacyJsLoader: capabilities.legacyJsLoader }],
    ['24.0.0', { legacyJsLoader: capabilities.legacyJsLoader }],
    ['26.0.0', { legacyJsLoader: capabilities.legacyJsLoader }],
  ] as const) {
    const result = classifyNodeSupport(version, available);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'missing_capability');
    assert.match(supportDiagnostic(result), /required module loader is unavailable/);
  }
});

test('invalid versions fail open with policy metadata in their diagnostic', () => {
  for (const version of ['not-semver', '999999999999999999999.0.0']) {
    const result = classifyNodeSupport(version, capabilities);
    const diagnostic = supportDiagnostic(result);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'invalid_version');
    assert.match(diagnostic, /instrumentation skipped/);
    assert.match(diagnostic, new RegExp(NODE_SUPPORT_LAST_REVIEWED));
    assert.match(diagnostic, new RegExp(NODE_RELEASE_SCHEDULE_URL.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});
