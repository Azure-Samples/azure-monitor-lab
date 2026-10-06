import { chromium } from '@playwright/test';

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const baseUrl = new URL(option('base-url', 'http://127.0.0.1:5188'));
const users = Number.parseInt(option('users', '24'), 10);
const concurrency = Number.parseInt(option('concurrency', '4'), 10);
const repeatUsers = Number.parseInt(option('repeat-users', String(Math.ceil(users * 0.25))), 10);
const headed = process.argv.includes('--headed');
if (!['http:', 'https:'].includes(baseUrl.protocol)) throw new Error('Base URL must use HTTP or HTTPS.');
if (baseUrl.protocol === 'http:' && !['localhost', '127.0.0.1', '::1'].includes(baseUrl.hostname)) {
  throw new Error('HTTP is allowed only for a loopback development URL.');
}
if (!Number.isInteger(users) || users < 1 || users > 200) throw new Error('Users must be between 1 and 200.');
if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 10) throw new Error('Concurrency must be between 1 and 10.');
if (!Number.isInteger(repeatUsers) || repeatUsers < 0 || repeatUsers > users) throw new Error('Repeat users must be between 0 and Users.');

const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const browser = await chromium.launch({ headless: !headed });
const results = [];
let next = 0;

function profile(index, repeat = false) {
  const segments = ['new', 'returning', 'premium'];
  const products = ['monitoring-starter', 'agent-operations', 'sre-command'];
  const bucket = repeat ? (index + 2) % 10 : index % 10;
  return {
    user: `demo-user-${String(index + 1).padStart(4, '0')}`,
    segment: repeat ? 'returning' : segments[index % segments.length],
    variant: index % 2 === 0 ? 'A' : 'B',
    product: products[index % products.length],
    support: bucket === 2 || bucket === 7,
    stopAt: bucket === 0 ? 'browse' : bucket === 1 ? 'cart' : bucket === 3 ? 'checkout' : 'complete',
    outcome: bucket === 4 ? 'declined' : 'success',
    repeat
  };
}

async function click(page, selector) {
  await pause(150 + Math.floor(Math.random() * 350));
  await page.locator(selector).click();
}

async function runJourney(data) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const url = new URL('/customer/', baseUrl);
  url.search = new URLSearchParams({
    user: data.user,
    segment: data.segment,
    variant: data.variant,
    outcome: data.outcome,
    source: 'generator'
  });
  try {
    await page.goto(url.href, { waitUntil: 'networkidle' });
    await page.evaluate(() => window.amlabCustomerReady);
    await click(page, '#start-journey');
    if (data.stopAt === 'browse') return { ...data, status: 'abandoned-browse' };
    await click(page, `[data-product="${data.product}"]`);
    await click(page, '#add-to-cart');
    if (data.stopAt === 'cart') return { ...data, status: 'abandoned-cart' };
    if (data.support) {
      await click(page, '#ask-support');
      await page.locator('#support-status').getByText(/Resolved|unavailable/).waitFor();
      await click(page, '#support-return');
    }
    await click(page, '#begin-checkout');
    if (data.stopAt === 'checkout') return { ...data, status: 'abandoned-checkout' };
    await click(page, '#complete-purchase');
    if (data.outcome === 'success') {
      await page.locator('[data-screen="confirmation"]').waitFor();
      await pause(1200);
      return { ...data, status: 'completed' };
    }
    await page.locator('#checkout-status').getByText(/declined/).waitFor();
    await pause(1200);
    return { ...data, status: 'declined' };
  } finally {
    await pause(500);
    await context.close();
  }
}

const journeys = [
  ...Array.from({ length: users }, (_, index) => profile(index)),
  ...Array.from({ length: repeatUsers }, (_, index) => profile(index, true))
];

async function worker() {
  while (true) {
    const index = next++;
    if (index >= journeys.length) return;
    const journey = journeys[index];
    try {
      const result = await runJourney(journey);
      results.push(result);
      console.log(`${result.user}${result.repeat ? ' repeat' : ''}: ${result.status}`);
    } catch (error) {
      results.push({ ...journey, status: 'failed', error: error.message });
      console.error(`${journey.user}: ${error.message}`);
    }
  }
}

try {
  await Promise.all(Array.from({ length: Math.min(concurrency, journeys.length) }, worker));
} finally {
  await browser.close();
}

const summary = results.reduce((groups, result) => {
  (groups[result.status] ??= []).push(result);
  return groups;
}, {});
console.log('\nUsage traffic summary');
for (const [status, entries] of Object.entries(summary)) console.log(`  ${status}: ${entries.length}`);
if (results.some(result => result.status === 'failed')) process.exitCode = 1;
