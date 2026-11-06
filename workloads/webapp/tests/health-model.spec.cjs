const { test, expect } = require('@playwright/test');
const path = require('node:path');

const now = new Date('2026-11-06T12:00:00Z');
const models = [
  { name: 'hm-amlab-flows', displayName: 'Lab user flows', resourceGroup: 'rg-azure-monitor-lab', defaultEntity: 'shop-demo' },
  { name: 'hm-lab-cafe', displayName: 'Café tutorial', resourceGroup: 'rg-healthmodel-tutorial', defaultEntity: 'order-coffee' }
];
const signal = (name, displayName, state, value, unit, extra = {}) => ({ name, displayName, kind: 'LogAnalyticsQuery', state, value, unit, reportedAt: now.toISOString(), context: null, ...extra });
const entity = (name, displayName, state, children = [], signals = [], icon = 'SystemComponent') => ({ name, displayName, state, icon, children, signals });
const external = signal('control-center-report', 'control-center-report', 'degraded', 1, null, { kind: 'External', context: 'Sent from the Lab Control Center. Expires after 15 minutes.' });
function cafe(orderState = 'healthy', reported = false) {
  return {
    available: true, state: 'ready', message: '6 entities read.', model: 'hm-lab-cafe', checkedAt: now.toISOString(),
    entities: [
      entity('hm-lab-cafe', 'Café', orderState === 'healthy' ? 'healthy' : 'degraded', ['browse-menu', 'order-coffee'], [], 'Root'),
      entity('browse-menu', 'Browse menu', 'healthy', ['menu-catalog'], [], 'UserFlow'),
      entity('menu-catalog', 'Menu catalog', 'healthy', [], [signal('menu-errors', 'Menu errors', 'healthy', 0, 'Count')]),
      entity('order-coffee', 'Order coffee', orderState, ['order-api'], reported ? [external] : [], 'UserFlow'),
      entity('order-api', 'Order API', 'healthy', [], [signal('slow-orders', 'Order time (p95)', 'healthy', 757, 'MilliSeconds'), signal('failed-orders', 'Failed order requests', 'unknown', null, 'Count')]),
      entity('orphan', 'Unlinked entity', 'unknown')
    ]
  };
}
const flows = {
  available: true, state: 'ready', message: '2 entities read.', model: 'hm-amlab-flows', checkedAt: now.toISOString(),
  entities: [
    entity('hm-amlab-flows', 'Lab flows', 'unhealthy', ['shop-demo'], [], 'Root'),
    entity('shop-demo', 'Show the shop app live', 'unhealthy', [], [signal('shop-failures', 'Shop failures', 'unhealthy', 12, 'Count')], 'UserFlow')
  ]
};

async function prepare(page, { reads = {}, report, modelsResponse } = {}) {
  const calls = { reads: [], reports: [] };
  await page.clock.install({ time: now });
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: 'rg-azure-monitor-lab', appService: 'app-amlab-demo' } }));
  await page.route('**/api/console/config', route => route.fulfill({ json: { links: {}, performanceCooldownSeconds: 30 } }));
  await page.route('**/api/infra/health', route => route.fulfill({ json: { available: false, message: 'Infrastructure health access is not enabled.' } }));
  await page.route('**/api/healthmodels', route => route.fulfill(modelsResponse || { json: { models } }));
  await page.route('**/api/healthmodels/*', route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    calls.reads.push(name);
    const response = reads[name] ?? (name === 'hm-lab-cafe' ? cafe() : flows);
    return route.fulfill(typeof response === 'function' ? response(calls) : { json: response });
  });
  await page.route('**/api/healthmodels/*/reports', route => {
    const request = route.request();
    calls.reports.push({ model: new URL(request.url()).pathname.split('/')[3], body: request.postDataJSON(), header: request.headers()['x-amlab-agent-request'] });
    return route.fulfill(report || { json: { sent: true, message: 'Degraded report sent. It expires at 12:15 UTC.', model: 'hm-lab-cafe', entity: request.postDataJSON().entity, signal: 'control-center-report', expiresAt: new Date(now.getTime() + 900000).toISOString() } });
  });
  await page.goto('/');
  return calls;
}
async function open(page, model = 'hm-amlab-flows') {
  await page.getByRole('tab', { name: 'Health Model' }).click();
  await expect(page.locator('#panel-healthmodel')).toBeVisible();
  await expect(page.locator('#hm-model')).toHaveValue(model);
}
async function selectCafe(page) {
  await page.locator('#hm-model').selectOption('hm-lab-cafe');
  await expect(page.locator('#hm-status')).toHaveText('6 entities read.');
}

test('Health Model tab reads the first configured model only when opened', async ({ page }) => {
  const calls = await prepare(page);
  await expect(page.locator('#panel-health')).toBeVisible();
  expect(calls.reads).toEqual([]);
  await open(page);
  await expect(page.locator('#hm-status')).toHaveText('2 entities read.');
  await expect(page.locator('#hm-model option')).toHaveText(['Lab user flows (hm-amlab-flows)', 'Café tutorial (hm-lab-cafe)']);
  await expect(page.locator('#hm-entity')).toHaveValue('shop-demo');
  await page.getByRole('tab', { name: 'Traffic & Faults' }).click();
  await page.getByRole('tab', { name: 'Health Model' }).click();
  expect(calls.reads).toEqual(['hm-amlab-flows']);
});

test('Health Model shows the entity tree, states, counts and signal values', async ({ page }) => {
  await prepare(page);
  await open(page);
  await selectCafe(page);
  const rows = page.locator('#hm-rows tr');
  await expect(rows.locator('td:first-child strong')).toHaveText(['Café', 'Browse menu', 'Menu catalog', 'Order coffee', 'Order API', 'Unlinked entity']);
  const indent = await rows.locator('td:first-child').evaluateAll(cells => cells.map(cell => cell.style.paddingLeft));
  expect(indent).toEqual(['12px', '30px', '48px', '30px', '48px', '12px']);
  await expect(rows.nth(3).locator('td:first-child small')).toHaveText('order-coffee / UserFlow');
  await expect(rows.locator('td:nth-child(2)')).toHaveText(['Healthy', 'Healthy', 'Healthy', 'Healthy', 'Healthy', 'Unknown']);
  await expect(rows.nth(0).locator('td:nth-child(3)')).toHaveText('Rolls up from its children');
  const api = rows.nth(4).locator('.hm-signals li');
  await expect(api.nth(0)).toContainText('Healthy');
  await expect(api.nth(0)).toContainText('Order time (p95)');
  await expect(api.nth(0).locator('strong')).toHaveText('757 MilliSeconds');
  await expect(api.nth(1).locator('strong')).toHaveText('No value');
  await expect(api.nth(1)).toContainText('Unknown');
  await expect(api.nth(0).locator('small')).toContainText('LogAnalyticsQuery / reported');
  await expect(page.locator('#hm-count-total')).toHaveText('6');
  await expect(page.locator('#hm-count-healthy')).toHaveText('5');
  await expect(page.locator('#hm-count-degraded')).toHaveText('0');
  await expect(page.locator('#hm-count-unhealthy')).toHaveText('0');
  await expect(page.locator('#hm-count-unknown')).toHaveText('1');
  await expect(page.locator('#hm-checked')).toContainText('Checked');
  await expect(page.locator('#hm-entity option')).toHaveCount(6);
});

test('Switching models reads the other model and uses its default entity', async ({ page }) => {
  const calls = await prepare(page);
  await open(page);
  await expect(page.locator('#hm-count-unhealthy')).toHaveText('2');
  await selectCafe(page);
  await expect(page.locator('#hm-entity')).toHaveValue('order-coffee');
  await page.locator('#hm-model').selectOption('hm-amlab-flows');
  await expect(page.locator('#hm-entity')).toHaveValue('shop-demo');
  expect(calls.reads).toEqual(['hm-amlab-flows', 'hm-lab-cafe', 'hm-amlab-flows']);
});

for (const choice of [{ entity: null, expected: 'order-coffee' }, { entity: 'order-api', expected: 'order-api' }]) {
  test(`One click sends a Degraded report to ${choice.expected} and the entity turns Degraded`, async ({ page }, testInfo) => {
    let reported = false;
    const calls = await prepare(page, { reads: { 'hm-lab-cafe': () => ({ json: reported ? (choice.expected === 'order-coffee' ? cafe('degraded', true) : cafe()) : cafe() }) } });
    await page.setViewportSize({ width: 1440, height: 1100 });
    await open(page);
    await selectCafe(page);
    if (choice.entity) await page.locator('#hm-entity').selectOption(choice.entity);
    await page.getByRole('button', { name: 'Send Degraded Report' }).click();
    await expect(page.locator('#hm-report-status')).toHaveText('Degraded report sent. It expires at 12:15 UTC.');
    expect(calls.reports).toEqual([{ model: 'hm-lab-cafe', body: { entity: choice.expected }, header: 'true' }]);
    await expect(page.locator('#hm-rows tr.hm-reported td:first-child small')).toContainText(choice.expected);
    reported = true;
    await page.clock.fastForward(5000);
    await expect.poll(() => calls.reads.length).toBe(3);
    if (choice.expected === 'order-coffee') {
      const row = page.locator('#hm-rows tr.hm-reported');
      await expect(row.locator('td:nth-child(2)')).toHaveText('Degraded');
      await expect(row.locator('.hm-signals li')).toContainText('control-center-report');
      await expect(row.locator('.hm-signals li small')).toContainText('External report');
      await expect(row.locator('.hm-signals li small')).toContainText('Expires after 15 minutes.');
      await expect(page.locator('#hm-count-degraded')).toHaveText('2');
      await page.screenshot({ path: testInfo.outputPath('health-model-reported-1440.png'), fullPage: true });
      if (process.env.UPDATE_CONTROL_CENTER_SCREENSHOT === '1') await page.screenshot({ path: path.resolve(__dirname, '../../../docs/images/health-model.png'), fullPage: true });
    }
    await page.clock.fastForward(15000);
    await expect.poll(() => calls.reads.length).toBe(4);
    await page.clock.fastForward(25000);
    await expect.poll(() => calls.reads.length).toBe(5);
  });
}

for (const failure of [
  { name: 'denied', status: 200, json: { sent: false, message: 'Report access was denied. The app identity needs the ingestHealthReport action on this health model.' } },
  { name: 'throttled', status: 429, json: { error: 'Request limit reached. Please retry after the cooldown.', retrySeconds: 30 } }
]) {
  test(`A ${failure.name} report shows the reason and schedules no refresh`, async ({ page }) => {
    const calls = await prepare(page, { report: { status: failure.status, json: failure.json } });
    await open(page);
    await selectCafe(page);
    await page.getByRole('button', { name: 'Send Degraded Report' }).click();
    await expect(page.locator('#hm-report-status')).toHaveText(failure.json.message || failure.json.error);
    await expect(page.locator('#hm-rows tr.hm-reported')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Send Degraded Report' })).toBeEnabled();
    await page.clock.fastForward(60000);
    expect(calls.reads).toEqual(['hm-amlab-flows', 'hm-lab-cafe']);
  });
}

for (const failure of [
  { name: 'missing model', response: { json: { available: false, state: 'unavailable', message: 'The health model was not found. Deploy it first.', entities: [] } }, text: 'The health model was not found. Deploy it first.' },
  { name: 'denied read', response: { json: { available: false, state: 'unavailable', message: 'Read access was denied. The app identity needs Reader on this health model.', entities: [] } }, text: 'Read access was denied. The app identity needs Reader on this health model.' },
  { name: 'server error', response: { status: 500, body: 'not json' }, text: 'The health model could not be read.' }
]) {
  test(`A ${failure.name} keeps the view empty and keeps the default entity`, async ({ page }) => {
    await prepare(page, { reads: { 'hm-amlab-flows': () => failure.response } });
    await open(page);
    await expect(page.locator('#hm-status')).toHaveText(failure.text);
    await expect(page.locator('#hm-table')).toBeHidden();
    await expect(page.locator('#hm-empty-text')).toHaveText('No health model snapshot available.');
    await expect(page.locator('#hm-entity')).toHaveValue('shop-demo');
    await expect(page.locator('#hm-count-total')).toHaveText('-');
  });
}

test('Health Model asks for sign-in when the operator is not approved', async ({ page }) => {
  await prepare(page, { modelsResponse: { status: 401, json: { available: false } } });
  await page.getByRole('tab', { name: 'Health Model' }).click();
  await expect(page.locator('#hm-status')).toHaveText('Sign in with an approved lab operator account to view health models.');
  await expect(page.locator('#hm-sign-in')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Send Degraded Report' })).toBeDisabled();
});

test('Health Model explains when no model is configured', async ({ page }) => {
  await prepare(page, { modelsResponse: { json: { models: [] } } });
  await page.getByRole('tab', { name: 'Health Model' }).click();
  await expect(page.locator('#hm-status')).toHaveText('No health model is configured. Enable health access for this app.');
  await expect(page.getByRole('button', { name: 'Send Degraded Report' })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Refresh' }).last()).toBeDisabled();
});

test('Health model endpoints are disabled by default, no-store, and reject unsafe hosts and cross-site posts', async ({ request }) => {
  const list = await request.get('/api/healthmodels');
  expect(list.status()).toBe(200);
  expect(await list.json()).toEqual({ models: [] });
  expect(list.headers()['cache-control']).toBe('no-store');
  const read = await request.get('/api/healthmodels/hm-lab-cafe');
  expect((await read.json()).state).toBe('not_configured');
  for (const route of ['/api/healthmodels', '/api/healthmodels/hm-lab-cafe']) {
    expect((await request.get(route, { headers: { Host: 'attacker.example', 'X-MS-CLIENT-PRINCIPAL-ID': 'forged' } })).status()).toBe(401);
  }
  expect((await request.post('/api/healthmodels/hm-lab-cafe/reports', { data: { entity: 'order-coffee' } })).status()).toBe(403);
  const report = await request.post('/api/healthmodels/hm-lab-cafe/reports', { data: { entity: 'order-coffee' }, headers: { 'X-Amlab-Agent-Request': 'true' } });
  expect(report.status()).toBe(200);
  expect((await report.json()).sent).toBe(false);
});

for (const width of [1440, 390, 320]) {
  test(`Health Model layout fits at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 740 });
    await prepare(page);
    await open(page);
    await selectCafe(page);
    await page.evaluate(() => document.fonts.ready);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const clipped = await page.locator('#panel-healthmodel button, #panel-healthmodel h2, #panel-healthmodel .hm-table td').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
    expect(clipped).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath(`health-model-${width}.png`), fullPage: true });
    await page.getByRole('tab', { name: 'Health Model' }).focus();
    await page.keyboard.press('ArrowLeft');
    await expect(page.locator('#tab-health')).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.locator('#tab-healthmodel')).toBeFocused();
    await expect(page.locator('#panel-healthmodel')).toBeVisible();
    expect(errors).toEqual([]);
  });
}
