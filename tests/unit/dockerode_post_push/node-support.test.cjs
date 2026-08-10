'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  NODE_RELEASE_SCHEDULE_URL,
  NODE_SUPPORT_LAST_REVIEWED,
  classifyNodeSupport,
  diagnosticForNodeSupport,
} = require('../../../src/dockerode_post_push/node_support.cjs');

const registerHooks = () => {};

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
    assert.match(diagnosticForNodeSupport(result), /excluded as end-of-life/);
  }
});

test('Node 22 before 22.15 is below the minimum', () => {
  const result = classifyNodeSupport('22.14.0', registerHooks);
  assert.equal(result.enabled, false);
  assert.equal(result.code, 'below_minimum');
  assert.match(diagnosticForNodeSupport(result), /Node 22\.15\.0 or newer is required/);
});

test('future capable majors activate in best-effort mode', () => {
  const result = classifyNodeSupport('27.0.0', registerHooks);
  assert.equal(result.enabled, true);
  assert.equal(result.mode, 'best_effort');
  assert.match(diagnosticForNodeSupport(result), /enabling best-effort instrumentation/);
});

test('missing registerHooks always fails open for otherwise capable releases', () => {
  for (const version of ['22.15.0', '24.0.0', '26.0.0', '27.0.0']) {
    const result = classifyNodeSupport(version, undefined);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'missing_capability');
    assert.match(diagnosticForNodeSupport(result), /module\.registerHooks\(\) is unavailable/);
  }
});

test('invalid versions fail open with policy metadata in their diagnostic', () => {
  for (const version of ['not-semver', '999999999999999999999.0.0']) {
    const result = classifyNodeSupport(version, registerHooks);
    const diagnostic = diagnosticForNodeSupport(result);
    assert.equal(result.enabled, false);
    assert.equal(result.code, 'invalid_version');
    assert.match(diagnostic, /instrumentation skipped/);
    assert.match(diagnostic, new RegExp(NODE_SUPPORT_LAST_REVIEWED));
    assert.match(diagnostic, new RegExp(NODE_RELEASE_SCHEDULE_URL.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});
