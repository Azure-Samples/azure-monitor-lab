const { test, expect } = require('@playwright/test');
const { randomUUID } = require('node:crypto');

for (const path of ['/', '/customer/']) {
  test(`browser telemetry enriches SDK page views and dependencies at ${path}`, async ({ page }) => {
    const telemetry = [];
    await page.addInitScript(() => sessionStorage.setItem('amlab.synthetic-session', 'test-synthetic-session'));
    await page.route('**/api/telemetry/config', route => route.fulfill({
      json: {
        enabled: true,
        connectionString: `InstrumentationKey=${randomUUID()};IngestionEndpoint=https://telemetry.example/`,
        serviceName: 'browser-test',
        serviceVersion: 'test-version',
        contentRecordingEnabled: false
      }
    }));
    await page.route('https://telemetry.example/**', route => {
      const body = route.request().postData();
      if (body) {
        const items = body.startsWith('[') ? JSON.parse(body) : body.trim().split('\n').map(line => JSON.parse(line));
        telemetry.push(...items);
      }
      return route.fulfill({ status: 200, json: { itemsReceived: telemetry.length, itemsAccepted: telemetry.length, errors: [] } });
    });
    await page.route('**/api/telemetry-probe', route => route.fulfill({ json: { ok: true } }));
    await page.goto(path);
    await expect.poll(async () => page.evaluate(() =>
      performance.getEntriesByType('resource').some(entry => entry.name.endsWith('/api/telemetry/config'))
    )).toBe(true);
    await page.evaluate(() => fetch('/api/telemetry-probe'));
    await expect.poll(() => telemetry.some(item => item.data?.baseType === 'PageviewData') &&
      telemetry.some(item => item.data?.baseType === 'RemoteDependencyData' &&
        item.data.baseData.data?.includes('/api/telemetry-probe')), { timeout: 30000 }).toBe(true);

    for (const item of telemetry.filter(item => ['PageviewData', 'RemoteDependencyData'].includes(item.data?.baseType))) {
      expect(item.data.baseData.properties).toMatchObject({
        'synthetic.session_id': 'test-synthetic-session',
        'service.name': 'browser-test',
        'service.version': 'test-version',
        'content_recording.enabled': 'false',
        'synthetic.data': 'true'
      });
    }
  });
}
