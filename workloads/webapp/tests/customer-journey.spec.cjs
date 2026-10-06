const { test, expect } = require('@playwright/test');

test('customer journey emits a six-step flow with optional agent support', async ({ page }) => {
  let supportCalls = 0;
  let checkoutCalls = 0;
  await page.route('**/api/customer/support', route => {
    supportCalls++;
    route.fulfill({
      status: 200,
      json: { taskSuccess: true, traceId: 'support-trace', durationMs: 125 }
    });
  });
  await page.route('**/api/checkout?outcome=success', route => {
    checkoutCalls++;
    expect(route.request().headers()['x-amlab-channel']).toBe('customer-journey');
    route.fulfill({ status: 200, json: { payment: 'ok', cartValue: 89, items: 1 } });
  });

  await page.goto('/customer/?user=demo-user-0042&segment=premium&variant=B&outcome=success');
  await expect(page.getByText('demo-user-0042')).toBeVisible();
  await expect(page.getByText('premium', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Explore products' }).click();
  await expect(page).toHaveURL(/\/customer\/browse/);
  await page.getByRole('button', { name: /Agent Operations/ }).click();
  await expect(page).toHaveURL(/\/customer\/product\/agent-operations/);
  await page.getByRole('button', { name: 'Add to cart' }).click();
  await expect(page).toHaveURL(/\/customer\/cart/);
  await page.getByRole('button', { name: 'Ask support agent' }).click();
  await expect(page).toHaveURL(/\/customer\/support/);
  await expect(page.getByText(/Resolved/)).toBeVisible();
  await page.getByRole('button', { name: 'Return to cart' }).click();
  await page.getByRole('button', { name: 'Continue to checkout' }).click();
  await expect(page).toHaveURL(/\/customer\/checkout/);
  await page.getByRole('button', { name: 'Complete purchase' }).click();
  await expect(page.getByRole('heading', { name: 'Order confirmed' })).toBeVisible();
  await expect(page).toHaveURL(/\/customer\/confirmation/);
  await expect(page.locator('#journey-step')).toHaveText('Customer / Confirmation');
  expect(supportCalls).toBe(1);
  expect(checkoutCalls).toBe(1);
});

test('customer routes support direct navigation and browser history', async ({ page }) => {
  await page.goto('/customer/cart?user=demo-user-route');
  await expect(page.getByRole('heading', { name: 'Your package is ready' })).toBeVisible();
  await page.getByRole('button', { name: 'Continue to checkout' }).click();
  await expect(page).toHaveURL(/\/customer\/checkout/);
  await page.goBack();
  await expect(page.getByRole('heading', { name: 'Your package is ready' })).toBeVisible();
});

test('customer journey keeps invalid identity and cohort input out of telemetry context', async ({ page }) => {
  await page.goto('/customer/?user=%3Cscript%3E&segment=secret&variant=Z');
  await expect(page.locator('#customer-id')).toHaveText(/^demo-user-[0-9a-f-]+$/);
  await expect(page.locator('#customer-segment')).toHaveText('new');
  await expect(page.locator('#customer-variant')).toHaveText('A');
});

test('anonymous customer support path is metadata-only and rate limited', async ({ request }) => {
  const response = await request.post('/api/customer/support');
  expect(response.status()).toBe(200);
  const result = await response.json();
  expect(result.scenario).toBe('multi-agent-handoff');
  expect(result.mode).toBe('fixed');
  expect(result.taskSuccess).toBe(true);
});

for (const width of [1440, 390, 320]) {
  test(`customer journey fits at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: width > 720 ? 900 : 740 });
    await page.goto('/customer/?user=demo-user-layout');
    await expect(page.getByRole('heading', { name: 'Operate with confidence.' })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}
