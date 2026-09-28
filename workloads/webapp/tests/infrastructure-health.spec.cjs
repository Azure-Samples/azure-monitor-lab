const { test, expect } = require('@playwright/test');
const path = require('node:path');

const now = new Date('2026-09-11T12:00:00Z');
const resourceBase = '/subscriptions/example-subscription/resourceGroups/rg-azure-monitor-lab/providers/';
const resource = (name, type, state, detail) => ({
  id: resourceBase + type + '/' + name, name, type, state, location: 'northeurope', provisioningState: 'Succeeded',
  portalUrl: 'https://portal.azure.com/#resource' + resourceBase + type + '/' + name + '/overview',
  platform: { state: state === 'critical' ? 'healthy' : state, detail: state === 'unknown' ? 'No Azure Resource Health assessment for this resource.' : state === 'warning' ? 'Azure Resource Health: Degraded.' : 'Azure Resource Health: Available.', observedAt: state === 'unknown' ? null : now.toISOString() },
  telemetry: detail ? { state, detail, observedAt: now.toISOString() } : null
});
const snapshot = {
  available: true, state: 'ready', message: 'Health snapshot complete.', checkedAt: now.toISOString(), expiresAt: new Date(now.getTime() + 60000).toISOString(), cached: false,
  resources: [resource('app-amlab-demo', 'Microsoft.Web/sites', 'critical', '42 requests / 6 failures in the last 15 minutes.'),
    resource('aks-amlab', 'Microsoft.ContainerService/managedClusters', 'warning', '2 nodes reporting / 8 reported restarts (15-minute sample window).'),
    resource('vm-amlab-linux', 'Microsoft.Compute/virtualMachines', 'healthy', 'Last heartbeat 60s ago.'),
    resource('vmss-amlab', 'Microsoft.Compute/virtualMachineScaleSets', 'unknown')],
  sources: [{ name: 'Resource inventory', available: true, detail: 'Resource group inventory retrieved.' }, { name: 'Azure Resource Health', available: true, detail: 'Platform availability retrieved.' }, { name: 'Heartbeat', available: true, detail: 'Telemetry query completed.' }]
};

async function prepare(page, response = snapshot) {
  await page.clock.install({ time: now });
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: 'rg-azure-monitor-lab', appService: 'app-amlab-demo' } }));
  await page.route('**/api/console/config', route => route.fulfill({ json: { links: { Workbook: 'https://portal.azure.com/#resource/example-workbook' }, performanceCooldownSeconds: 30 } }));
  await page.route('**/api/infra/health', route => route.fulfill({ json: response }));
  await page.goto('/');
  await expect(page.locator('#infra-status')).toHaveText(response.message);
}

test('Header health checks on page load and infrastructure refresh without changing traffic results', async ({ page }) => {
  let probes = 0;
  await page.route('**/healthz', route => { probes++; return route.fulfill({ status: 200, body: 'OK' }); });
  await prepare(page);
  await expect(page.locator('#health-status')).toHaveText(/^Healthy \/ \d+ ms$/);
  await expect(page.locator('#total')).toHaveText('0');
  await expect(page.locator('#history-count')).toHaveText('0');
  expect(probes).toBe(1);
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.getByRole('tab', { name: 'Infrastructure Health' }).click();
  await page.clock.fastForward(61000);
  expect(probes).toBe(1);
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.locator('#health-status')).toHaveText(/^Healthy \/ \d+ ms$/);
  await expect(page.locator('#total')).toHaveText('0');
  await expect(page.locator('#history-count')).toHaveText('0');
  expect(probes).toBe(2);
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await expect(page.locator('#history-count')).toHaveText('1');
  const checked = await page.locator('#health-status').textContent();
  await page.getByRole('button', { name: 'Clear session results' }).click();
  await expect(page.locator('#total')).toHaveText('0');
  await expect(page.locator('#health-status')).toHaveText(checked);
  expect(probes).toBe(3);
});

for (const failure of ['http', 'network']) {
  test(`Header health reports ${failure} failures and recovers on infrastructure refresh`, async ({ page }) => {
    let available = false;
    await page.route('**/healthz', route => available ? route.fulfill({ body: 'OK' })
      : failure === 'http' ? route.fulfill({ status: 503 }) : route.abort('failed'));
    await prepare(page);
    await expect(page.locator('#health-status')).toHaveText(/^Unavailable \/ \d+ ms$/);
    await expect(page.locator('#failed')).toHaveText('0');
    await expect(page.locator('#total')).toHaveText('0');
    available = true;
    await page.clock.fastForward(61000);
    await page.getByRole('button', { name: 'Refresh', exact: true }).click();
    await expect(page.locator('#health-status')).toHaveText(/^Healthy \/ \d+ ms$/);
    await expect(page.locator('#total')).toHaveText('0');
  });
}

test('Header health ignores an older automatic result after a newer manual check', async ({ page }) => {
  let probes = 0;
  let release;
  await page.route('**/healthz', async route => {
    probes++;
    if (probes === 1) {
      await new Promise(resolve => { release = resolve; });
      await route.fulfill({ body: 'OK' });
    } else await route.fulfill({ status: 503 });
  });
  await prepare(page);
  await expect(page.locator('#health-status')).toHaveText('Checking...');
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await expect(page.locator('#health-status')).toHaveText(/^Unavailable \/ \d+ ms$/);
  const checked = await page.locator('#health-status').textContent();
  const finished = page.waitForEvent('requestfinished', request => request.url().endsWith('/healthz'));
  release();
  await finished;
  await expect(page.locator('#health-status')).toHaveText(checked);
  await expect(page.locator('#total')).toHaveText('1');
});

test('Infrastructure Health is first and default, reads once, filters resources, and preserves the snapshot', async ({ page }) => {
  const requests = [];
  page.on('request', request => { if (request.url().includes('/api/')) requests.push({ path: new URL(request.url()).pathname, method: request.method() }); });
  await prepare(page);
  await expect(page.getByRole('tab').first()).toHaveAttribute('id', 'tab-health');
  await expect(page.getByRole('tab', { name: 'Infrastructure Health' })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('#infra-count-total')).toHaveText('4');
  for (const state of ['healthy', 'warning', 'critical', 'unknown']) await expect(page.locator(`#infra-count-${state}`)).toHaveText('1');
  await expect(page.locator('#infra-rows tr')).toHaveCount(4);
  await expect(page.locator('#infra-rows')).toContainText('vmss-amlab');
  await expect(page.locator('#infra-rows')).toContainText('VM scale set');
  await page.getByLabel('Find resource').fill('linux');
  await expect(page.locator('#infra-rows tr')).toHaveCount(1);
  await expect(page.locator('#infra-rows')).toContainText('vm-amlab-linux');
  await page.getByLabel('Find resource').fill('');
  await page.getByLabel('Status', { exact: true }).selectOption('critical');
  await expect(page.locator('#infra-rows tr')).toHaveCount(1);
  await expect(page.locator('#infra-rows')).toContainText('6 failures');
  await page.getByLabel('Find resource').fill('missing');
  await expect(page.locator('#infra-empty')).toContainText('No resources match');
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await expect(page.locator('#total')).toHaveText('0');
  await page.getByRole('tab', { name: 'Infrastructure Health' }).click();
  await expect(page.getByLabel('Find resource')).toHaveValue('missing');
  expect(requests.filter(request => request.path === '/api/infra/health')).toHaveLength(1);
  expect(requests.some(request => request.method === 'POST' || /sre\/|agents\/catalog/.test(request.path))).toBe(false);
});

test('Infrastructure Health marks stale snapshots without polling and retains old data after a failed refresh', async ({ page }) => {
  let checks = 0;
  page.on('request', request => { if (request.url().endsWith('/api/infra/health')) checks++; });
  await prepare(page);
  await expect(page.locator('#infra-refresh')).toBeDisabled();
  await page.clock.fastForward(61000);
  await expect(page.locator('#infra-stale')).toContainText('Stale snapshot');
  await expect(page.locator('#infra-refresh')).toBeEnabled();
  expect(checks).toBe(1);
  await page.route('**/api/infra/health', route => route.fulfill({ status: 503, json: { available: false, message: 'Read access was denied.' } }));
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.locator('#infra-status')).toHaveText('Read access was denied.');
  await expect(page.locator('#infra-stale')).toContainText('previous snapshot');
  await expect(page.locator('#infra-count-total')).toHaveText('4');
  expect(checks).toBe(2);
});

test('Infrastructure Health exposes source failures, renders Azure text inertly, and rejects unsafe links', async ({ page }) => {
  const unsafe = structuredClone(snapshot);
  unsafe.state = 'partial';
  unsafe.message = 'Partial snapshot. Some health sources could not be verified.';
  unsafe.resources[0].name = '<img src=x onerror="window.injected=true">';
  unsafe.resources[0].portalUrl = 'javascript:alert(1)';
  unsafe.sources[1] = { name: 'Azure Resource Health', available: false, detail: 'Read access was denied.' };
  await prepare(page, unsafe);
  await expect(page.locator('#infra-rows tr').first()).toContainText('<img');
  await expect(page.locator('#infra-rows tr').first().locator('a')).not.toHaveAttribute('href');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  await page.getByText('Health sources', { exact: true }).click();
  await expect(page.locator('#infra-sources')).toContainText('Read access was denied.');
});

test('Infrastructure Health supports empty, unavailable, loading, and sign-in states without fabricated health', async ({ page }) => {
  await prepare(page, { ...snapshot, resources: [] });
  await expect(page.locator('#infra-empty')).toContainText('No resources were returned');
  await page.route('**/api/infra/health', route => route.fulfill({ status: 401, json: { available: false } }));
  await page.reload();
  await expect(page.locator('#infra-sign-in')).toBeVisible();
  await expect(page.locator('#infra-count-healthy')).toHaveText('-');
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await page.route('**/api/infra/health', route => route.fulfill({ json: { available: false, message: 'Infrastructure health access is not enabled.' } }));
  await page.reload();
  await expect(page.locator('#infra-status')).toHaveText('Infrastructure health access is not enabled.');
  await expect(page.locator('#infra-sign-in')).toBeHidden();
  await expect(page.locator('#infra-count-total')).toHaveText('-');
  let release;
  await page.route('**/api/infra/health', async route => { await new Promise(resolve => { release = resolve; }); await route.fulfill({ json: snapshot }); });
  await page.reload();
  await expect(page.locator('#panel-health')).toHaveAttribute('aria-busy', 'true');
  await expect(page.locator('#infra-refresh')).toBeDisabled();
  release();
  await expect(page.locator('#infra-count-total')).toHaveText('4');
});

test('Infrastructure Health endpoint remains scoped, no-store, disabled by default, and rejects unsafe hosts', async ({ request }) => {
  test.setTimeout(90000);
  let response = await request.get('/api/infra/health?resourceGroup=other-rg');
  if (response.status() === 429) {
    const retryAfter = Number(response.headers()['retry-after']);
    expect(retryAfter).toBeGreaterThan(0);
    expect(retryAfter).toBeLessThanOrEqual(60);
    await new Promise(resolve => setTimeout(resolve, (retryAfter + 1) * 1000));
    response = await request.get('/api/infra/health?resourceGroup=other-rg');
  }
  expect(response.status()).toBe(200);
  expect((await response.json()).state).toBe('not_configured');
  expect(response.headers()['cache-control']).toBe('no-store');
  expect(response.headers()['x-amlab-trace-id']).toMatch(/^[0-9a-f]{32}$/);
  expect((await request.get('/api/infra/health', { headers: { Host: 'attacker.example', 'X-MS-CLIENT-PRINCIPAL-ID': 'forged' } })).status()).toBe(401);
  expect((await request.post('/api/infra/health')).status()).toBe(403);
});

for (const width of [1440, 390, 320]) {
  test(`Infrastructure Health layout and navigation fit at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 740 });
    await prepare(page);
    await page.evaluate(() => document.fonts.ready);
    await expect(page.locator('#health-status')).toHaveText(/^Healthy \/ \d+ ms$/);
    await expect(page.locator('.mobile-feedback')).toBeHidden();
    expect(await page.locator('#brand-mark').evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const clipped = await page.locator('button, select, input, h1, h2, .infra-table td').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
    expect(clipped).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath(`infrastructure-health-${width}.png`), fullPage: true });
    if (process.env.UPDATE_CONTROL_CENTER_SCREENSHOT === '1' && width === 1440) await page.screenshot({ path: path.resolve(__dirname, '../../../docs/images/infrastructure-health.png'), fullPage: true });
    await page.getByRole('tab', { name: 'Infrastructure Health' }).focus();
    await page.keyboard.press('End');
    await expect(page.locator('#tab-foundry')).toBeFocused();
    await page.keyboard.press('Home');
    await expect(page.locator('#tab-health')).toBeFocused();
    await expect(page.locator('#panel-health')).toBeVisible();
    expect(errors).toEqual([]);
  });
}