const { test, expect } = require('@playwright/test');

async function openTraffic(page) {
  await page.goto('/');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
}

test('API contracts, no-store, W3C correlation, and deterministic checkout', async ({ request }) => {
  const traceId = '0123456789abcdef0123456789abcdef';
  const health = await request.get('/healthz', { headers: { traceparent: `00-${traceId}-0123456789abcdef-01` } });
  expect(health.status()).toBe(200);
  expect(await health.text()).toBe('OK');
  expect(health.headers()['x-amlab-trace-id']).toBe(traceId);
  expect(health.headers()['cache-control']).toBe('no-store');
  const version = await request.get('/api/console/version');
  expect(version.status()).toBe(200);
  expect(version.headers()['cache-control']).toBe('no-store');
  expect(await version.json()).toEqual({ deploymentId: expect.any(String) });
  expect((await version.json()).deploymentId.length).toBeGreaterThan(0);
  const failure = await request.get('/api/explode', { headers: { traceparent: `00-${traceId}-0123456789abcdef-01` } });
  expect(failure.status()).toBe(500);
  expect(failure.headers()['x-amlab-trace-id']).toBe(traceId);
  expect(await failure.text()).not.toContain('StackTrace');
  const success = await request.get('/api/checkout?outcome=success', { headers: { 'X-Amlab-Channel': 'mobile' } });
  expect(success.status()).toBe(200);
  expect((await success.json()).payment).toBe('ok');
  const declined = await request.get('/api/checkout?outcome=declined');
  expect(declined.status()).toBe(402);
  expect((await declined.json()).payment).toBe('declined');
  expect((await request.get('/api/checkout?outcome=invalid')).status()).toBe(400);
  expect((await request.get('/api/checkout', { headers: { 'X-Amlab-Channel': '<script>' } })).status()).toBe(400);
  expect([200, 402]).toContain((await request.get('/api/checkout')).status());
  const config = await request.get('/api/console/config');
  expect(Object.keys(await config.json()).sort()).toEqual(['links', 'performanceCooldownSeconds']);
  expect(await config.text()).not.toMatch(/InstrumentationKey|ConnectionString|password/i);
});

test('real actions update metrics, history, trace details, chart, and reset', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await openTraffic(page);
  await expect(page.getByRole('heading', { name: 'Azure Monitor Lab Control Center' })).toBeVisible();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await expect(page.locator('#health-status')).toContainText('Healthy');
  await page.getByRole('button', { name: /Slow Request/ }).click();
  await expect(page.locator('#live-text')).toHaveText('Slow request in progress');
  await expect(page.getByRole('button', { name: /Trigger Error/ })).toBeDisabled();
  await expect(page.locator('#total')).toHaveText('2');
  await page.getByRole('button', { name: /Trigger Error/ }).click();
  await expect(page.locator('#total')).toHaveText('3');
  await expect(page.locator('#failed')).toHaveText('1');
  await page.getByRole('button', { name: 'Show Intentional error response 3' }).click();
  await expect(page.locator('#response-3 .trace')).toHaveText(/^[0-9a-f]{32}$/);
  await expect(page.locator('#response-3')).toContainText('Expected demo failure');
  await expect(page.locator('#chart-empty')).toBeHidden();
  await page.getByRole('button', { name: 'Clear session results' }).click();
  await expect(page.locator('#total')).toHaveText('0');
  await expect(page.locator('#history-empty')).toBeVisible();
  expect(errors).toEqual([]);
});

test('checkout channel and outcome controls produce business results', async ({ page }) => {
  await openTraffic(page);
  await page.getByLabel('Channel', { exact: true }).selectOption('mobile');
  await page.getByLabel('Payment', { exact: true }).selectOption('success');
  const pending = page.waitForRequest(request => request.url().includes('/api/checkout'));
  await page.getByRole('button', { name: 'Simulate Checkout' }).click();
  expect((await pending).headers()['x-amlab-channel']).toBe('mobile');
  await expect(page.locator('#checkout-result')).toContainText('Paid');
  await page.getByLabel('Payment', { exact: true }).selectOption('declined');
  await page.getByRole('button', { name: 'Simulate Checkout' }).click();
  await expect(page.locator('#checkout-result')).toContainText('Declined');
  await expect(page.locator('#failed')).toHaveText('1');
});

test('bounded traffic run finishes and Stop prevents subsequent requests', async ({ page }) => {
  await openTraffic(page);
  await page.getByLabel('Profile', { exact: true }).selectOption('errors');
  await page.getByLabel('Requests', { exact: true }).selectOption('5');
  await page.getByRole('button', { name: 'Start Run' }).click();
  await expect(page.locator('#run-status')).toHaveText('Completed', { timeout: 15000 });
  await expect(page.locator('#total')).toHaveText('5');
  await expect(page.locator('#failed')).toHaveText('3');
  await expect(page.locator('#run-progress')).toHaveAttribute('value', '5');
  await page.getByRole('button', { name: 'Clear session results' }).click();
  await page.getByLabel('Profile', { exact: true }).selectOption('latency');
  await page.getByRole('button', { name: 'Start Run' }).click();
  await expect(page.locator('#live-text')).toHaveText('Slow request in progress');
  await page.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(page.locator('#run-status')).toHaveText('Stopped');
  await expect(page.locator('#total')).toHaveText('2');
  await expect(page.getByRole('button', { name: 'Start Run' })).toBeEnabled();
  const count = await page.locator('#total').textContent();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText(String(Number(count) + 1));
});

test('performance experiment requires confirmation and respects server cooldown', async ({ page, request }) => {
  await openTraffic(page);
  await page.getByRole('button', { name: 'Run Inefficient Code' }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.locator('#total')).toHaveText('0');
  await page.getByRole('button', { name: 'Run Inefficient Code' }).click();
  await page.getByRole('button', { name: 'Run Experiment', exact: true }).click();
  await expect(page.locator('#total')).toHaveText('1', { timeout: 20000 });
  await expect(page.getByRole('button', { name: 'Run Inefficient Code' })).toBeDisabled();
  const rejected = await request.post('/api/console/performance');
  expect(rejected.status()).toBe(429);
  expect(Number(rejected.headers()['retry-after'])).toBeGreaterThan(0);
  expect(rejected.headers()['x-amlab-trace-id']).toMatch(/^[0-9a-f]{32}$/);
});

test('dependency control reports a result and timeout is explicit', async ({ page }) => {
  await openTraffic(page);
  await page.getByRole('button', { name: /Test Dependency/ }).click();
  await expect(page.locator('#total')).toHaveText('1', { timeout: 20000 });
  await page.route('**/healthz', route => route.abort('failed'));
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#history')).toContainText('Network error');
  await expect(page.getByRole('button', { name: /Check Health/ })).toBeEnabled();
});

test('configured monitoring links are HTTPS-only and response content is inert', async ({ page }) => {
  await page.route('**/api/console/config', route => route.fulfill({ json: {
    links: { ApplicationInsights: 'https://portal.azure.com/#resource/test', Logs: 'javascript:alert(1)', Workbook: null, Grafana: 'https://example.grafana.azure.com/' }, performanceCooldownSeconds: 30
  } }));
  await page.route('**/healthz', route => route.fulfill({ body: '<img src=x onerror="window.injected=true">', headers: { 'X-Amlab-Trace-Id': 'safe-trace' } }));
  await openTraffic(page);
  await expect(page.locator('[data-link="ApplicationInsights"]')).toHaveAttribute('href', 'https://portal.azure.com/#resource/test');
  await expect(page.locator('[data-link="Logs"]')).not.toHaveAttribute('href');
  await page.getByRole('button', { name: /Check Health/ }).click();
  await page.getByRole('button', { name: 'Show Health check response 1' }).click();
  await expect(page.locator('#response-1 pre')).toContainText('<img');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
});

for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }, { width: 320, height: 740 }]) {
  test(`responsive layout and assets at ${viewport.width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize(viewport);
    await openTraffic(page);
    await page.evaluate(() => document.fonts.ready);
    await expect(page.locator('#brand-mark')).toBeVisible();
    await expect(page.locator('#brand-mark')).toHaveAttribute('alt', 'Azure Monitor Lab');
    expect(await page.locator('#brand-mark').evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true);
    await page.getByRole('button', { name: /Check Health/ }).click();
    await expect(page.locator('#total')).toHaveText('1');
    await page.getByRole('button', { name: /Slow Request/ }).click();
    await expect(page.locator('#total')).toHaveText('2');
    await page.getByRole('button', { name: /Trigger Error/ }).click();
    await expect(page.locator('#total')).toHaveText('3');
    if (viewport.width <= 760) {
      await expect(page.locator('#mobile-status')).toBeVisible();
      await expect(page.locator('#mobile-status')).toContainText('HTTP 500');
      await page.getByRole('link', { name: 'View session activity' }).click();
      await expect(page.getByRole('heading', { name: 'This session' })).toBeInViewport();
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const clipped = await page.locator('button, select, h1, h2').evaluateAll(elements => elements.filter(element => element.clientWidth > 0 && element.scrollWidth > element.clientWidth + 2).map(element => element.textContent));
    expect(clipped).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath(`console-${viewport.width}.png`), fullPage: true });
    const pixels = await page.locator('#latency-chart').evaluate(canvas => {
      const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
      let painted = 0;
      for (let index = 3; index < data.length; index += 4) if (data[index] > 0) painted++;
      return painted;
    });
    expect(pixels).toBeGreaterThan(100);
  });
}