const { test, expect } = require('@playwright/test');

const catalog = { available: true, state: 'ready', message: 'Connected to existing lab agents', agents: [
  { key: 'triage', name: 'Support Triage', model: 'test-model' },
  { key: 'finops', name: 'FinOps Q&A', model: 'test-model' }
] };
const answer = { agent: 'Support Triage', model: 'test-model', text: 'Technical: inspect the application trace.', status: 'completed', inputTokens: 120, outputTokens: 32, estimatedCostUsd: null, durationMs: 1400, traceId: '0123456789abcdef0123456789abcdef', runId: 'run_test' };
async function ready(page) {
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: catalog }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'Foundry Playground' }).click();
  await expect(page.getByLabel('Agent', { exact: true })).toBeEnabled();
  await expect(page.getByLabel('Observability scenario').locator('option')).toHaveCount(3);
}
async function approve(page) {
  await page.getByLabel('Task', { exact: true }).fill('The app returns an error.');
  await page.getByLabel('I approve billable model usage for this task.').check();
}

test('agent API rejects unsafe requests, enforces consent and size, defaults off, and limits requests', async ({ request }) => {
  const data = { agent: 'triage', prompt: 'Test task', consent: true };
  const headers = { 'X-Amlab-Agent-Request': 'true' };
  expect((await request.post('/api/agents/run', { data })).status()).toBe(403);
  expect((await request.post('/api/agents/run', { data, headers: { ...headers, Host: 'attacker.example' } })).status()).toBe(401);
  expect((await request.post('/api/agents/run', { data, headers: { ...headers, Origin: 'https://attacker.example' } })).status()).toBe(403);
  for (const invalid of [{ ...data, agent: 'arbitrary-agent' }, { ...data, prompt: '' }, { ...data, prompt: 'a'.repeat(4001) }, { ...data, consent: false }]) {
    expect((await request.post('/api/agents/run', { data: invalid, headers })).status()).toBe(400);
  }
  const disabled = await request.post('/api/agents/run', { data, headers });
  expect(disabled.status()).toBe(503);
  expect((await disabled.json()).state).toBe('not_configured');
  expect((await request.post('/api/agents/run', { data, headers })).status()).toBe(503);
  const limited = await request.post('/api/agents/run', { data, headers });
  expect(limited.status()).toBe(429);
  expect(Number(limited.headers()['retry-after'])).toBeGreaterThan(0);
  const available = await request.get('/api/agents/catalog');
  expect((await available.json()).available).toBe(false);
  expect(available.headers()['cache-control']).toBe('no-store');
  const context = await request.get('/api/agents/context');
  expect(Object.keys(await context.json()).sort()).toEqual(['appService', 'foundryUrl', 'observabilityAgentUrl', 'resourceGroup', 'sreUrl']);
  expect(await context.text()).not.toMatch(/InstrumentationKey|ConnectionString|password/i);
});

test('observability scenarios compare broken and fixed metadata-only traces', async ({ page }) => {
  const submissions = [];
  await page.route('**/api/agents/scenarios/run', async route => {
    const data = route.request().postDataJSON();
    submissions.push(data);
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    const broken = data.mode === 'broken';
    await route.fulfill({
      status: broken && data.scenario === 'wrong-tool' ? 409 : 200,
      json: {
        scenario: data.scenario,
        mode: data.mode,
        status: broken ? 'wrong_tool' : 'completed',
        selectedTool: broken ? 'inventory_lookup' : 'order_lookup',
        expectedTool: 'order_lookup',
        durationMs: broken ? 2500 : 100,
        traceId: 'scenario-trace',
        investigationPrompt: `Investigate trace scenario-trace for ${data.scenario} in ${data.mode} mode.`
      }
    });

  });
  await ready(page);
  await page.getByLabel('Observability scenario').selectOption('wrong-tool');
  await page.getByLabel('Scenario profile').selectOption('broken');
  await page.getByLabel('I approve generation of synthetic, metadata-only demo telemetry.').check();
  await page.getByRole('button', { name: 'Generate Trace' }).click();
  await expect(page.locator('#agent-scenario-status')).toContainText('wrong_tool');
  await expect(page.locator('#agent-scenario-status')).toContainText('trace scenario-trace');
  await expect(page.getByLabel('Observability Agent investigation prompt')).toHaveValue(/scenario-trace.*wrong-tool.*broken/);
  await expect(page.getByRole('button', { name: 'Copy Prompt' })).toBeVisible();
  await expect(page.getByLabel('I approve generation of synthetic, metadata-only demo telemetry.')).not.toBeChecked();
  await page.getByLabel('Scenario profile').selectOption('fixed');
  await page.getByLabel('I approve generation of synthetic, metadata-only demo telemetry.').check();
  await page.getByRole('button', { name: 'Generate Trace' }).click();
  await expect(page.locator('#agent-scenario-status')).toContainText('completed');
  expect(submissions).toEqual([
    { scenario: 'wrong-tool', mode: 'broken', consent: true },
    { scenario: 'wrong-tool', mode: 'fixed', consent: true }
  ]);
});

test('observability scenario failures are not replayed and non-JSON responses stay inert', async ({ page }) => {
  let attempts = 0;
  await page.route('**/api/agents/scenarios/run', route => {
    attempts++;
    route.fulfill({ status: 502, contentType: 'text/html', body: '<script>window.injected=true</script>' });
  });
  await ready(page);
  await page.getByLabel('I approve generation of synthetic, metadata-only demo telemetry.').check();
  await page.getByRole('button', { name: 'Generate Trace' }).click();
  await expect(page.locator('#agent-scenario-status')).toContainText('Scenario failed');
  await expect(page.getByLabel('I approve generation of synthetic, metadata-only demo telemetry.')).not.toBeChecked();
  expect(attempts).toBe(1);
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
});

test('alert storm generates a bounded mixed batch and can stop without replay', async ({ page }) => {
  const submissions = [];
  await page.route('**/api/agents/scenarios/run', async route => {
    const data = route.request().postDataJSON();
    submissions.push(data);
    await route.fulfill({
      status: data.scenario === 'partial-failure' ? 502 : 200,
      json: {
        scenario: data.scenario,
        mode: data.mode,
        status: data.scenario === 'partial-failure' ? 'partial_failure' : 'completed',
        selectedTool: 'customer_lookup',
        expectedTool: data.scenario === 'partial-failure' ? 'order_lookup' : 'customer_lookup',
        durationMs: 100,
        traceId: `storm-${submissions.length}`,
        investigationPrompt: 'Investigate the mixed batch.'
      }
    });
  });
  await ready(page);
  await page.getByLabel('Alert storm requests').selectOption('12');
  await page.getByLabel('Alert storm duration').selectOption('3');
  await page.getByLabel('I approve repeated synthetic slow and failed agent requests.').check();
  await page.getByRole('button', { name: 'Start Alert Storm' }).click();
  await expect(page.locator('#alert-storm-counter')).toHaveText('1 / 12');
  await page.locator('#alert-storm-stop').click();
  await expect(page.locator('#alert-storm-status')).toContainText('Stopped after 1');
  expect(submissions).toEqual([{ scenario: 'slow-tool', mode: 'broken', consent: true }]);
});

test('token anomaly runs only the approved real-call batch and aggregates usage', async ({ page }) => {
  const submissions = [];
  let pricing = 'available';
  let callInBatch = 0;
  await page.route('**/api/agents/run', async route => {
    const data = route.request().postDataJSON();
    submissions.push(data);
    callInBatch++;
    await route.fulfill({
      json: {
        ...answer,
        inputTokens: 1200,
        outputTokens: 30,
        estimatedCostUsd: pricing === 'unavailable' || (pricing === 'partial' && callInBatch === 2) ? null : 0.001,
        traceId: `token-${submissions.length}`,
        runId: `run-${submissions.length}`
      }
    });
  });
  await ready(page);
  await page.getByLabel('Token anomaly calls').selectOption('3');
  await page.getByLabel('I approve this bounded batch of billable Foundry model calls.').check();
  await page.getByRole('button', { name: 'Generate Token Anomaly' }).click();
  await expect(page.locator('#token-anomaly-status')).toContainText('Completed 3 calls');
  await expect(page.locator('#token-anomaly-status')).toContainText('3,600 input + 90 output tokens');
  expect(submissions).toHaveLength(3);
  expect(new Set(submissions.map(item => item.batchId)).size).toBe(1);
  expect(submissions.every(item => item.scenario === 'token-anomaly' && item.consent && item.prompt.length <= 4000)).toBe(true);
  await expect(page.getByLabel('I approve this bounded batch of billable Foundry model calls.')).not.toBeChecked();

  pricing = 'unavailable';
  callInBatch = 0;
  await page.getByLabel('I approve this bounded batch of billable Foundry model calls.').check();
  await page.getByRole('button', { name: 'Generate Token Anomaly' }).click();
  await expect(page.locator('#token-anomaly-status')).toContainText('Completed 3 calls');
  await expect(page.locator('#token-anomaly-status')).toContainText('cost unavailable; model pricing is not configured');
  await expect(page.locator('#token-anomaly-status')).not.toContainText('$0.000000');

  pricing = 'partial';
  callInBatch = 0;
  await page.getByLabel('I approve this bounded batch of billable Foundry model calls.').check();
  await page.getByRole('button', { name: 'Generate Token Anomaly' }).click();
  await expect(page.locator('#token-anomaly-status')).toContainText('Completed 3 calls');
  await expect(page.locator('#token-anomaly-status')).toContainText('partial estimate $0.002000; pricing unavailable for 1 call');
});

test('token anomaly reports usage from an incomplete call and does not replay it', async ({ page }) => {
  let attempts = 0;
  await page.route('**/api/agents/run', route => {
    attempts++;
    route.fulfill({
      status: 502,
      json: {
        error: 'Agent run ended with status incomplete (max_completion_tokens). No tool actions were executed by the console.',
        runId: 'run-incomplete',
        incompleteReason: 'max_completion_tokens',
        inputTokens: 3260,
        outputTokens: 4096,
        estimatedCostUsd: 0.01
      }
    });
  });
  await ready(page);
  await page.getByLabel('Token anomaly calls').selectOption('3');
  await page.getByLabel('I approve this bounded batch of billable Foundry model calls.').check();
  await page.getByRole('button', { name: 'Generate Token Anomaly' }).click();
  await expect(page.locator('#token-anomaly-status')).toContainText('0 completed calls; 7,356 reported tokens');
  await expect(page.locator('#token-anomaly-status')).toContainText('max_completion_tokens');
  expect(attempts).toBe(1);
});

test('tabs preserve console state, support keyboard navigation, and validate agent destinations', async ({ page }) => {
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: 'test-rg', appService: 'test-app', sreUrl: 'https://sre.azure.com/#/agent/test', foundryUrl: 'javascript:alert(1)' } }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await page.getByRole('button', { name: /Trigger Error/ }).click();
  await expect(page.locator('#total')).toHaveText('2');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'Lab Operations', exact: true })).toBeFocused();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true })).toBeFocused();
  await expect(page.locator('#panel-console')).toBeHidden();
  await expect(page.getByLabel('Investigation brief')).toHaveCount(0);
  await expect(page.locator('#sre-open')).toHaveAttribute('href', 'https://sre.azure.com/#/agent/test');
  await expect(page.locator('#foundry-open')).not.toHaveAttribute('href');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).focus();
  await page.keyboard.press('End');
  await expect(page.locator('#tab-foundry')).toBeFocused();
  await page.keyboard.press('Home');
  await expect(page.locator('#tab-health')).toBeFocused();
  await expect(page.locator('#panel-health')).toBeVisible();
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('#panel-console')).toBeVisible();
  await expect(page.locator('#total')).toHaveText('2');
  await page.getByRole('button', { name: 'Clear session results' }).click();
  await expect(page.locator('#total')).toHaveText('0');
});

test('playground shows actual returned metadata, requires per-task consent, and keeps AI text inert', async ({ page }) => {
  let submitted;
  await page.route('**/api/agents/run', async route => {
    submitted = route.request().postDataJSON();
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    await route.fulfill({ json: { ...answer, text: '<img src=x onerror="window.injected=true">' } });
  });
  await ready(page);
  await page.getByLabel('Task', { exact: true }).fill('Test');
  await expect(page.getByRole('button', { name: 'Run Agent', exact: true })).toBeDisabled();
  await approve(page);
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Completed');
  expect(submitted).toEqual({ agent: 'triage', prompt: 'The app returns an error.', consent: true });
  await expect(page.locator('#agent-results')).toContainText('120');
  await expect(page.locator('#agent-results')).toContainText('32');
  await expect(page.locator('#agent-results')).toContainText('Rates not configured');
  await expect(page.locator('#agent-results')).toContainText(answer.traceId);
  await expect(page.locator('#agent-results')).toContainText('<img');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  await expect(page.getByLabel('I approve billable model usage for this task.')).not.toBeChecked();
  await page.getByRole('button', { name: 'Clear task results' }).click();
  await expect(page.locator('#agent-results')).toBeEmpty();
});

test('playground sends a same-origin referrer through App Service authentication', async ({ page }) => {
  let requests = 0;
  await page.route('**/api/agents/run', async route => {
    requests++;
    const expectedReferrer = new URL('/', route.request().url()).href;
    if (route.request().headers().referer !== expectedReferrer) {
      await route.fulfill({ status: 403, contentType: 'text/html', body: '<h1>Forbidden</h1>' });
      return;
    }
    await route.fulfill({ json: answer });
  });
  await ready(page);
  await approve(page);
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Completed');
  expect(requests).toBe(1);
});

for (const status of [401, 403, 502]) {
  test(`playground reports non-JSON HTTP ${status} without replaying the request`, async ({ page }) => {
    let requests = 0;
    await page.route('**/api/agents/run', async route => {
      requests++;
      await route.fulfill({ status, headers: { 'X-Amlab-Trace-Id': 'platform-failure-trace' },
        contentType: 'text/html', body: status === 401 ? '' : '<h1>private platform diagnostic</h1>' });
    });
    await ready(page);
    await approve(page);
    await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
    await expect(page.locator('#agent-status')).toContainText(`HTTP ${status}`);
    await expect(page.locator('#agent-status')).toContainText('platform-failure-trace');
    await expect(page.locator('#agent-status')).not.toContainText('private platform diagnostic');
    await expect(page.locator('#agent-results')).toBeEmpty();
    await expect(page.getByLabel('I approve billable model usage for this task.')).not.toBeChecked();
    if (status === 401) await expect(page.locator('#agent-sign-in')).toBeVisible();
    expect(requests).toBe(1);
  });
}

test('playground reports unavailable services and recovers after cancellation and upstream failure', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('tab', { name: 'Foundry Playground' }).click();
  await expect(page.locator('#agent-availability')).toContainText('not enabled');
  await expect(page.getByRole('button', { name: 'Run Agent', exact: true })).toBeDisabled();
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: catalog }));
  await page.getByRole('button', { name: 'Refresh agent availability' }).click();
  await expect(page.getByLabel('Agent', { exact: true })).toBeEnabled();
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  await page.route('**/api/agents/run', async route => { await blocked; await route.abort().catch(() => {}); });
  await approve(page);
  const sent = page.waitForRequest('**/api/agents/run');
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await sent;
  await expect(page.getByLabel('Agent', { exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Stopped waiting');
  release();
  await page.unroute('**/api/agents/run');
  await page.route('**/api/agents/run', route => route.fulfill({ status: 429, headers: { 'Retry-After': '15', 'X-Amlab-Trace-Id': 'failure-trace' }, json: { error: 'Foundry capacity exceeded.' } }));
  await approve(page);
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Retry after 15 seconds');
  await expect(page.locator('#agent-status')).toContainText('failure-trace');
});

for (const width of [1440, 390, 320]) {
  test(`agent tabs render without overflow at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 844 });
    await page.route('**/api/agents/run', route => route.fulfill({ json: answer }));
    await ready(page);
    await approve(page);
    await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
    await expect(page.locator('#agent-status')).toContainText('Completed');
    for (const name of ['Foundry Playground', 'SRE MCP Assistant']) {
      await page.getByRole('tab', { name, exact: true }).click();
      await expect(page.locator('.mobile-feedback')).toBeHidden();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const clipped = await page.locator('button, select, h1, h2').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
      expect(clipped).toEqual([]);
      await page.screenshot({ path: testInfo.outputPath(`${name.split(' ')[0].toLowerCase()}-${width}.png`), fullPage: true });
    }
    expect(errors).toEqual([]);
  });
}