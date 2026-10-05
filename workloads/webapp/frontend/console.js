import '@fontsource-variable/manrope';
import './console.css';
import { initializeAgentViews } from './agents.js';
import { initializeBrowserTelemetry } from './telemetry.js';
import labLogo from '../../../docs/azure-monitor-lab-logo.svg';
import { createIcons, Activity, ArrowRight, ArrowUpRight, BookOpen, ChartNoAxesCombined, Check, ChevronDown, ChevronUp, CircleHelp, Copy, Cpu, Download, ExternalLink, FlaskConical, HeartPulse, Inbox, Logs, MessagesSquare, Network, PanelsTopLeft, Play, RefreshCw, ScanLine, Send, ShoppingCart, Square, Timer, Trash2, TriangleAlert, X } from 'lucide';
import { Chart, LineController, LineElement, PointElement, CategoryScale, LinearScale, Tooltip } from 'chart.js';

const icons = { Activity, ArrowRight, ArrowUpRight, BookOpen, ChartNoAxesCombined, Check, ChevronDown, ChevronUp, CircleHelp, Copy, Cpu, Download, ExternalLink, FlaskConical, HeartPulse, Inbox, Logs, MessagesSquare, Network, PanelsTopLeft, Play, RefreshCw, ScanLine, Send, ShoppingCart, Square, Timer, Trash2, TriangleAlert, X };
const byId = id => document.getElementById(id);
const refreshIcons = () => createIcons({ icons, attrs: { 'aria-hidden': 'true' } });
const actions = {
  health: { title: 'Health check', path: '/healthz' },
  slow: { title: 'Slow request', path: '/api/slow' },
  explode: { title: 'Intentional error', path: '/api/explode' },
  dependency: { title: 'Dependency', path: '/api/dep' },
  checkout: { title: 'Checkout', path: '/api/checkout' },
  performance: { title: 'Performance experiment', path: '/api/console/performance', method: 'POST' }
};
const profiles = { normal: ['health', 'checkout', 'dependency'], latency: ['health', 'slow', 'slow'], errors: ['health', 'explode', 'explode'] };
let history = [];
let totals = { count: 0, failures: 0, latency: 0 };
let busy = false;
let run = null;
let cooldownUntil = 0;
let toastTimer;
let healthCheckVersion = 0;
let configuration = { links: {}, performanceCooldownSeconds: 30 };

initializeBrowserTelemetry();
byId('brand-mark').src = labLogo;
refreshIcons();
Chart.register(LineController, LineElement, PointElement, CategoryScale, LinearScale, Tooltip);
const chart = new Chart(byId('latency-chart'), {
  type: 'line',
  data: { labels: [], datasets: [{ data: [], borderColor: '#006cdb', borderWidth: 2, pointRadius: 3, pointHoverRadius: 5, pointBackgroundColor: [], tension: .2 }] },
  options: {
    responsive: true, maintainAspectRatio: false, animation: false,
    plugins: { tooltip: { callbacks: { label: context => `${Math.round(context.parsed.y)} ms` } } },
    scales: {
      x: { grid: { display: false }, ticks: { maxTicksLimit: 8, color: '#74848f', font: { size: 10 } }, border: { display: false } },
      y: { beginAtZero: true, suggestedMax: 1000, grid: { color: '#e8eef1' }, border: { display: false }, ticks: { maxTicksLimit: 5, color: '#74848f', font: { size: 10 }, callback: value => `${value} ms` } }
    }
  }
});

function startWebAppHealthCheck() {
  byId('health-status').textContent = 'Checking...';
  byId('health-status').removeAttribute('title');
  return ++healthCheckVersion;
}

function reportWebAppHealth(healthy, duration, version) {
  if (version !== healthCheckVersion) return;
  byId('health-status').textContent = `${healthy ? 'Healthy' : 'Unavailable'} / ${Math.round(duration)} ms`;
  byId('health-status').title = `/healthz checked at ${new Date().toLocaleTimeString()}`;
}

async function checkWebAppHealth() {
  const version = startWebAppHealthCheck();
  const started = performance.now();
  let healthy = false;
  try {
    const response = await fetch('/healthz', { cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(10000) });
    healthy = response.ok;
  } catch { healthy = false; }
  reportWebAppHealth(healthy, performance.now() - started, version);
}

function toast(message) {
  clearTimeout(toastTimer);
  byId('toast').textContent = message;
  byId('toast').hidden = false;
  toastTimer = setTimeout(() => { byId('toast').hidden = true; }, 3500);
}

function updateControls() {
  const locked = busy || Boolean(run);
  document.querySelectorAll('[data-action], #start-run, #clear, #channel, #outcome, #profile, #request-count, #interval').forEach(control => { control.disabled = locked; });
  byId('stop-run').disabled = !run || run.stopped;
  const remaining = Math.max(0, Math.ceil((cooldownUntil - Date.now()) / 1000));
  byId('performance').disabled = locked || remaining > 0;
  byId('cooldown').textContent = remaining > 0 ? `Cooldown: ${remaining}s` : 'Confirmation required';
}

function updateMetrics() {
  byId('total').textContent = totals.count.toLocaleString();
  byId('failed').textContent = totals.failures.toLocaleString();
  byId('failure-rate').textContent = `${totals.count ? Math.round(totals.failures / totals.count * 100) : 0}% of requests`;
  byId('average').textContent = totals.count ? Math.round(totals.latency / totals.count).toLocaleString() : '0';
  const recent = history.slice(0, 30).reverse();
  chart.data.labels = recent.map(result => result.sequence);
  chart.data.datasets[0].data = recent.map(result => result.duration);
  chart.data.datasets[0].pointBackgroundColor = recent.map(result => result.ok ? '#006cdb' : '#bb3649');
  chart.update();
  byId('chart-empty').hidden = history.length > 0;
  byId('history-empty').hidden = history.length > 0;
  byId('history-count').textContent = history.length;
  document.dispatchEvent(new Event('lab-evidence-changed'));
}

function makeElement(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}

function iconButton(icon, label) {
  const button = makeElement('button', undefined, 'icon-button');
  button.type = 'button';
  button.title = label;
  button.setAttribute('aria-label', label);
  const graphic = document.createElement('i');
  graphic.dataset.lucide = icon;
  button.append(graphic);
  return button;
}

function appendResult(result) {
  const row = document.createElement('tr');
  row.append(makeElement('td', result.time.toLocaleTimeString([], { hour12: false })));
  row.append(makeElement('td', result.title));
  const statusCell = document.createElement('td');
  statusCell.append(makeElement('span', result.status ? `HTTP ${result.status}` : 'Network error', `badge${result.ok ? '' : ' failed'}`));
  row.append(statusCell, makeElement('td', `${Math.round(result.duration).toLocaleString()} ms`));
  const buttonCell = document.createElement('td');
  const toggle = iconButton('chevron-down', `Show ${result.title} response ${result.sequence}`);
  toggle.setAttribute('aria-expanded', 'false');
  toggle.setAttribute('aria-controls', `response-${result.sequence}`);
  buttonCell.append(toggle);
  row.append(buttonCell);
  const detail = makeElement('tr', undefined, 'detail');
  detail.id = `response-${result.sequence}`;
  detail.hidden = true;
  const cell = document.createElement('td');
  cell.colSpan = 5;
  const header = makeElement('div', undefined, 'detail-header');
  const traceBlock = document.createElement('div');
  traceBlock.append(makeElement('span', 'TRACE ID / APPLICATION INSIGHTS OPERATION ID', 'field-label'), makeElement('code', result.traceId || 'Unavailable', 'trace'));
  header.append(traceBlock);
  if (result.traceId) {
    const copy = iconButton('copy', 'Copy trace ID');
    copy.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(result.traceId); toast('Trace ID copied'); }
      catch { toast('Clipboard unavailable. Select the trace ID to copy it.'); }
    });
    header.append(copy);
  }
  cell.append(header);
  if (result.key === 'explode' && result.status === 500) cell.append(makeElement('p', 'Expected demo failure.'));
  cell.append(makeElement('p', `${result.method} ${result.path}`), makeElement('pre', result.body));
  detail.append(cell);
  toggle.addEventListener('click', () => {
    detail.hidden = !detail.hidden;
    toggle.setAttribute('aria-expanded', String(!detail.hidden));
    toggle.setAttribute('aria-label', `${detail.hidden ? 'Show' : 'Hide'} ${result.title} response ${result.sequence}`);
    toggle.title = toggle.getAttribute('aria-label');
  });
  byId('history').prepend(row, detail);
  while (byId('history').children.length > 200) byId('history').lastElementChild.remove();
  refreshIcons();
}

function showCheckout(result) {
  const container = byId('checkout-result');
  container.replaceChildren();
  let data;
  try { data = JSON.parse(result.body); } catch { return; }
  if (data.cartValue === undefined) { container.textContent = 'Transaction unavailable'; return; }
  container.append(makeElement('span', data.payment === 'ok' ? 'Paid' : 'Declined', `badge${data.payment === 'ok' ? '' : ' failed'}`));
  container.append(makeElement('strong', `Cart ${data.cartValue.toFixed(2)}`), makeElement('span', `${data.items} items`), makeElement('span', result.channel));
}

async function sendRequest(key, overrides = {}) {
  if (busy) return;
  const action = actions[key];
  const healthVersion = key === 'health' ? startWebAppHealthCheck() : null;
  let path = action.path;
  const method = action.method || 'GET';
  const headers = {};
  const channel = overrides.channel || byId('channel').value;
  if (key === 'checkout') {
    path += `?outcome=${encodeURIComponent(overrides.outcome || byId('outcome').value)}`;
    headers['X-Amlab-Channel'] = channel;
  }
  busy = true;
  updateControls();
  byId('live-state').classList.add('busy');
  byId('live-text').textContent = `${action.title} in progress`;
  byId('mobile-status').textContent = `${action.title} in progress`;
  const started = performance.now();
  const startedAt = new Date();
  const ticker = setInterval(() => { byId('elapsed').textContent = `${((performance.now() - started) / 1000).toFixed(1)} s`; }, 100);
  const result = { key, title: action.title, path, method, channel, time: startedAt, status: 0, ok: false, traceId: '', body: '', duration: 0 };
  try {
    const response = await fetch(path, { method, headers, cache: 'no-store', signal: AbortSignal.timeout(15000) });
    result.status = response.status;
    result.ok = response.ok;
    result.traceId = response.headers.get('X-Amlab-Trace-Id') || '';
    const text = await response.text();
    try { result.body = JSON.stringify(JSON.parse(text), null, 2); } catch { result.body = text; }
    result.body = result.body.slice(0, 16000);
    if (key === 'performance' && response.status === 429) {
      const retrySeconds = Number(response.headers.get('Retry-After'));
      cooldownUntil = Date.now() + (Number.isFinite(retrySeconds) && retrySeconds > 0 ? Math.min(retrySeconds, 60) : 30) * 1000;
    }
  } catch (error) {
    result.body = error.name === 'TimeoutError' ? 'Request timed out after 15 seconds. Server work may still be running.' : 'The request could not reach the app. Check connectivity and try again.';
  } finally {
    clearInterval(ticker);
    result.duration = performance.now() - started;
    result.sequence = ++totals.count;
    totals.latency += result.duration;
    if (!result.ok) totals.failures++;
    history.unshift(result);
    history = history.slice(0, 100);
    busy = false;
    byId('live-state').classList.remove('busy');
    byId('live-text').textContent = `${action.title} ${result.ok ? 'completed' : result.key === 'explode' && result.status === 500 ? 'failed as expected' : 'failed'}`;
    byId('elapsed').textContent = `${Math.round(result.duration).toLocaleString()} ms`;
    byId('mobile-status').textContent = `${result.title} / ${result.status ? `HTTP ${result.status}` : 'Network error'}`;
    if (key === 'health') reportWebAppHealth(result.ok, result.duration, healthVersion);
    if (key === 'checkout') showCheckout(result);
    appendResult(result);
    updateMetrics();
    updateControls();
  }
  return result;
}

document.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => sendRequest(button.dataset.action)));

byId('start-run').addEventListener('click', async () => {
  if (run || busy) return;
  const count = Math.min(30, Math.max(1, Number(byId('request-count').value) || 10));
  const interval = Math.min(5000, Math.max(1000, Number(byId('interval').value) || 1000));
  const sequence = profiles[byId('profile').value] || profiles.normal;
  run = { stopped: false, completed: 0, wake: null };
  byId('run-progress').max = count;
  byId('run-progress').value = 0;
  byId('run-count').textContent = `0 / ${count}`;
  byId('run-status').textContent = 'Running';
  updateControls();
  try {
    for (let index = 0; index < count && !run.stopped; index++) {
      const started = performance.now();
      await sendRequest(sequence[index % sequence.length], { outcome: 'success', channel: 'web' });
      run.completed++;
      byId('run-progress').value = run.completed;
      byId('run-count').textContent = `${run.completed} / ${count}`;
      if (run.stopped || run.completed === count) break;
      await new Promise(resolve => {
        const timer = setTimeout(resolve, Math.max(0, interval - (performance.now() - started)));
        run.wake = () => { clearTimeout(timer); resolve(); };
      });
      run.wake = null;
    }
    byId('run-status').textContent = run.stopped ? 'Stopped' : 'Completed';
  } finally { run = null; updateControls(); }
});

byId('stop-run').addEventListener('click', () => {
  if (!run) return;
  run.stopped = true;
  run.wake?.();
  byId('run-status').textContent = busy ? 'Stopping after current request' : 'Stopping';
  updateControls();
});

byId('request-count').addEventListener('change', () => {
  byId('run-progress').max = Number(byId('request-count').value);
  byId('run-progress').value = 0;
  byId('run-count').textContent = `0 / ${byId('request-count').value}`;
  byId('run-status').textContent = 'Ready';
});

byId('performance').addEventListener('click', () => byId('performance-dialog').showModal());
byId('performance-dialog').addEventListener('close', () => {
  if (byId('performance-dialog').returnValue !== 'confirm' || busy || run || Date.now() < cooldownUntil) return;
  cooldownUntil = Date.now() + configuration.performanceCooldownSeconds * 1000;
  sendRequest('performance');
});
setInterval(updateControls, 1000);

byId('clear').addEventListener('click', () => {
  if (busy || run) return;
  history = [];
  totals = { count: 0, failures: 0, latency: 0 };
  byId('history').replaceChildren();
  byId('checkout-result').replaceChildren(makeElement('span', 'No transactions yet', 'muted'));
  byId('live-text').textContent = 'Waiting for a request';
  byId('mobile-status').textContent = 'Waiting for a request';
  byId('elapsed').textContent = '';
  byId('run-progress').value = 0;
  byId('run-count').textContent = `0 / ${byId('request-count').value}`;
  byId('run-status').textContent = 'Ready';
  updateMetrics();
  toast('Session results cleared. Azure telemetry is unchanged.');
});

async function loadConfiguration() {
  try {
    const response = await fetch('/api/console/config', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error('Configuration unavailable');
    configuration = await response.json();
    configuration.performanceCooldownSeconds = Math.max(30, Number(configuration.performanceCooldownSeconds) || 30);
    const configured = new Set();
    document.querySelectorAll('[data-link]').forEach(link => {
      const value = configuration.links?.[link.dataset.link];
      link.title = 'Not configured for this deployment';
      try {
        const url = new URL(value);
        if (url.protocol !== 'https:' || url.username || url.password) return;
        link.href = url.href;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.removeAttribute('aria-disabled');
        link.title = 'Open in Azure; your account permissions apply';
        configured.add(link.dataset.link);
      } catch { link.title = 'Not configured for this deployment'; }
    });
    byId('links-status').textContent = configured.size === 4 ? '' : `${4 - configured.size} destinations not configured`;
  } catch {
    byId('links-status').textContent = 'Monitoring destinations unavailable';
  }
}
loadConfiguration();
initializeAgentViews({
  snapshot: () => history.map(({ time, duration, method, path, status, traceId, title, ok }) => ({ time, duration, method, path, status, traceId, title, ok })),
  resizeChart: () => chart.resize(), toast, refreshIcons, checkWebAppHealth
});