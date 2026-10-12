import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { customerPurchaseOutcome } from '../customer-journey-outcome.mjs';

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
  assert.doesNotMatch(generator, /trackLabEvent|PurchaseCompleted|refresh-order/);
  assert.match(bootstrap, /'scripts\/customer-journey-outcome\.mjs'/);
});
