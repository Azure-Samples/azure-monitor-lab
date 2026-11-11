const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

test('deployment uses ZipDeploy and an Oryx build for the locked SDK dependencies', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const deploy = fs.readFileSync(path.join(root, 'scripts', 'deploy-healthmodel-tutorial.ps1'), 'utf8');
  const publish = fs.readFileSync(path.join(root, 'scripts', 'publish-healthmodel-cafe.ps1'), 'utf8');
  const template = fs.readFileSync(path.join(root, 'infra', 'healthmodel-tutorial', 'workload.bicep'), 'utf8');
  assert.match(deploy, /publish-healthmodel-cafe\.ps1/);
  assert.match(publish, /az webapp deployment source config-zip\b/);
  assert.match(publish, /'server\.js', 'package\.json', 'package-lock\.json'/);
  assert.match(template, /name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true'/);
  assert.match(template, /name: 'ENABLE_ORYX_BUILD', value: 'true'/);
  assert.match(template, /name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: 'disabled'/);
});

function fixture({ telemetry = false, failQueue = false, failHost = null } = {}) {
  const calls = [];
  const blobs = new Map([
    ['/menu/menu.json', JSON.stringify([{ id: 'flat-white', name: 'Flat white', price: 3.9 }])]
  ]);
  let handler;
  const request = (options, callback) => {
    const req = new EventEmitter();
    let body = '';
    req.setTimeout = () => req;
    req.write = (chunk) => { body += chunk; };
    req.end = () => process.nextTick(() => {
      if (options.hostname === failHost) {
        req.emit('error', new Error(`Request failed with ${options.headers['X-IDENTITY-HEADER'] || options.headers.Authorization}`));
        return;
      }
      const res = new EventEmitter();
      res.complete = true;
      let payload = '';
      if (options.hostname === 'identity.local') {
        res.statusCode = 200;
        payload = JSON.stringify({ access_token: 'fixture-token', expires_on: Date.now() / 1000 + 3600 });
      } else if (options.hostname.endsWith('.queue.core.windows.net')) {
        res.statusCode = failQueue ? 503 : 201;
      } else if (options.method === 'PUT') {
        blobs.set(options.path, body);
        res.statusCode = 201;
      } else {
        res.statusCode = blobs.has(options.path) ? 200 : 404;
        payload = blobs.get(options.path) || '';
      }
      callback(res);
      res.emit('data', Buffer.from(payload));
      res.emit('end');
    });
    return req;
  };
  vm.runInNewContext(source, {
    require(name) {
      calls.push(name);
      if (name === '@azure/monitor-opentelemetry') {
        return { useAzureMonitor(options) { calls.push(['monitor-started', options.samplingRatio]); } };
      }
      if (name === 'http') {
        return { request, createServer(callback) { handler = callback; return { listen() {} }; } };
      }
      if (name === 'https') return { request };
      return require(name);
    },
    process: { env: {
      STORAGE_ACCOUNT_NAME: 'fixture',
      IDENTITY_ENDPOINT: 'http://identity.local/token',
      IDENTITY_HEADER: 'fixture-header',
      ...(telemetry ? { APPLICATIONINSIGHTS_CONNECTION_STRING: 'fixture-connection' } : {})
    } },
    console: { log() {}, error(message) { calls.push(['error', message]); } },
    URL, Buffer
  });
  return {
    calls,
    send(method, url, body) {
      return new Promise((resolve) => {
        const req = new EventEmitter();
        req.method = method;
        req.url = url;
        let status;
        handler(req, {
          writeHead(value) { status = value; },
          end(payload) { resolve({ status, body: JSON.parse(payload) }); }
        });
        process.nextTick(() => {
          if (body) req.emit('data', Buffer.from(JSON.stringify(body)));
          req.emit('end');
        });
      });
    }
  };
}

test('Azure Monitor starts before HTTP modules and samples all tutorial traffic', () => {
  const { calls } = fixture({ telemetry: true });
  assert.deepEqual(calls.slice(0, 3), [
    '@azure/monitor-opentelemetry', ['monitor-started', 1], 'http'
  ]);
});

test('local runs without a connection string do not initialize an exporter', async () => {
  const app = fixture();
  assert.ok(!app.calls.includes('@azure/monitor-opentelemetry'));
  assert.deepEqual(await app.send('GET', '/healthz'), { status: 200, body: { status: 'ok' } });
});

test('instrumented app still reads the menu and persists orders', async () => {
  const app = fixture({ telemetry: true });
  const menu = await app.send('GET', '/api/menu');
  assert.equal(menu.status, 200);
  assert.equal(menu.body[0].id, 'flat-white');
  const order = await app.send('POST', '/api/orders', { item: 'flat-white' });
  assert.equal(order.status, 201);
  assert.equal(order.body.status, 'brewing');
  assert.deepEqual(await app.send('GET', `/api/orders/${order.body.id}`), {
    status: 200, body: order.body
  });
});

test('a failed optional barista notification does not fail the stored order', async () => {
  const app = fixture({ telemetry: true, failQueue: true });
  const order = await app.send('POST', '/api/orders', { item: 'flat-white' });
  assert.equal(order.status, 201);
  assert.ok(app.calls.some((call) => Array.isArray(call) && call[0] === 'error' &&
    call[1] === 'Barista notification failed; the order was saved. Check dependency telemetry.'));
});

test('identity transport errors do not expose credentials in logs or HTTP responses', async () => {
  const app = fixture({ failHost: 'identity.local' });
  const response = await app.send('GET', '/api/menu');
  assert.deepEqual(response, { status: 500, body: { error: 'Request failed. Check application telemetry.' } });
  assert.ok(app.calls.some((call) => Array.isArray(call) && call[0] === 'error' &&
    call[1] === 'Cafe request failed. Check request and dependency telemetry.'));
  assert.doesNotMatch(JSON.stringify({ calls: app.calls, response }), /fixture-header|fixture-token/);
});

test('optional notification transport errors retain the saved order without logging its bearer token', async () => {
  const app = fixture({ failHost: 'fixture.queue.core.windows.net' });
  const order = await app.send('POST', '/api/orders', { item: 'flat-white' });
  assert.equal(order.status, 201);
  assert.deepEqual(await app.send('GET', `/api/orders/${order.body.id}`), {
    status: 200, body: order.body
  });
  assert.ok(app.calls.some((call) => Array.isArray(call) && call[0] === 'error' &&
    call[1] === 'Barista notification failed; the order was saved. Check dependency telemetry.'));
  assert.doesNotMatch(JSON.stringify(app.calls), /fixture-header|fixture-token/);
});
