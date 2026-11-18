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
function cafe(reportedEntity = null) {
  const state = name => (name === reportedEntity ? 'degraded' : 'healthy');
  const signals = (name, own = []) => (name === reportedEntity ? [...own, external] : own);
  return {
    available: true, state: 'ready', message: '6 entities read.', checkedAt: now.toISOString(),
    entities: [
      entity('hm-lab-cafe', 'Café', reportedEntity ? 'degraded' : 'healthy', ['browse-menu', 'order-coffee'], [], 'Root'),
      entity('browse-menu', 'Browse menu', 'healthy', ['menu-catalog'], [], 'UserFlow'),
      entity('menu-catalog', 'Menu catalog', 'healthy', [], [signal('menu-errors', 'Menu errors', 'healthy', 0, 'Count')]),
      entity('order-coffee', 'Order coffee', state('order-coffee'), ['order-api', 'menu-catalog'], signals('order-coffee'), 'UserFlow'),
      entity('order-api', 'Order API', state('order-api'), [], signals('order-api', [signal('slow-orders', 'Order time (p95)', 'healthy', 757, 'MilliSeconds'), signal('failed-orders', 'Failed order requests', 'unknown', null, 'Count')])),
      entity('orphan', 'Unlinked entity', 'unknown')
    ]
  };
}
const flows = {
  available: true, state: 'ready', message: '2 entities read.', checkedAt: now.toISOString(),
  entities: [
    entity('hm-amlab-flows', 'Lab flows', 'unhealthy', ['shop-demo'], [], 'Root'),
    entity('shop-demo', 'Show the shop app live', 'unhealthy', [], [signal('shop-failures', 'Shop failures', 'unhealthy', 12, 'Count')], 'UserFlow')
  ]
};
const sent = entity => ({ json: { sent: true, message: 'Degraded report sent. It expires at 12:15 UTC.', entity, expiresAt: new Date(now.getTime() + 900000).toISOString() } });

async function prepare(page, { reads = {}, report, modelsResponse } = {}) {
  const calls = { reads: [], reports: [], lists: 0 };
  await page.clock.install({ time: now });
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: 'rg-azure-monitor-lab', appService: 'app-amlab-demo' } }));
  await page.route('**/api/console/config', route => route.fulfill({ json: { links: {}, performanceCooldownSeconds: 30 } }));
  await page.route('**/api/infra/health', route => route.fulfill({ json: { available: false, message: 'Infrastructure health access is not enabled.' } }));
  await page.route('**/api/healthmodels', route => {
    calls.lists++;
    return route.fulfill(typeof modelsResponse === 'function' ? modelsResponse(calls) : modelsResponse || { json: { models } });
  });
  await page.route('**/api/healthmodels/*', async route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    calls.reads.push(name);
    const response = reads[name] ?? (name === 'hm-lab-cafe' ? cafe() : flows);
    // An aborted read cannot be fulfilled any more.
    return route.fulfill(typeof response === 'function' ? await response(calls) : { json: response }).catch(() => {});
  });
  await page.route('**/api/healthmodels/*/reports', async route => {
    const request = route.request();
    calls.reports.push({ model: new URL(request.url()).pathname.split('/')[3], body: request.postDataJSON(), header: request.headers()['x-amlab-agent-request'] });
    return route.fulfill(typeof report === 'function' ? await report() : report || sent(request.postDataJSON().entity));
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
// Lets any request the page has started reach the route handlers before asserting that none was made.
async function settle(page) { await page.waitForTimeout(500); }

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
  await settle(page);
  expect(calls.reads).toEqual(['hm-amlab-flows']);
  expect(calls.lists).toBe(1);
});

test('Health Model sends a same-origin referrer through App Service authentication without leaking it externally', async ({ page }) => {
  await prepare(page);
  let requests = 0;
  await page.route('**/api/healthmodels/*/reports', async route => {
    requests++;
    if (route.request().headers().referer !== new URL('/', route.request().url()).href) {
      return route.fulfill({ status: 403, body: '' });
    }
    return route.fulfill(sent('shop-demo'));
  });
  await open(page);
  await page.getByRole('button', { name: 'Send Degraded Report' }).click();
  await expect(page.locator('#hm-report-status')).toHaveText('Degraded report sent. It expires at 12:15 UTC.');
  expect(requests).toBe(1);
  let externalReferrer;
  await page.route('https://external.example/privacy-check', route => {
    externalReferrer = route.request().headers().referer;
    return route.fulfill({ body: 'ok', headers: { 'access-control-allow-origin': '*' } });
  });
  await page.evaluate(() => fetch('https://external.example/privacy-check'));
  expect(externalReferrer).toBeUndefined();
});

test('Health Model shows the entity tree once per entity, with states, counts and signal values', async ({ page }) => {
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
  await expect(rows.nth(5).locator('td:nth-child(3)')).toHaveText('No signals');
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

test('Entities the root does not reach keep their own subtree', async ({ page }) => {
  const loose = { ...flows, entities: [...flows.entities, entity('loose-part', 'Loose part', 'healthy'), entity('loose', 'Loose component', 'unknown', ['loose-part'])] };
  await prepare(page, { reads: { 'hm-amlab-flows': loose } });
  await open(page);
  const rows = page.locator('#hm-rows tr');
  await expect(rows.locator('td:first-child strong')).toHaveText(['Lab flows', 'Show the shop app live', 'Loose component', 'Loose part']);
  expect(await rows.locator('td:first-child').evaluateAll(cells => cells.map(cell => cell.style.paddingLeft))).toEqual(['12px', '30px', '12px', '30px']);
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

test('Switching models during a read shows the newly selected model', async ({ page }) => {
  let release;
  const calls = await prepare(page, { reads: { 'hm-amlab-flows': () => new Promise(resolve => { release = () => resolve({ json: flows }); }) } });
  await page.getByRole('tab', { name: 'Health Model' }).click();
  await expect.poll(() => calls.reads).toEqual(['hm-amlab-flows']);
  await page.locator('#hm-model').selectOption('hm-lab-cafe');
  await expect(page.locator('#hm-status')).toHaveText('6 entities read.');
  release();
  await settle(page);
  await expect(page.locator('#hm-status')).toHaveText('6 entities read.');
  await expect(page.locator('#hm-entity')).toHaveValue('order-coffee');
  await expect(page.locator('#hm-rows tr').first().locator('td:first-child strong')).toHaveText('Café');
  expect(calls.reads).toEqual(['hm-amlab-flows', 'hm-lab-cafe']);
});

for (const choice of [{ pick: null, entity: 'order-coffee' }, { pick: 'order-api', entity: 'order-api' }]) {
  test(`One click sends a Degraded report to ${choice.entity} and it turns Degraded until the report expires`, async ({ page }, testInfo) => {
    let reported = null;
    const calls = await prepare(page, { reads: { 'hm-lab-cafe': () => ({ json: cafe(reported) }) } });
    await page.setViewportSize({ width: 1440, height: 1100 });
    await open(page);
    await selectCafe(page);
    if (choice.pick) await page.locator('#hm-entity').selectOption(choice.pick);
    await page.getByRole('button', { name: 'Send Degraded Report' }).click();
    await expect(page.locator('#hm-report-status')).toHaveText('Degraded report sent. It expires at 12:15 UTC.');
    expect(calls.reports).toEqual([{ model: 'hm-lab-cafe', body: { entity: choice.entity }, header: 'true' }]);
    const row = page.locator('#hm-rows tr.hm-reported');
    await expect(row.locator('td:first-child small')).toContainText(choice.entity);
    reported = choice.entity;
    await page.clock.fastForward(5000);
    await expect.poll(() => calls.reads.length).toBe(3);
    await expect(row.locator('td:nth-child(2)')).toHaveText('Degraded');
    await expect(row.locator('.hm-signals li').last()).toContainText('control-center-report');
    await expect(row.locator('.hm-signals li small').last()).toContainText('External report');
    await expect(row.locator('.hm-signals li small').last()).toContainText('Expires after 15 minutes.');
    await expect(page.locator('#hm-count-degraded')).toHaveText('2');
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: testInfo.outputPath(`health-model-reported-${choice.entity}.png`), fullPage: true });
    if (process.env.UPDATE_CONTROL_CENTER_SCREENSHOT === '1' && choice.entity === 'order-coffee') await page.screenshot({ path: path.resolve(__dirname, '../../../docs/images/health-model.png'), fullPage: true });
    await page.clock.fastForward(15000);
    await expect.poll(() => calls.reads.length).toBe(4);
    await page.clock.fastForward(25000);
    await expect.poll(() => calls.reads.length).toBe(5);
    reported = null;
    await page.clock.fastForward(15 * 60000);
    await page.getByRole('button', { name: 'Refresh' }).last().click();
    await expect.poll(() => calls.reads.length).toBe(6);
    await expect(page.locator('#hm-count-degraded')).toHaveText('0');
    await expect(row).toHaveCount(0);
  });
}

for (const failure of [
  { name: 'denied', response: { status: 200, json: { sent: false, message: 'Report access was denied. The app identity needs the Health Model Reporter role on this health model.' } }, signIn: false },
  { name: 'throttled', response: { status: 429, json: { error: 'Request limit reached. Please retry after the cooldown.', retrySeconds: 30 } }, signIn: false },
  { name: 'signed-out', response: { status: 401, json: { available: false, error: 'Authenticated operator access is required.' } }, signIn: true }
]) {
  test(`A ${failure.name} report shows the reason and schedules no refresh`, async ({ page }) => {
    const calls = await prepare(page, { report: failure.response });
    await open(page);
    await selectCafe(page);
    await page.getByRole('button', { name: 'Send Degraded Report' }).click();
    await expect(page.locator('#hm-report-status')).toHaveText(failure.response.json.message || failure.response.json.error);
    await expect(page.locator('#hm-sign-in')).toBeVisible({ visible: failure.signIn });
    await expect(page.locator('#hm-rows tr.hm-reported')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Send Degraded Report' })).toBeEnabled();
    await page.clock.fastForward(60000);
    await settle(page);
    expect(calls.reads).toEqual(['hm-amlab-flows', 'hm-lab-cafe']);
  });
}

test('A report that returns after a model switch names its model and refreshes nothing', async ({ page }) => {
  let release;
  const calls = await prepare(page, { report: () => new Promise(resolve => { release = () => resolve(sent('order-coffee')); }) });
  await open(page);
  await selectCafe(page);
  await page.getByRole('button', { name: 'Send Degraded Report' }).click();
  await expect.poll(() => calls.reports.length).toBe(1);
  await page.locator('#hm-model').selectOption('hm-amlab-flows');
  await expect(page.locator('#hm-status')).toHaveText('2 entities read.');
  release();
  await expect(page.locator('#hm-report-status')).toHaveText('hm-lab-cafe: Degraded report sent. It expires at 12:15 UTC.');
  await page.clock.fastForward(60000);
  await settle(page);
  expect(calls.reads).toEqual(['hm-amlab-flows', 'hm-lab-cafe', 'hm-amlab-flows']);
  await expect(page.locator('#hm-rows tr.hm-reported')).toHaveCount(0);
});

for (const failure of [
  { name: 'missing model', response: { json: { available: false, state: 'unavailable', message: 'The health model was not found. Deploy it first.', entities: [] } }, text: 'The health model was not found. Deploy it first.' },
  { name: 'denied read', response: { json: { available: false, state: 'unavailable', message: 'Read access was denied. The app identity needs the Health Model Reporter role on this health model.', entities: [] } }, text: 'Read access was denied. The app identity needs the Health Model Reporter role on this health model.' },
  { name: 'server error', response: { status: 500, body: 'not json' }, text: 'The health model could not be read.' }
]) {
  test(`A ${failure.name} on the first read keeps the view empty and the default entity`, async ({ page }) => {
    await prepare(page, { reads: { 'hm-amlab-flows': () => failure.response } });
    await open(page);
    await expect(page.locator('#hm-status')).toHaveText(failure.text);
    await expect(page.locator('#hm-table')).toBeHidden();
    await expect(page.locator('#hm-empty-text')).toHaveText('No health model snapshot available.');
    await expect(page.locator('#hm-entity')).toHaveValue('shop-demo');
    await expect(page.locator('#hm-count-total')).toHaveText('-');
  });

  test(`A ${failure.name} on a later read keeps showing the previous read`, async ({ page }) => {
    let failing = false;
    await prepare(page, { reads: { 'hm-amlab-flows': () => (failing ? failure.response : { json: flows }) } });
    await open(page);
    await expect(page.locator('#hm-status')).toHaveText('2 entities read.');
    failing = true;
    await page.getByRole('button', { name: 'Refresh' }).last().click();
    await expect(page.locator('#hm-status')).toHaveText(`${failure.text} Showing the previous read.`);
    await expect(page.locator('#hm-table')).toBeVisible();
    await expect(page.locator('#hm-count-total')).toHaveText('2');
  });
}

for (const failure of [
  { name: 'not approved', response: { status: 401, json: { available: false } }, text: 'Sign in with an approved lab operator account to view health models.', signIn: true },
  { name: 'not configured', response: { json: { models: [] } }, text: 'No health model is configured. Enable health access for this app.', signIn: false },
  { name: 'throttled', response: { status: 429, json: { error: 'Request limit reached. Please retry after the cooldown.' } }, text: 'Request limit reached. Please retry after the cooldown.', signIn: false },
  { name: 'failing', response: { status: 500, json: { title: 'Lab request failed' } }, text: 'Health models could not be listed. Retry with Refresh.', signIn: false }
]) {
  test(`A ${failure.name} model list explains itself and Refresh retries it`, async ({ page }) => {
    const calls = await prepare(page, { modelsResponse: list => (list.lists === 1 ? failure.response : { json: { models } }) });
    await page.getByRole('tab', { name: 'Health Model' }).click();
    await expect(page.locator('#hm-status')).toHaveText(failure.text);
    await expect(page.locator('#hm-sign-in')).toBeVisible({ visible: failure.signIn });
    await expect(page.getByRole('button', { name: 'Send Degraded Report' })).toBeDisabled();
    await page.getByRole('button', { name: 'Refresh' }).last().click();
    await expect(page.locator('#hm-status')).toHaveText('2 entities read.');
    await expect(page.locator('#hm-sign-in')).toBeHidden();
    expect(calls.lists).toBe(2);
  });
}

test('Health model endpoints are disabled by default, no-store, and reject unsafe hosts and cross-site posts', async ({ request }) => {
  const list = await request.get('/api/healthmodels');
  expect(list.status()).toBe(200);
  expect(await list.json()).toEqual({ models: [] });
  expect(list.headers()['cache-control']).toBe('no-store');
  const read = await request.get('/api/healthmodels/hm-lab-cafe');
  expect((await read.json()).state).toBe('not_configured');
  for (const route of ['/api/healthmodels', '/api/healthmodels/', '/api/healthmodels/hm-lab-cafe']) {
    expect((await request.get(route, { headers: { Host: 'attacker.example', 'X-MS-CLIENT-PRINCIPAL-ID': 'forged' } })).status()).toBe(401);
  }
  const url = '/api/healthmodels/hm-lab-cafe/reports';
  expect((await request.post(url, { data: { entity: 'order-coffee' } })).status()).toBe(403);
  expect((await request.post(url, { data: { entity: 'order-coffee' }, headers: { 'X-Amlab-Agent-Request': 'true', Origin: 'https://attacker.example' } })).status()).toBe(403);
  const report = await request.post(url, { data: { entity: 'order-coffee' }, headers: { 'X-Amlab-Agent-Request': 'true' } });
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
    expect(await page.locator('#panel-healthmodel').evaluate(panel => parseFloat(getComputedStyle(panel).paddingLeft))).toBeGreaterThanOrEqual(16);
    await expect(page.locator('#panel-healthmodel .scenario-links a')).toHaveCount(2);
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
