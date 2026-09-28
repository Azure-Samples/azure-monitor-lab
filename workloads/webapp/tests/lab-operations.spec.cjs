const { test, expect } = require('@playwright/test');
const path = require('node:path');

const now = new Date('2026-09-11T12:00:00Z');
const target = { jobResourceId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.App/jobs/job-labops-demo', image: 'acrlabopsdemo.azurecr.io/lab-operations@sha256:' + 'a'.repeat(64), subscriptionId: '00000000-0000-0000-0000-000000000000', tenantId: '00000000-0000-0000-0000-000000000000', resourceGroup: 'rg-azure-monitor-lab' };
const actions = [
  ['start', 'Start Lab', 'start-the-lab.ps1', 'Starts stopped lab resources. Running resources incur charges.'],
  ['stop', 'Stop Lab', 'stop-the-lab.ps1', 'Deallocates VMs and VMSS instances, stops AKS, then stops the Web App hosting this Control Center.'],
  ['break', 'Break Lab', 'break-the-lab.ps1', 'Deallocates lab VMs, disrupts the AKS frontend, and increases application failures.'],
  ['restore', 'Restore Lab', 'restore-the-lab.ps1', 'Starts VMs and restores the demo frontend and load generator.'],
  ['ramp', 'Start Load Ramp', 'start-ramp.ps1', 'Replaces the previous ramp job and starts 60 minutes of traffic.'],
  ['cpu', 'Simulate High CPU', 'simulate-high-cpu.ps1', 'Runs a self-expiring 10-minute CPU load on both running demo VMs via Run Command. Performance, CPU credits, and telemetry charges are affected.'],
  ['logs', 'Send Custom Logs', 'send-custom-logs.ps1', 'Ingests sample audit events into the lab custom table.'],
  ['annotation', 'Add Release Marker', 'send-release-annotation.ps1', 'Writes a deployment or incident marker.']
].map(([id, title, file, impact]) => ({ id, title, script: `scripts/${file}`, impact }));
const proposalId = 'b'.repeat(32);
const runId = 'c'.repeat(32);
const operationRun = (operation = 'start', state = 'queued') => ({ id: runId, parameters: { operation, count: 0, name: '', category: '' }, target,
  submittedAt: now.toISOString(), state, message: state === 'succeeded' ? 'The approved script completed.' : 'The Azure runner is executing the approved operation.', executionName: 'job-labops-demo-execution',
  url: 'https://portal.azure.com/#resource' + target.jobResourceId + '/overview', steps: [{ name: 'Job accepted', state: 'succeeded' }, { name: 'Run approved operation', state: state === 'succeeded' ? 'succeeded' : 'running' }] });

async function prepare(page, options = {}) {
  const calls = { prepared: [], approvals: [], referrers: [], reads: 0, catalogs: 0 };
  let runs = options.runs || [];
  await page.clock.install({ time: now });
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: target.resourceGroup, appService: 'app-amlab-demo' } }));
  await page.route('**/api/operations/catalog', route => {
    calls.catalogs++;
    return route.fulfill({ status: options.status || 200, json: { available: options.available !== false, message: options.message || 'Runner verified.', actions, target, runs } });
  });
  await page.route('**/api/operations/prepare', route => {
    const input = route.request().postDataJSON();
    calls.prepared.push(input);
    calls.referrers.push(route.request().headers().referer);
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    return route.fulfill({ json: { state: 'approval_required', proposal: { id: proposalId, action: actions.find(action => action.id === input.operation),
      parameters: { count: 0, name: '', category: '', ...input }, target, expiresAt: new Date(now.getTime() + 300000).toISOString() } } });
  });
  await page.route('**/api/operations/approval', route => {
    const input = route.request().postDataJSON();
    calls.approvals.push(input);
    if (!input.approve) return route.fulfill({ json: { state: 'declined' } });
    if (options.lostApproval) return route.abort('failed');
    runs = [operationRun(calls.prepared.at(-1).operation, options.unknown ? 'dispatch_unknown' : 'queued')];
    return route.fulfill({ status: 202, json: { run: runs[0] } });
  });
  await page.route('**/api/operations/runs/*', route => {
    calls.reads++;
    return route.fulfill({ json: { run: operationRun(runs[0]?.parameters.operation || 'start', options.nextState || 'succeeded') } });
  });
  await page.goto('/');
  expect(calls.catalogs).toBe(0);
  await page.getByRole('tab', { name: 'Lab Operations', exact: true }).click();
  await expect(page.locator('#operations-status')).toHaveText(options.message || 'Runner verified.');
  return calls;
}

async function review(page, operation) {
  await page.getByRole('button', { name: actions.find(action => action.id === operation).title, exact: true }).click();
  await expect(page.locator('#operation-dialog')).toBeVisible();
  if (operation === 'logs') await page.getByLabel('Event count', { exact: true }).fill('25');
  if (operation === 'annotation') {
    await page.getByLabel('Marker name', { exact: true }).fill('Release 1.2 (demo)');
    await page.getByLabel('Marker category').selectOption('Incident');
  }
  await page.getByRole('button', { name: 'Review Operation', exact: true }).click();
  await expect(page.locator('#operation-approve-form')).toBeVisible();
}

for (const action of actions) {
  test(`Lab Operations reviews ${action.title} with frozen parameters and cancellation never executes`, async ({ page }) => {
    const calls = await prepare(page);
    await review(page, action.id);
    const expected = { operation: action.id, ...(action.id === 'logs' ? { count: 25 } : {}), ...(action.id === 'annotation' ? { name: 'Release 1.2 (demo)', category: 'Incident' } : {}) };
    expect(calls.prepared).toEqual([expected]);
    expect(calls.approvals).toEqual([]);
    await expect(page.locator('#operation-preview')).toContainText(action.script);
    await expect(page.locator('#operation-preview')).toContainText(target.image);
    await expect(page.locator('#operation-preview')).toContainText(target.resourceGroup);
    await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(page.locator('#operation-dialog')).toBeHidden();
    await expect.poll(() => calls.approvals).toEqual([{ proposalId, resourceGroup: '', approve: false }]);
  });
}

test('Lab Operations requires target confirmation and consent, then tracks a single independent run', async ({ page }) => {
  const calls = await prepare(page);
  await review(page, 'start');
  await page.getByLabel('Confirm resource group').fill('wrong-group');
  await page.getByLabel('I approve these changes and associated Azure charges.').check();
  await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
  await page.getByLabel('Confirm resource group').fill(target.resourceGroup);
  await page.getByRole('button', { name: 'Approve & Run' }).click();
  await expect(page.locator('#operation-dialog')).toBeHidden();
  expect(calls.approvals).toEqual([{ proposalId, resourceGroup: target.resourceGroup, approve: true }]);
  await expect(page.locator('#operations-runs')).toContainText('Queued');
  await expect(page.getByRole('button', { name: 'Break Lab', exact: true })).toBeDisabled();
  await expect(page.locator('#total')).toHaveText('0');
  await page.clock.fastForward(11000);
  await expect(page.locator('#operations-runs')).toContainText('Succeeded');
  await expect(page.locator('#operations-runs')).toContainText('Run approved operation');
  await expect(page.getByRole('link', { name: 'Open Azure job' })).toHaveAttribute('href', operationRun().url);
  await expect(page.getByRole('button', { name: 'Break Lab', exact: true })).toBeEnabled();
  await page.clock.fastForward(60000);
  expect(calls.reads).toBe(1);
  expect(calls.approvals).toHaveLength(1);
});

test('Lab Operations CPU simulation requires approval and stays disabled with an older runner catalog', async ({ page }) => {
  const calls = await prepare(page);
  await expect(page.locator('[data-operation="cpu"] svg.lucide-cpu')).toHaveCount(1);
  await review(page, 'cpu');
  await expect(page.locator('#operation-impact')).toContainText('10-minute');
  await expect(page.locator('#operation-impact')).toContainText('both running demo VMs');
  await expect(page.locator('#operation-count-field')).toBeHidden();
  await expect(page.locator('#operation-marker-fields')).toBeHidden();
  expect(calls.approvals).toEqual([]);
  await page.getByLabel('Confirm resource group').fill(target.resourceGroup);
  await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
  await page.getByLabel('I approve these changes and associated Azure charges.').check();
  await page.getByRole('button', { name: 'Approve & Run' }).click();
  expect(calls.prepared).toEqual([{ operation: 'cpu' }]);
  expect(calls.approvals).toEqual([{ proposalId, resourceGroup: target.resourceGroup, approve: true }]);
  await expect(page.getByRole('button', { name: 'Simulate High CPU', exact: true })).toBeDisabled();
  await expect(page.locator('#operations-runs')).toContainText('Simulate High CPU');
  await page.clock.fastForward(11000);
  await page.route('**/api/operations/catalog', route => route.fulfill({ json: {
    available: true, message: 'Runner verified.', actions: actions.filter(action => action.id !== 'cpu'), target, runs: []
  } }));
  await page.getByRole('button', { name: 'Refresh runner connection and history' }).click();
  await expect(page.getByRole('button', { name: 'Simulate High CPU', exact: true })).toBeDisabled();
  expect(calls.approvals).toHaveLength(1);
});

test('Lab Operations restores journal history and only checks active runs while the tab is visible', async ({ page }) => {
  const calls = await prepare(page, { runs: [operationRun('restore', 'running')], nextState: 'running' });
  await page.clock.fastForward(11000);
  await expect.poll(() => calls.reads).toBe(1);
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.clock.fastForward(60000);
  expect(calls.reads).toBe(1);
  await page.getByRole('tab', { name: 'Lab Operations' }).click();
  await page.clock.fastForward(11000);
  await expect.poll(() => calls.reads).toBe(2);
  await page.reload();
  await page.getByRole('tab', { name: 'Lab Operations' }).click();
  await expect(page.locator('#operations-runs')).toContainText('Restore Lab');
  await expect(page.getByRole('button', { name: 'Start Lab', exact: true })).toBeDisabled();
  expect(calls.approvals).toHaveLength(0);
});

test('Lab Operations expires approvals and does not resend a lost approval response', async ({ page }) => {
  const calls = await prepare(page, { lostApproval: true });
  await review(page, 'logs');
  await page.getByLabel('Confirm resource group').fill(target.resourceGroup);
  await page.getByLabel('I approve these changes and associated Azure charges.').check();
  await page.clock.fastForward(301000);
  await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
  expect(calls.approvals).toHaveLength(0);
  await page.reload();
  await page.clock.setSystemTime(now);
  await page.getByRole('tab', { name: 'Lab Operations' }).click();
  await review(page, 'logs');
  await page.getByLabel('Confirm resource group').fill(target.resourceGroup);
  await page.getByLabel('I approve these changes and associated Azure charges.').check();
  await page.getByRole('button', { name: 'Approve & Run' }).click();
  await expect(page.locator('#operation-error')).toContainText('cannot be resent');
  await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
  expect(calls.approvals).toHaveLength(1);
});

test('Lab Operations reports disabled/sign-in states and renders runner results as inert text', async ({ page }) => {
  await prepare(page, { available: false, status: 401, message: 'Sign in with an approved operator account.' });
  await expect(page.locator('#operations-sign-in')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Start Lab', exact: true })).toBeDisabled();
  await page.route('**/api/operations/catalog', route => route.fulfill({ json: { available: false, message: 'Runner not configured.', actions, target, runs: [] } }));
  await page.getByRole('button', { name: 'Refresh runner connection and history' }).click();
  await expect(page.locator('#operations-status')).toHaveText('Runner not configured.');
  await expect(page.locator('#operations-sign-in')).toBeHidden();
  const run = { ...operationRun('start', 'failed'), message: '<img src=x onerror="window.injected=true">', url: 'javascript:alert(1)' };
  await page.route('**/api/operations/catalog', route => route.fulfill({ json: { available: true, message: 'Runner verified.', actions, target, runs: [run] } }));
  await page.getByRole('button', { name: 'Refresh runner connection and history' }).click();
  await expect(page.locator('#operations-runs')).toContainText('<img');
  await expect(page.getByRole('link', { name: 'Open Azure job' })).toHaveCount(0);
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
});

test('Lab Operations API is disabled by default and enforces operator and same-origin guards', async ({ request }) => {
  const headers = { 'X-Amlab-Agent-Request': 'true' };
  const catalog = await request.get('/api/operations/catalog');
  expect(catalog.status()).toBe(200);
  expect((await catalog.json()).available).toBe(false);
  expect((await catalog.json()).actions).toHaveLength(8);
  expect(catalog.headers()['cache-control']).toBe('no-store');
  expect((await request.post('/api/operations/prepare', { data: { operation: 'start' } })).status()).toBe(403);
  expect((await request.post('/api/operations/prepare', { headers: { ...headers, Host: 'attacker.example' }, data: { operation: 'start' } })).status()).toBe(401);
  expect((await request.post('/api/operations/approval', { headers: { ...headers, Origin: 'https://attacker.example' }, data: { proposalId, resourceGroup: target.resourceGroup, approve: true } })).status()).toBe(403);
  expect((await request.post('/api/operations/prepare', { headers, data: { operation: 'teardown' } })).status()).toBe(400);
  expect((await request.post('/api/operations/prepare', { headers, data: { operation: 'start', resourceGroup: 'other' } })).status()).toBe(503);
});

test('Lab Operations reports an empty review error without losing the HTTP status or approving a run', async ({ page }) => {
  const calls = await prepare(page);
  await page.route('**/api/operations/prepare', route => route.fulfill({ status: 403, body: '' }));
  await page.getByRole('button', { name: 'Start Lab', exact: true }).click();
  await page.getByRole('button', { name: 'Review Operation', exact: true }).click();
  await expect(page.locator('#operation-error')).toContainText('HTTP 403');
  await expect(page.locator('#operation-error')).not.toContainText('JSON');
  await expect(page.locator('#operation-approve-form')).toBeHidden();
  expect(calls.approvals).toEqual([]);
});

test('Lab Operations sends a same-origin referrer for authenticated Review but never to external sites', async ({ page }) => {
  const calls = await prepare(page);
  await review(page, 'start');
  expect(calls.referrers).toEqual([page.url()]);
  expect(calls.approvals).toEqual([]);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  let externalReferrer;
  await page.route('https://external.example/privacy-check', route => {
    externalReferrer = route.request().headers().referer;
    return route.fulfill({ body: 'ok', headers: { 'access-control-allow-origin': '*' } });
  });
  await page.evaluate(() => fetch('https://external.example/privacy-check'));
  expect(externalReferrer).toBeUndefined();
});

for (const response of [{ status: 401, body: '' }, { status: 502, body: '<html>Gateway failure</html>' }, { status: 200, body: '' }]) {
  test(`Lab Operations handles a non-JSON HTTP ${response.status} approval without retrying it`, async ({ page }) => {
    const calls = await prepare(page);
    await review(page, 'start');
    let submissions = 0;
    await page.route('**/api/operations/approval', route => {
      submissions++;
      return route.fulfill(response);
    });
    await page.getByLabel('Confirm resource group').fill(target.resourceGroup);
    await page.getByLabel('I approve these changes and associated Azure charges.').check();
    await page.getByRole('button', { name: 'Approve & Run' }).click();
    await expect(page.locator('#operation-error')).toContainText(`HTTP ${response.status}`);
    await expect(page.locator('#operation-error')).toContainText('cannot be resent');
    await expect(page.getByRole('button', { name: 'Approve & Run' })).toBeDisabled();
    expect(submissions).toBe(1);
    expect(calls.approvals).toEqual([]);
  });
}

for (const width of [1440, 390, 320]) {
  test(`Lab Operations review and activity fit at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 740 });
    await prepare(page, { runs: [operationRun('annotation', 'succeeded')] });
    await page.evaluate(() => document.fonts.ready);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await expect(page.locator('.mobile-feedback')).toBeHidden();
    await page.screenshot({ path: testInfo.outputPath(`lab-operations-${width}.png`), fullPage: true });
    if (process.env.UPDATE_CONTROL_CENTER_SCREENSHOT === '1' && width === 1440) await page.screenshot({ path: path.resolve(__dirname, '../../../docs/images/lab-operations.png'), fullPage: true });
    await review(page, 'cpu');
    await page.screenshot({ path: testInfo.outputPath(`lab-operation-review-${width}.png`), fullPage: true });
    const clipped = await page.locator('button, input, h1, h2, .operation-details dd').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
    expect(clipped).toEqual([]);
    expect(errors).toEqual([]);
  });
}