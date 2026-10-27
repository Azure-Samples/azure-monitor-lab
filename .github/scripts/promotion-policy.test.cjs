'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { enforcePromotion, checkName } = require('./promotion-policy.cjs');

const mainSha = '1'.repeat(40);
const integrationSha = '2'.repeat(40);
const mergeSha = '3'.repeat(40);

function fixture() {
  const repository = { id: 123, full_name: 'example/lab' };
  const pull = {
    number: 42, state: 'open', mergeable: true, merge_commit_sha: mergeSha,
    base: { ref: 'main', sha: mainSha, repo: { ...repository } },
    head: { ref: 'integration', sha: integrationSha, repo: { ...repository } }
  };
  const calls = { checks: [], closes: [], comments: [], failures: [], comparisons: [] };
  const tips = { main: mainSha, integration: integrationSha };
  const state = {
    pull, latest: null, tips, reads: 0,
    comparison: { status: 'ahead', merge_base_commit: { sha: mainSha } }
  };
  const github = { rest: {
    pulls: {
      get: async () => ({ data: ++state.reads > 1 && state.latest ? state.latest : state.pull }),
      update: async value => { calls.closes.push(value); }
    },
    git: { getRef: async ({ ref }) => ({ data: { object: { sha: state.tips[ref.slice('heads/'.length)] } } }) },
    checks: { create: async value => { calls.checks.push(value); } },
    issues: { createComment: async value => { calls.comments.push(value); } },
    repos: { compareCommitsWithBasehead: async value => {
      calls.comparisons.push(value);
      return { data: state.comparison };
    } }
  } };
  const context = {
    repo: { owner: 'example', repo: 'lab' }, payload: { pull_request: { number: 42 } },
    serverUrl: 'https://github.com', runId: 1234
  };
  const core = { info() {}, setFailed: message => calls.failures.push(message) };
  return { state, calls, github, context, core, run: () => enforcePromotion({ github, context, core }) };
}

test('accepts current same-repository integration and reports success on the required head context', async () => {
  const setup = fixture();
  await setup.run();
  assert.equal(setup.calls.checks.length, 1);
  assert.equal(setup.calls.checks[0].name, checkName);
  assert.equal(setup.calls.checks[0].conclusion, 'success');
  assert.equal(setup.calls.checks[0].head_sha, integrationSha);
  assert.equal(setup.calls.closes.length, 0);
  assert.equal(setup.calls.failures.length, 0);
});

for (const branch of ['dev', 'feature/change', 'Integration', 'integration-copy']) {
  test(`rejects and closes ${branch} -> main even with the same head SHA as integration`, async () => {
    const setup = fixture();
    setup.state.pull.head.ref = branch;
    await setup.run();
    assert.equal(setup.calls.checks[0].conclusion, 'failure');
    assert.equal(setup.calls.checks[0].head_sha, integrationSha);
    assert.deepEqual(setup.calls.closes, [{ owner: 'example', repo: 'lab', pull_number: 42, state: 'closed' }]);
    assert.equal(setup.calls.comments.length, 1);
    assert.equal(setup.calls.failures.length, 1);
    assert.equal(setup.calls.comparisons.length, 0);
  });
}

test('rejects a fork branch named integration', async () => {
  const setup = fixture();
  setup.state.pull.head.repo = { id: 456, full_name: 'fork/lab' };
  await setup.run();
  assert.equal(setup.calls.closes.length, 1);
  assert.equal(setup.calls.checks[0].conclusion, 'failure');
});

test('checks repository identity as well as name', async () => {
  const setup = fixture();
  setup.state.pull.head.repo.id = 456;
  await setup.run();
  assert.equal(setup.calls.closes.length, 1);
});

test('does not interfere with dev -> integration', async () => {
  const setup = fixture();
  setup.state.pull.base.ref = 'integration';
  setup.state.pull.head.ref = 'dev';
  await setup.run();
  assert.equal(setup.calls.checks.length, 0);
  assert.equal(setup.calls.closes.length, 0);
  assert.equal(setup.calls.failures.length, 0);
});

test('does not act on already closed PRs', async () => {
  const setup = fixture();
  setup.state.pull.state = 'closed';
  await setup.run();
  assert.equal(setup.calls.checks.length, 0);
  assert.equal(setup.calls.closes.length, 0);
});

test('does not close a disallowed PR if it has since been retargeted to integration', async () => {
  const setup = fixture();
  setup.state.pull.head.ref = 'dev';
  setup.state.latest = structuredClone(setup.state.pull);
  setup.state.latest.base.ref = 'integration';
  await setup.run();
  assert.equal(setup.calls.closes.length, 0);
  assert.equal(setup.calls.comments.length, 0);
});

test('rejects promotion when integration does not contain the latest main', async () => {
  const setup = fixture();
  setup.state.comparison = { status: 'diverged', merge_base_commit: { sha: '0'.repeat(40) } };
  await setup.run();
  assert.equal(setup.calls.checks[0].conclusion, 'failure');
  assert.equal(setup.calls.closes.length, 0);
  assert.equal(setup.calls.failures.length, 1);
});

for (const branch of ['main', 'integration']) {
  test(`rejects a stale ${branch} tip`, async () => {
    const setup = fixture();
    setup.state.tips[branch] = '4'.repeat(40);
    await setup.run();
    assert.equal(setup.calls.checks[0].conclusion, 'failure');
    assert.equal(setup.calls.closes.length, 0);
  });
}

for (const mergeable of [null, false]) {
  test(`fails closed when the test merge is not ready (${mergeable})`, async () => {
    const setup = fixture();
    setup.state.pull.mergeable = mergeable;
    setup.state.pull.merge_commit_sha = null;
    await setup.run();
    assert.equal(setup.calls.checks.length, 0);
    assert.equal(setup.calls.failures.length, 1);
    assert.equal(setup.calls.closes.length, 0);
  });
}

test('never publishes success for a PR updated during validation', async () => {
  const setup = fixture();
  setup.state.latest = structuredClone(setup.state.pull);
  setup.state.latest.head.sha = '4'.repeat(40);
  await setup.run();
  assert.equal(setup.calls.checks.length, 0);
  assert.equal(setup.calls.failures.length, 1);
});

test('propagates API failures without publishing success', async () => {
  const setup = fixture();
  setup.github.rest.git.getRef = async () => { throw new Error('API unavailable'); };
  await assert.rejects(setup.run(), /API unavailable/);
  assert.equal(setup.calls.checks.length, 0);
  assert.equal(setup.calls.closes.length, 0);
});

test('requires a valid PR event', async () => {
  const setup = fixture();
  setup.context.payload = {};
  await assert.rejects(setup.run(), /pull request event/);
});