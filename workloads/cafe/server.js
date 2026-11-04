// Lab Café: a tiny coffee shop API for the health model tutorial.
// No npm dependencies on purpose: App Service auto-instrumentation records every
// request and every outgoing storage call, so the health model has data to read.
//
//   GET  /                 menu page            (user flow: browse the menu)
//   GET  /api/menu         menu as JSON         (user flow: browse the menu)
//   POST /api/orders       place an order       (user flow: order coffee)
//   GET  /api/orders/:id   track an order       (user flow: order coffee)
//   GET  /healthz          App Service health check
//
// Storage access uses the web app's managed identity (no keys).
// CHAOS_ORDER_FAILURE_PERCENT simulates a bad release of the order code.

const http = require('http');
const https = require('https');
const crypto = require('crypto');

const port = process.env.PORT || 8080;
const account = process.env.STORAGE_ACCOUNT_NAME;
const blobHost = `${account}.blob.core.windows.net`;
const queueHost = `${account}.queue.core.windows.net`;
const storageApiVersion = '2023-11-03';

const defaultMenu = [
  { id: 'espresso', name: 'Espresso', price: 2.8 },
  { id: 'flat-white', name: 'Flat white', price: 3.9 },
  { id: 'oat-latte', name: 'Oat latte', price: 4.2 },
  { id: 'cold-brew', name: 'Cold brew', price: 4.5 }
];

let cachedToken = { value: null, expiresAt: 0 };

function request(client, options, body) {
  return new Promise((resolve, reject) => {
    const req = client.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function storageToken() {
  if (cachedToken.value && Date.now() < cachedToken.expiresAt - 300000) return cachedToken.value;
  const endpoint = new URL(process.env.IDENTITY_ENDPOINT);
  endpoint.searchParams.set('resource', 'https://storage.azure.com/');
  endpoint.searchParams.set('api-version', '2019-08-01');
  const res = await request(http, {
    hostname: endpoint.hostname,
    port: endpoint.port,
    path: endpoint.pathname + endpoint.search,
    headers: { 'X-IDENTITY-HEADER': process.env.IDENTITY_HEADER }
  });
  if (res.status !== 200) throw new Error(`Managed identity token request failed: ${res.status}`);
  const token = JSON.parse(res.body);
  cachedToken = { value: token.access_token, expiresAt: Number(token.expires_on) * 1000 };
  return cachedToken.value;
}

async function storageCall(method, host, path, body, extraHeaders = {}) {
  const token = await storageToken();
  const headers = { Authorization: `Bearer ${token}`, 'x-ms-version': storageApiVersion, ...extraHeaders };
  if (body) headers['Content-Length'] = Buffer.byteLength(body);
  return request(https, { method, hostname: host, path, headers }, body);
}

async function readMenu() {
  const res = await storageCall('GET', blobHost, '/menu/menu.json');
  if (res.status === 404) {
    await writeBlob('/menu/menu.json', JSON.stringify(defaultMenu));
    return defaultMenu;
  }
  if (res.status !== 200) throw new Error(`Menu read failed: ${res.status}`);
  return JSON.parse(res.body);
}

async function writeBlob(path, json) {
  const res = await storageCall('PUT', blobHost, path, json, {
    'x-ms-blob-type': 'BlockBlob',
    'Content-Type': 'application/json'
  });
  if (res.status !== 201) throw new Error(`Blob write ${path} failed: ${res.status}`);
}

async function readOrder(id) {
  const res = await storageCall('GET', blobHost, `/orders/${id}.json`);
  if (res.status === 404) return null;
  if (res.status !== 200) throw new Error(`Order read failed: ${res.status}`);
  return JSON.parse(res.body);
}

// Optional step: the barista display listens on this queue. A failure here is
// logged but does not fail the order, which is why the health model gives it
// limited impact.
async function notifyBarista(order) {
  const text = Buffer.from(JSON.stringify(order)).toString('base64');
  const body = `<QueueMessage><MessageText>${text}</MessageText></QueueMessage>`;
  const res = await storageCall('POST', queueHost, '/order-events/messages', body, { 'Content-Type': 'application/xml' });
  if (res.status !== 201) throw new Error(`Barista notification failed: ${res.status}`);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

function send(res, status, payload, type = 'application/json') {
  res.writeHead(status, { 'Content-Type': type });
  res.end(type === 'application/json' ? JSON.stringify(payload) : payload);
}

function menuPage(menu) {
  const items = menu
    .map((m) => `<li>${m.name} <b>€${m.price.toFixed(2)}</b> <button onclick="order('${m.id}')">Order</button></li>`)
    .join('');
  return `<!doctype html><html><head><meta charset="utf-8"><title>Lab Café</title></head>
<body style="font-family:system-ui;max-width:32rem;margin:3rem auto"><h1>☕ Lab Café</h1><ul>${items}</ul>
<p id="result" aria-live="polite"></p>
<script>
async function order(item) {
  const result = document.getElementById('result');
  const res = await fetch('/api/orders', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ item }) });
  const body = await res.json();
  result.textContent = res.ok ? 'Order ' + body.id + ': ' + body.item + ' is ' + body.status : 'Sorry, ordering failed (' + res.status + '): ' + body.error;
}
</script></body></html>`;
}

function shouldFailOrder() {
  const percent = Number(process.env.CHAOS_ORDER_FAILURE_PERCENT || 0);
  return Math.random() * 100 < percent;
}

async function placeOrder(req, res) {
  const input = JSON.parse((await readBody(req)) || '{}');
  if (shouldFailOrder()) throw new Error('Chaos: order service is having a bad day');
  const menu = await readMenu();
  const item = menu.find((m) => m.id === input.item);
  if (!item) return send(res, 400, { error: `Unknown item '${input.item}'` });
  const order = { id: crypto.randomUUID(), item: item.id, price: item.price, status: 'brewing', placedAt: new Date().toISOString() };
  await writeBlob(`/orders/${order.id}.json`, JSON.stringify(order));
  try {
    await notifyBarista(order);
  } catch (err) {
    console.error(err.message);
  }
  send(res, 201, order);
}

async function route(req, res) {
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { status: 'ok' });
  if (req.method === 'GET' && url.pathname === '/') return send(res, 200, menuPage(await readMenu()), 'text/html');
  if (req.method === 'GET' && url.pathname === '/api/menu') return send(res, 200, await readMenu());
  if (req.method === 'POST' && url.pathname === '/api/orders') return placeOrder(req, res);
  const match = url.pathname.match(/^\/api\/orders\/([0-9a-f-]{36})$/);
  if (req.method === 'GET' && match) {
    const order = await readOrder(match[1]);
    return order ? send(res, 200, order) : send(res, 404, { error: 'Order not found' });
  }
  send(res, 404, { error: 'Not found' });
}

http
  .createServer((req, res) => {
    route(req, res).catch((err) => {
      console.error(err.message);
      send(res, 500, { error: err.message });
    });
  })
  .listen(port, () => console.log(`Lab Café listening on ${port}`));
