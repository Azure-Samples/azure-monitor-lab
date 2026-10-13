import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { customerPurchaseOutcome } from '../customer-journey-outcome.mjs';
import {
  createRequestPacer,
  fetchWithRateLimit,
  isCustomerApiUrl,
  retryAfterMilliseconds
} from '../../workloads/webapp/scripts/usage-traffic-pacing.mjs';

test('disabled synthetic checkout retains completed outcome', () => {
  assert.equal(customerPurchaseOutcome('Order confirmed', ''), 'completed');
});

test('real order acceptance is separate from durable completion', () => {
  assert.equal(customerPurchaseOutcome('Order accepted', 'Processing state: Pending'), 'accepted-pending');
  assert.equal(customerPurchaseOutcome('Order accepted', 'Processing state: Queued'), 'accepted-queued');
  assert.equal(customerPurchaseOutcome('Order confirmed', 'Processing state: Completed'), 'completed');
});

test('unverified or conflicting completion fails closed', () => {
  for (const [heading, status] of [
    ['Order accepted', ''],
    ['Order confirmed', 'Processing state: Queued'],
    ['Order accepted', 'Order processing status could not be verified. Retry later.']
  ]) {
    assert.throws(() => customerPurchaseOutcome(heading, status), /not verified/);
  }
});

test('generator and copied runner context include outcome helper without polling', () => {
  const generator = readFileSync(new URL('../../workloads/webapp/scripts/generate-usage-traffic.mjs', import.meta.url), 'utf8');
  const bootstrap = readFileSync(new URL('../initialize-webapp-console.ps1', import.meta.url), 'utf8');
  assert.match(generator, /customerPurchaseOutcome\(heading, processingStatus\)/);
  assert.match(generator, /import .*customer-journey-outcome\.mjs/);
  assert.match(generator, /unrouteAll\(\{ behavior: 'wait' \}\)/);
  assert.doesNotMatch(generator, /trackLabEvent|PurchaseCompleted|refresh-order/);
  assert.match(bootstrap, /'scripts\/customer-journey-outcome\.mjs'/);
});

test('retry-after supports seconds and HTTP dates', () => {
  const now = Date.parse('2026-10-13T12:00:00Z');
  assert.equal(retryAfterMilliseconds('12', now), 12000);
  assert.equal(retryAfterMilliseconds('Tue, 13 Oct 2026 12:00:07 GMT', now), 7000);
  assert.equal(retryAfterMilliseconds('invalid', now), null);
});

test('customer API matcher accepts Playwright URL objects', () => {
  const baseUrl = new URL('https://customer.example/');
  assert.equal(isCustomerApiUrl(new URL('https://customer.example/api/customer/products'), baseUrl), true);
  assert.equal(isCustomerApiUrl(new URL('https://customer.example/api/telemetry/config'), baseUrl), false);
  assert.equal(isCustomerApiUrl(new URL('https://other.example/api/customer/products'), baseUrl), false);
});

test('request pacer serializes concurrent requests', async () => {
  let now = 0;
  const delays = [];
  const pace = createRequestPacer({
    minimumIntervalMs: 1100,
    now: () => now,
    pause: async delay => {
      delays.push(delay);
      now += delay;
    }
  });
  await Promise.all([pace(), pace(), pace()]);
  assert.deepEqual(delays, [1100, 1100]);
});

test('rate-limited fetch honors retry-after and remains bounded', async () => {
  const statuses = [429, 429, 200];
  const disposed = [];
  const delays = [];
  let paced = 0;
  const route = {
    async fetch() {
      const status = statuses.shift();
      return {
        status: () => status,
        headerValue: async () => '2',
        dispose: async () => disposed.push(status)
      };
    }
  };
  const response = await fetchWithRateLimit(route, {
    pace: async () => paced++,
    pause: async delay => delays.push(delay)
  });
  assert.equal(response.status(), 200);
  assert.equal(paced, 3);
  assert.deepEqual(delays, [2000, 2000]);
  assert.deepEqual(disposed, [429, 429]);
});
