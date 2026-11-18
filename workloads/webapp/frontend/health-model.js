export function initializeHealthModel({ refreshIcons }) {
  const byId = id => document.getElementById(id);
  const states = { healthy: 'Healthy', degraded: 'Degraded', unhealthy: 'Unhealthy', unknown: 'Unknown' };
  const styles = { healthy: 'infra-healthy', degraded: 'infra-warning', unhealthy: 'infra-critical', unknown: 'infra-unknown' };
  const icons = { healthy: 'check', degraded: 'triangle-alert', unhealthy: 'x', unknown: 'circle-help' };
  let models = [];
  let snapshot = null;
  let reported = null;
  let reading = null;
  let loading = false;
  let sending = false;
  let timers = [];

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function state(value) { return Object.hasOwn(states, value) ? value : 'unknown'; }
  function badge(value) {
    const status = state(value);
    const node = element('span', undefined, `infra-badge ${styles[status]}`);
    const icon = element('i');
    icon.dataset.lucide = icons[status];
    node.append(icon, element('span', states[status]));
    return node;
  }
  function time(value) {
    const date = new Date(value);
    return value && Number.isFinite(date.getTime()) ? date.toLocaleString([], { dateStyle: 'short', timeStyle: 'medium' }) : 'Not reported';
  }
  function selected() { return models.find(model => model.name === byId('hm-model').value); }
  function ordered(entities, root) {
    const byName = new Map(entities.map(entity => [entity.name, entity]));
    const children = new Set(entities.flatMap(entity => entity.children || []));
    const starts = byName.has(root) ? [root] : entities.filter(entity => !children.has(entity.name)).map(entity => entity.name);
    const rows = [];
    const seen = new Set();
    const visit = (name, depth) => {
      const entity = byName.get(name);
      if (!entity || seen.has(name)) return;
      seen.add(name);
      rows.push({ entity, depth });
      for (const child of entity.children || []) visit(child, depth + 1);
    };
    starts.forEach(name => visit(name, 0));
    // Entities the root does not reach keep their own subtrees, parents first.
    entities.filter(entity => !children.has(entity.name)).forEach(entity => visit(entity.name, 0));
    entities.forEach(entity => visit(entity.name, 0));
    return rows;
  }
  function value(signal) {
    if (signal.value === null || signal.value === undefined) return 'No value';
    return `${Number(signal.value).toLocaleString([], { maximumFractionDigits: 2 })}${signal.unit ? ` ${signal.unit}` : ''}`;
  }
  function render() {
    const model = selected();
    const entities = snapshot?.entities || [];
    const highlight = reported && reported.model === model?.name && Date.now() < reported.expiresAt ? reported.entity : null;
    for (const status of Object.keys(states)) byId(`hm-count-${status}`).textContent = snapshot ? entities.filter(entity => state(entity.state) === status).length : '-';
    byId('hm-count-total').textContent = snapshot ? entities.length : '-';
    byId('hm-checked').textContent = snapshot?.checkedAt ? `Checked ${time(snapshot.checkedAt)}` : 'Not checked';
    const rows = ordered(entities, model?.name);
    byId('hm-rows').replaceChildren(...rows.map(({ entity, depth }) => {
      const row = element('tr');
      if (entity.name === highlight) row.className = 'hm-reported';
      const name = element('td');
      name.dataset.label = 'Entity';
      name.style.paddingLeft = `${12 + depth * 18}px`;
      name.append(element('strong', entity.displayName || entity.name), element('small', entity.icon ? `${entity.name} / ${entity.icon}` : entity.name));
      const status = element('td');
      status.dataset.label = 'State';
      status.append(badge(entity.state));
      const signals = element('td');
      signals.dataset.label = 'Signals';
      if (!entity.signals?.length) signals.append(element('span', entity.children?.length ? 'Rolls up from its children' : 'No signals', 'muted'));
      else {
        const list = element('ul', undefined, 'hm-signals');
        list.append(...entity.signals.map(signal => {
          const item = element('li');
          item.append(badge(signal.state), element('span', signal.displayName || signal.name), element('strong', value(signal)));
          const details = [signal.kind === 'External' ? 'External report' : signal.kind, signal.reportedAt ? `reported ${time(signal.reportedAt)}` : null, signal.context].filter(Boolean);
          item.append(element('small', details.join(' / ')));
          return item;
        }));
        signals.append(list);
      }
      row.append(name, status, signals);
      return row;
    }));
    byId('hm-table').hidden = !rows.length;
    byId('hm-empty').hidden = rows.length > 0;
    byId('hm-empty-text').textContent = snapshot ? 'This health model has no entities.' : 'No health model snapshot available.';
    const entity = byId('hm-entity');
    const choice = entity.value || model?.defaultEntity;
    entity.replaceChildren(...rows.map(({ entity: item, depth }) => {
      const option = element('option', `${'  '.repeat(depth)}${item.displayName || item.name}`);
      option.value = item.name;
      return option;
    }));
    if (!rows.length && model?.defaultEntity) {
      const option = element('option', model.defaultEntity);
      option.value = model.defaultEntity;
      entity.append(option);
    }
    entity.value = [...entity.options].some(option => option.value === choice) ? choice : model?.defaultEntity || '';
    byId('hm-refresh').disabled = loading || Boolean(reading);
    byId('hm-report').disabled = Boolean(reading) || sending || !model || !entity.value;
    refreshIcons();
  }
  function status(text) { byId('hm-status').textContent = text; }
  function reportStatus(text) { byId('hm-report-status').textContent = text; }
  async function read(response) { try { return await response.json(); } catch { return {}; } }
  async function loadModels() {
    const response = await fetch('/api/healthmodels', { cache: 'no-store', referrerPolicy: 'same-origin', signal: AbortSignal.timeout(15000) });
    byId('hm-sign-in').hidden = response.status !== 401;
    if (response.status === 401) { status('Sign in with an approved lab operator account to view health models.'); return false; }
    const data = await read(response);
    models = response.ok && Array.isArray(data.models) ? data.models : [];
    byId('hm-model').replaceChildren(...models.map(model => {
      const option = element('option', `${model.displayName || model.name} (${model.name})`);
      option.value = model.name;
      return option;
    }));
    if (!response.ok) status(data.error || 'Health models could not be listed. Retry with Refresh.');
    else if (!models.length) status('No health model is configured. Enable health access for this app.');
    return models.length > 0;
  }
  async function fetchSnapshot(model, signal) {
    try {
      const response = await fetch(`/api/healthmodels/${encodeURIComponent(model.name)}`, { cache: 'no-store', referrerPolicy: 'same-origin', signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]) });
      const data = await read(response);
      const ok = response.ok && data.available && Array.isArray(data.entities);
      return { signIn: response.status === 401, snapshot: ok ? data : null, message: data.message || data.error || 'The health model could not be read.' };
    } catch {
      return { signIn: false, snapshot: null, message: 'The health model could not be reached. Check connectivity and retry.' };
    }
  }
  async function refresh() {
    const model = selected();
    if (!model) return;
    reading?.abort();
    const controller = reading = new AbortController();
    byId('panel-healthmodel').setAttribute('aria-busy', 'true');
    status(`Reading ${model.name}...`);
    render();
    const result = await fetchSnapshot(model, controller.signal);
    if (controller !== reading) return;
    reading = null;
    byId('panel-healthmodel').setAttribute('aria-busy', 'false');
    byId('hm-sign-in').hidden = !result.signIn;
    if (result.snapshot) snapshot = result.snapshot;
    status(result.snapshot || !snapshot ? result.message : `${result.message} Showing the previous read.`);
    render();
  }
  async function post(model, entity) {
    try {
      const response = await fetch(`/api/healthmodels/${encodeURIComponent(model.name)}/reports`, {
        method: 'POST', cache: 'no-store', referrerPolicy: 'same-origin', signal: AbortSignal.timeout(30000),
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' }, body: JSON.stringify({ entity })
      });
      const data = await read(response);
      return { signIn: response.status === 401, sent: response.ok && data.sent === true, expiresAt: Date.parse(data.expiresAt), message: data.message || data.error || 'The health report could not be sent.' };
    } catch {
      return { signIn: false, sent: false, message: 'The health report could not be sent. Check connectivity and retry.' };
    }
  }
  async function send() {
    const model = selected();
    const entity = byId('hm-entity').value;
    if (!model || !entity || sending) return;
    sending = true;
    reportStatus(`Sending a Degraded report to ${entity}...`);
    render();
    const result = await post(model, entity);
    sending = false;
    if (result.sent) reported = { model: model.name, entity, expiresAt: result.expiresAt };
    if (selected() === model) {
      byId('hm-sign-in').hidden = !result.signIn;
      reportStatus(result.message);
      if (result.sent) {
        timers.forEach(clearTimeout);
        timers = [5000, 20000, 45000].map(delay => setTimeout(refresh, delay));
      }
    } else reportStatus(`${model.name}: ${result.message}`);
    render();
  }
  async function load() {
    if (loading || models.length) return;
    loading = true;
    render();
    try {
      if (await loadModels()) await refresh();
    } catch {
      status('Health models could not be reached. Check connectivity and retry.');
    } finally {
      loading = false;
      render();
    }
  }
  byId('hm-model').addEventListener('change', () => {
    timers.forEach(clearTimeout);
    timers = [];
    snapshot = null;
    byId('hm-entity').value = '';
    reportStatus('');
    refresh();
  });
  byId('hm-refresh').addEventListener('click', () => (models.length ? refresh() : load()));
  byId('hm-report').addEventListener('click', send);
  return { load };
}
