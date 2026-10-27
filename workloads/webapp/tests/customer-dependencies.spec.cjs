const { test, expect } = require('@playwright/test');

async function realBackend(page) {
  await page.route('**/api/customer/dependencies', route => route.fulfill({ json: { enabled: true } }));
  await page.route('**/api/customer/products', route => route.fulfill({ json: [
    { id: 'monitoring-starter', name: 'Monitoring Starter', price: 49 },
    { id: 'agent-operations', name: 'Agent Operations', price: 89 },
    { id: 'sre-command', name: 'SRE Command', price: 129 }
  ] }));
}

async function checkout(page) {
  await page.goto('/customer/?outcome=success');
  await page.getByRole('button', { name: 'Explore products' }).click();
  await page.getByRole('button', { name: /Monitoring Starter/ }).click();
  await page.getByRole('button', { name: 'Add to cart' }).click();
  await page.getByRole('button', { name: 'Continue to checkout' }).click();
  await page.getByRole('button', { name: 'Complete purchase' }).click();
}

test('SQL catalogue and queued orders require processor completion before confirmation', async ({ page }) => {
  await realBackend(page);
  let order;
  await page.route('**/api/customer/orders', route => {
    order = route.request().postDataJSON();
    route.fulfill({ status: 202, json: { ...order, status: 'Queued' } });
  });
  await page.route('**/api/customer/orders/*', route => route.fulfill({ json: { ...order, status: 'Completed' } }));
  await checkout(page);
  await expect(page.getByRole('heading', { name: 'Order accepted' })).toBeVisible();
  await expect(page.locator('#confirmation-order')).toHaveText(order.id);
  await expect(page.locator('#confirmation-detail')).toContainText('not fulfilment');
  await expect(page.getByRole('heading', { name: 'Order confirmed' })).toBeVisible();
  await expect(page.locator('#order-status')).toHaveText('Processing state: Completed');
});

test('terminal processor failure becomes a visible customer error', async ({ page }) => {
  await realBackend(page);
  let order;
  let lookups = 0;
  await page.route('**/api/customer/orders', route => {
    order = route.request().postDataJSON();
    route.fulfill({ status: 202, json: { ...order, status: 'Queued' } });
  });
  await page.route('**/api/customer/orders/*', route => {
    lookups++;
    route.fulfill({ json: { ...order, status: lookups < 2 ? 'Queued' : 'Failed' } });
  });
  await checkout(page);
  await expect(page.getByRole('heading', { name: 'Order processing failed' })).toBeVisible();
  await expect(page.locator('#confirmation-detail')).toContainText('failed all processing attempts');
  await expect(page.locator('#order-status')).toHaveText('Processing state: Failed');
  await expect(page.locator('#order-status')).toHaveClass(/error/);
});

test('failed dispatch retries the same order ID and never claims success', async ({ page }) => {
  await realBackend(page);
  const attempts = [];
  await page.route('**/api/customer/orders', route => {
    const order = route.request().postDataJSON();
    attempts.push(order.id);
    route.fulfill(attempts.length === 1
      ? { status: 500, json: { title: 'Lab request failed' } }
      : { status: 202, json: { ...order, status: 'Pending' } });
  });
  await checkout(page);
  await expect(page.locator('#checkout-status')).toContainText('preserved order ID');
  await expect(page.getByRole('heading', { name: 'Order confirmed' })).not.toBeVisible();
  await page.getByRole('button', { name: 'Complete purchase' }).click();
  await expect(page.getByRole('heading', { name: 'Order accepted' })).toBeVisible();
  expect(attempts).toHaveLength(2);
  expect(attempts[0]).toBe(attempts[1]);
});

test('catalogue failure does not fall back to synthetic products', async ({ page }) => {
  await realBackend(page);
  await page.route('**/api/customer/products', route => route.fulfill({ status: 500, json: { title: 'Failed' } }));
  await page.goto('/customer/');
  await page.getByRole('button', { name: 'Explore products' }).click();
  await expect(page.locator('#dependency-status')).toContainText('catalogue is unavailable');
  await expect(page.getByRole('heading', { name: 'Choose your observability package' })).not.toBeVisible();
});

test('disabled feature advertises synthetic mode and does not expose live order endpoints', async ({ request }) => {
  const mode = await request.get('/api/customer/dependencies');
  expect(await mode.json()).toEqual({ enabled: false });
  expect((await request.post('/api/customer/orders', { data: { id: 'a40c55d9-2f90-42ce-8507-d719bf84d350', productId: 'monitoring-starter' } })).status()).toBe(404);
});
