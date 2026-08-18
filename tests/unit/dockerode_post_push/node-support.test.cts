import assert = require('node:assert/strict');
import test = require('node:test');
import {
  NODE_RELEASE_SCHEDULE_URL,
  NODE_SUPPORT_LAST_REVIEWED,
  classifyNodeSupport,
  diagnosticForNodeSupport,
} from '../../../src/dockerode_post_push/node_support.cjs';

const registerHooks = () => {};

function supportDiagnostic(result: ReturnType<typeof classifyNodeSupport>): string {
  const message = diagnosticForNodeSupport(result);
  assert.notEqual(message, null);
  return message!;
}

test('maintained releases are supported when registerHooks exists', () => {
  for (const version of ['22.15.0', '22.99.0', '24.0.0', '26.0.0']) {
    assert.deepEqual(classifyNodeSupport(version, registerHooks), {
      enabled: true,
      mode: 'supported',
      version,
      code: 'supported',
    });
  }
});

test('known EOL releases stay disabled even when registerHooks is mocked', () => {
  for (const version of ['18.20.0', '20.19.0', '21.7.3', '23.11.1', '25.8.0']) {
    const result = classifyNodeSupport(version, registerHooks);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'eol_release');
    assert.match(supportDiagnostic(result), /excluded as end-of-life/);
  }
});

test('Node 22 before 22.15 is below the minimum', () => {
  const result = classifyNodeSupport('22.14.0', registerHooks);
  assert.equal(result.enabled, false);
  assert.equal(result.code, 'below_minimum');
  assert.match(supportDiagnostic(result), /Node 22\.15\.0 or newer is required/);
});

test('future capable even majors activate in best-effort mode', () => {
  for (const version of ['28.0.0', '40.1.0']) {
    const result = classifyNodeSupport(version, registerHooks);
    assert.equal(result.enabled, true);
    assert.equal(result.mode, 'best_effort');
    assert.match(supportDiagnostic(result), /enabling best-effort instrumentation/);
  }
});

test('future odd non-LTS majors stay disabled even when registerHooks exists', () => {
  for (const version of ['27.0.0', '29.5.0']) {
    const result = classifyNodeSupport(version, registerHooks);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'non_lts_release');
    assert.match(supportDiagnostic(result), /odd-numbered non-LTS release/);
  }
});

test('prereleases stay disabled while build metadata preserves release support', () => {
  for (const version of ['22.15.0-rc.1', '26.0.0-nightly20260101']) {
    const result = classifyNodeSupport(version, registerHooks);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'prerelease');
    assert.match(supportDiagnostic(result), /prerelease builds are not supported/);
  }
  assert.equal(classifyNodeSupport('22.15.0+build.1', registerHooks).mode, 'supported');
  assert.equal(classifyNodeSupport('26.0.0+meta', registerHooks).mode, 'supported');
});

test('missing registerHooks always fails open for otherwise capable releases', () => {
  for (const version of ['22.15.0', '24.0.0', '26.0.0', '28.0.0']) {
    const result = classifyNodeSupport(version, undefined);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'missing_capability');
    assert.match(supportDiagnostic(result), /module\.registerHooks\(\) is unavailable/);
  }
});

test('invalid versions fail open with policy metadata in their diagnostic', () => {
  for (const version of ['not-semver', '999999999999999999999.0.0']) {
    const result = classifyNodeSupport(version, registerHooks);
    const diagnostic = supportDiagnostic(result);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'invalid_version');
    assert.match(diagnostic, /instrumentation skipped/);
    assert.match(diagnostic, new RegExp(NODE_SUPPORT_LAST_REVIEWED));
    assert.match(diagnostic, new RegExp(NODE_RELEASE_SCHEDULE_URL.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});
