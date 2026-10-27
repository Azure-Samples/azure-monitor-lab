'use strict';

const checkName = 'Integration promotion gate';
const routingMessage = 'Only this repository\'s integration branch may target main. Open your change against integration, validate it there, then open integration -> main.';

function isIntegrationSource(pull, repository) {
  return pull.head?.ref === 'integration'
    && pull.head.repo?.full_name === repository
    && pull.head.repo.id === pull.base.repo.id;
}

function hasTestMerge(pull) {
  return pull.mergeable === true && /^[0-9a-f]{40}$/.test(pull.merge_commit_sha || '');
}

async function enforcePromotion({ github, context, core }) {
  const repository = `${context.repo.owner}/${context.repo.repo}`;
  const pullNumber = context.payload.pull_request?.number;
  if (!Number.isSafeInteger(pullNumber) || pullNumber < 1) {
    throw new Error('A pull request event is required.');
  }

  const getPull = async () => (await github.rest.pulls.get({
    ...context.repo, pull_number: pullNumber
  })).data;
  const getTip = async branch => (await github.rest.git.getRef({
    ...context.repo, ref: `heads/${branch}`
  })).data.object.sha;
  const publish = async (pull, conclusion, summary) => {
    if (!hasTestMerge(pull)) return;
    await github.rest.checks.create({
      ...context.repo,
      name: checkName,
      head_sha: pull.head.sha,
      status: 'completed',
      conclusion,
      external_id: `promotion:${pullNumber}:${pull.head.sha}:${pull.base.sha}`,
      details_url: `${context.serverUrl}/${repository}/actions/runs/${context.runId}`,
      output: { title: checkName, summary }
    });
  };

  const pull = await getPull();
  if (pull.state !== 'open' || pull.base.ref !== 'main' || pull.base.repo.full_name !== repository) {
    core.info('This pull request is not an open promotion to this repository\'s main branch.');
    return;
  }

  if (!isIntegrationSource(pull, repository)) {
    await publish(pull, 'failure', routingMessage);
    const latest = await getPull();
    if (latest.state === 'open' && latest.base.ref === 'main'
      && latest.base.repo.full_name === repository && !isIntegrationSource(latest, repository)) {
      await github.rest.pulls.update({ ...context.repo, pull_number: pullNumber, state: 'closed' });
      await github.rest.issues.createComment({ ...context.repo, issue_number: pullNumber, body: routingMessage });
    }
    core.setFailed(routingMessage);
    return;
  }

  const mainSha = await getTip('main');
  const integrationSha = await getTip('integration');
  if (pull.base.sha !== mainSha || pull.head.sha !== integrationSha || !hasTestMerge(pull)) {
    const message = 'The promotion must use the current main and integration tips and have a conflict-free test merge. Update integration or rerun this check after GitHub computes the merge.';
    await publish(pull, 'failure', message);
    core.setFailed(message);
    return;
  }

  const comparison = (await github.rest.repos.compareCommitsWithBasehead({
    ...context.repo, basehead: `${mainSha}...${integrationSha}`
  })).data;
  if (!['ahead', 'identical'].includes(comparison.status)
    || comparison.merge_base_commit.sha !== mainSha) {
    const message = 'Bring the latest main changes into integration through a pull request and validate the combined result before promoting it.';
    await publish(pull, 'failure', message);
    core.setFailed(message);
    return;
  }

  const latest = await getPull();
  if (latest.state !== 'open' || latest.base.ref !== 'main'
    || latest.base.repo.full_name !== repository || !isIntegrationSource(latest, repository)
    || latest.head.sha !== integrationSha || latest.base.sha !== mainSha
    || latest.merge_commit_sha !== pull.merge_commit_sha || !hasTestMerge(latest)
    || await getTip('main') !== mainSha || await getTip('integration') !== integrationSha) {
    core.setFailed('The pull request or branch tips changed during validation. No successful promotion check was published; rerun for the current revision.');
    return;
  }

  await publish(latest, 'success', 'The source is this repository\'s current integration branch, it contains the current main, and the exact PR test-merge commit was validated. Required CI and a manual merge are still required.');
  core.info('Integration source and main ancestry verified. No code was merged.');
}

module.exports = { enforcePromotion, isIntegrationSource, checkName };