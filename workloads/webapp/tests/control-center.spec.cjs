const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');

const repository = path.resolve(__dirname, '../../..');
const docsUrl = 'https://github.com/Azure-Samples/azure-monitor-lab/blob/main/docs/';
const context = { resourceGroup: 'rg-azure-monitor-lab', appService: 'app-amlab-demo', sreUrl: null, foundryUrl: null };
const catalog = { available: true, message: 'Connected to existing lab agents', agents: [{ key: 'triage', name: 'Support Triage', model: 'example-model' }] };

for (const width of [1440, 820, 390, 320]) {
  test(`Control Center tabs and card controls have breathing room at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('/');
    await page.evaluate(() => document.fonts.ready);
    const tabs = await page.locator('[role="tab"]').evaluateAll(items => items.map(item => {
      const style = getComputedStyle(item);
      const bounds = item.getBoundingClientRect();
      const container = item.parentElement.getBoundingClientRect();
      return {
        padding: parseFloat(style.paddingLeft),
        height: bounds.height,
        insetTop: bounds.top - container.top,
        insetBottom: container.bottom - bounds.bottom,
        clipped: item.scrollWidth > item.clientWidth + 2
      };
    }));
    for (const tab of tabs) {
      expect(tab.padding).toBeGreaterThanOrEqual(12);
      expect(tab.height).toBeGreaterThanOrEqual(48);
      expect(tab.insetTop).toBeGreaterThanOrEqual(9);
      expect(tab.insetBottom).toBeGreaterThanOrEqual(9);
      expect(tab.clipped).toBe(false);
    }
    for (const id of ['health', 'console', 'operations', 'sre', 'foundry']) {
      await page.locator(`#tab-${id}`).click();
      const panel = page.locator(`#panel-${id}`);
      await expect(panel).toBeVisible();
      const clipped = await panel.locator('button, .button').evaluateAll(items => items
        .filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2)
        .map(item => item.textContent));
      expect(clipped).toEqual([]);
    }
    const insets = await page.locator('#panel-health, .workspace > aside, .workspace > .results, #panel-operations, #panel-sre, #panel-foundry')
      .evaluateAll(items => items.map(item => parseFloat(getComputedStyle(item).paddingLeft)));
    expect(insets.every(inset => inset >= 16)).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}

test('Control Center uses brief panel motion and respects reduced motion', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await page.goto('/');
  await page.locator('#tab-console').click();
  expect(await page.locator('#panel-console').evaluate(item => getComputedStyle(item).animationName)).toBe('lab-panel-enter');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.locator('#tab-health').click();
  expect(await page.locator('#panel-health').evaluate(item => getComputedStyle(item).animationName)).toBe('none');
});

async function prepare(page) {
  await page.route('**/api/agents/context', route => route.fulfill({ json: context }));
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: catalog }));
  await page.route('**/api/sre/availability', route => route.fulfill({ json: { available: true, message: 'MCP tools connected', tools: [], model: 'example-model' } }));
  await page.goto('/');
  await expect(page.locator('#lab-resource')).toHaveText(context.resourceGroup);
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
}

test('Control Center presents two documentation entry points and valid contextual scenario links', async ({ page }) => {
  const operations = [];
  page.on('request', request => { if (request.method() === 'POST') operations.push(request.url()); });
  await prepare(page);
  await expect(page).toHaveTitle('Azure Monitor Lab Control Center');
  await expect(page.getByRole('tab', { name: 'Traffic & Faults', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByRole('link', { name: 'Guide', exact: true })).toHaveAttribute('href', `${docsUrl}LAB-CONTROL-CENTER.md`);
  await expect(page.getByRole('link', { name: 'Scenarios', exact: true })).toHaveAttribute('href', `${docsUrl}DEMO-SCENARIOS.md`);
  const links = await page.locator('[data-documentation]').evaluateAll(items => items.map(item => ({ href: item.href, target: item.target, rel: item.rel })));
  expect(links.length).toBe(16);
  for (const link of links) {
    expect(link.href.startsWith(docsUrl)).toBe(true);
    expect(link.target).toBe('_blank');
    expect(link.rel).toContain('noopener');
    expect(link.rel).toContain('noreferrer');
    const [file, fragment] = link.href.slice(docsUrl.length).split('#');
    const content = fs.readFileSync(path.join(repository, 'docs', file), 'utf8');
    if (fragment) expect(content).toContain(`<a id="${fragment}"></a>`);
  }
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.getByRole('navigation', { name: 'Related scenarios for SRE' })).toBeVisible();
  await page.getByRole('tab', { name: 'Foundry Playground', exact: true }).click();
  await expect(page.getByRole('navigation', { name: 'Related scenarios for Foundry' })).toBeVisible();
  expect(operations).toEqual([]);
  const readme = fs.readFileSync(path.join(repository, 'README.md'), 'utf8');
  expect(readme).toContain('## Use The Lab');
  expect(readme).toContain('docs/LAB-CONTROL-CENTER.md');
  expect(readme).toContain('docs/DEMO-SCENARIOS.md');
});

test('Control Center shares resource and connection status without new background checks', async ({ page }) => {
  let checks = 0;
  page.on('request', request => { if (/\/api\/(agents\/catalog|sre\/availability)$/.test(request.url())) checks++; });
  await prepare(page);
  await expect(page.locator('#lab-app')).toHaveText(context.appService);
  await expect(page.locator('#sre-connection')).toHaveText('Not checked');
  await expect(page.locator('#foundry-connection')).toHaveText('Not checked');
  expect(checks).toBe(0);
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#health-status')).toContainText('Healthy');
  await page.getByRole('tab', { name: 'Foundry Playground', exact: true }).click();
  await expect(page.locator('#foundry-connection')).toHaveText('1 agent available');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-connection')).toHaveText('Runtime connected');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
  await expect(page.locator('#total')).toHaveText('1');
  expect(checks).toBe(2);
  await expect(page.locator('.environment-strip')).toBeVisible();
});

test('Control Center reports unavailable context and sign-in requirements without claiming healthy services', async ({ page }) => {
  await page.route('**/api/agents/context', route => route.abort());
  await page.route('**/api/agents/catalog', route => route.fulfill({ status: 401, json: { available: false, agents: [], message: 'Sign in required' } }));
  await page.route('**/api/sre/availability', route => route.fulfill({ status: 401, json: { available: false, message: 'Sign in required' } }));
  await page.goto('/');
  await expect(page.locator('#lab-resource')).toHaveText('Unavailable');
  await expect(page.locator('#lab-app')).toHaveText('Unavailable');
  await page.getByRole('tab', { name: 'Foundry Playground', exact: true }).click();
  await expect(page.locator('#foundry-connection')).toHaveText('Sign-in required');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-connection')).toHaveText('Sign-in required');
  await expect(page.locator('#health-status')).toContainText('Healthy');
  await expect(page.locator('#total')).toHaveText('0');
});

for (const width of [1440, 390, 320]) {
  test(`Control Center context and navigation fit at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 740 });
    await prepare(page);
    await page.evaluate(() => document.fonts.ready);
    if (width <= 760) {
      expect(await page.evaluate(() => document.querySelector('[data-action="health"]').getBoundingClientRect().bottom
        <= document.querySelector('.mobile-feedback').getBoundingClientRect().top)).toBe(true);
    }
    await page.getByRole('button', { name: /Check Health/ }).click();
    await expect(page.locator('#total')).toHaveText('1');
    await page.getByRole('button', { name: /Slow Request/ }).click();
    await expect(page.locator('#total')).toHaveText('2');
    await page.getByRole('button', { name: /Trigger Error/ }).click();
    await expect(page.locator('#total')).toHaveText('3');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const clipped = await page.locator('button, select, h1, h2, .environment-strip dd').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
    expect(clipped).toEqual([]);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
    const overlap = await page.evaluate(() => {
      const header = document.querySelector('.topbar').getBoundingClientRect();
      const intro = document.querySelector('.intro').getBoundingClientRect();
      const environment = document.querySelector('.environment-strip').getBoundingClientRect();
      const navigation = document.querySelector('.monitoring').getBoundingClientRect();
      return header.bottom > intro.top || intro.bottom > environment.top || environment.bottom > navigation.top;
    });
    expect(overlap).toBe(false);
    expect(await page.locator('#brand-mark').evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true);
    expect(await page.locator('#latency-chart').evaluate(canvas => canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data.some((value, index) => index % 4 === 3 && value > 0))).toBe(true);
    await page.screenshot({ path: testInfo.outputPath(`control-center-${width}.png`), fullPage: true });
    if (process.env.UPDATE_CONTROL_CENTER_SCREENSHOT === '1' && width === 1440) {
      await page.screenshot({ path: path.join(repository, 'docs/images/lab-control-center.png'), fullPage: true });
    }
    expect(errors).toEqual([]);
  });
}