export function initializeHealthModel({ refreshIcons }) {
  const byId = id => document.getElementById(id);
  const states = { healthy: 'Healthy', degraded: 'Degraded', unhealthy: 'Unhealthy', unknown: 'Unknown' };
  const styles = { healthy: 'infra-healthy', degraded: 'infra-warning', unhealthy: 'infra-critical', unknown: 'infra-unknown' };
  const icons = { healthy: 'check', degraded: 'triangle-alert', unhealthy: 'x', unknown: 'circle-help' };
  let models = [];
  let snapshot = null;
  let reported = null;
  let pending = false;
  let sending = false;
  let attempted = false;
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
    const visit = (name, depth, path) => {
      const entity = byName.get(name);
      if (!entity || path.has(name)) return;
      rows.push({ entity, depth });
      seen.add(name);
      for (const child of entity.children || []) visit(child, depth + 1, new Set([...path, name]));
    };
    starts.forEach(name => visit(name, 0, new Set()));
    entities.filter(entity => !seen.has(entity.name)).forEach(entity => rows.push({ entity, depth: 0 }));
    return rows;
  }
  function value(signal) {
    if (signal.value === null || signal.value === undefined) return 'No value';
    return `${Number(signal.value).toLocaleString([], { maximumFractionDigits: 2 })}${signal.unit ? ` ${signal.unit}` : ''}`;
  }
  function render() {
    const model = selected();
    const entities = snapshot?.entities || [];
    for (const status of Object.keys(states)) byId(`hm-count-${status}`).textContent = snapshot ? entities.filter(entity => state(entity.state) === status).length : '-';
    byId('hm-count-total').textContent = snapshot ? entities.length : '-';
    byId('hm-checked').textContent = snapshot?.checkedAt ? `Checked ${time(snapshot.checkedAt)}` : 'Not checked';
    const rows = ordered(entities, model?.name);
    byId('hm-rows').replaceChildren(...rows.map(({ entity, depth }) => {
      const row = element('tr');
      if (reported && reported.model === model?.name && reported.entity === entity.name) row.className = 'hm-reported';
      const name = element('td');
      name.dataset.label = 'Entity';
      name.style.paddingLeft = `${12 + depth * 18}px`;
      name.append(element('strong', entity.displayName || entity.name), element('small', entity.icon ? `${entity.name} / ${entity.icon}` : entity.name));
      const status = element('td');
      status.dataset.label = 'State';
      status.append(badge(entity.state));
      const signals = element('td');
      signals.dataset.label = 'Signals';
      if (!entity.signals?.length) signals.append(element('span', 'Rolls up from its children', 'muted'));
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
      const option = element('option', `${'\u00a0\u00a0'.repeat(depth)}${item.displayName || item.name}`);
      option.value = item.name;
      return option;
    }));
    if (!rows.length && model?.defaultEntity) {
      const option = element('option', model.defaultEntity);
      option.value = model.defaultEntity;
      entity.append(option);
    }
    entity.value = [...entity.options].some(option => option.value === choice) ? choice : model?.defaultEntity || '';
    byId('hm-refresh').disabled = pending || !model;
    byId('hm-report').disabled = pending || sending || !model || !entity.value;
    refreshIcons();
  }
  function status(text) { byId('hm-status').textContent = text; }
  async function read(response) { try { return await response.json(); } catch { return {}; } }
  async function loadModels() {
    const response = await fetch('/api/healthmodels', { cache: 'no-store', signal: AbortSignal.timeout(15000) });
    byId('hm-sign-in').hidden = response.status !== 401;
    if (response.status === 401) { status('Sign in with an approved lab operator account to view health models.'); return false; }
    const data = await read(response);
    models = response.ok && Array.isArray(data.models) ? data.models : [];
    byId('hm-model').replaceChildren(...models.map(model => {
      const option = element('option', `${model.displayName || model.name} (${model.name})`);
      option.value = model.name;
      return option;
    }));
    if (!models.length) status(data.error || 'No health model is configured. Enable health access for this app.');
    return models.length > 0;
  }
  async function refresh() {
    const model = selected();
    if (!model || pending) return;
    pending = true;
    byId('panel-healthmodel').setAttribute('aria-busy', 'true');
    status(`Reading ${model.name}...`);
    render();
    try {
      const response = await fetch(`/api/healthmodels/${encodeURIComponent(model.name)}`, { cache: 'no-store', signal: AbortSignal.timeout(30000) });
      const data = await read(response);
      byId('hm-sign-in').hidden = response.status !== 401;
      if (response.ok && data.available && Array.isArray(data.entities)) {
        snapshot = data;
        status(data.message || 'Health model read.');
      } else {
        snapshot = null;
        status(data.message || data.error || 'The health model could not be read.');
      }
    } catch {
      snapshot = null;
      status('The health model could not be reached. Check connectivity and retry.');
    } finally {
      pending = false;
      byId('panel-healthmodel').setAttribute('aria-busy', 'false');
      render();
    }
  }
  async function send() {
    const model = selected();
    const entity = byId('hm-entity').value;
    if (!model || !entity || sending) return;
    sending = true;
    render();
    byId('hm-report-status').textContent = `Sending a Degraded report to ${entity}...`;
    try {
      const response = await fetch(`/api/healthmodels/${encodeURIComponent(model.name)}/reports`, {
        method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(30000),
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' }, body: JSON.stringify({ entity })
      });
      const data = await read(response);
      byId('hm-report-status').textContent = data.message || data.error || 'The health report could not be sent.';
      if (response.ok && data.sent) {
        reported = { model: model.name, entity: data.entity };
        timers.forEach(clearTimeout);
        timers = [5000, 20000, 45000].map(delay => setTimeout(refresh, delay));
      }
    } catch {
      byId('hm-report-status').textContent = 'The health report could not be sent. Check connectivity and retry.';
    } finally {
      sending = false;
      render();
    }
  }
  async function load() {
    if (attempted) return;
    attempted = true;
    try {
      if (await loadModels()) await refresh();
    } catch {
      attempted = false;
      status('Health models could not be reached. Check connectivity and retry.');
    }
    render();
  }
  byId('hm-model').addEventListener('change', () => { snapshot = null; byId('hm-entity').value = ''; byId('hm-report-status').textContent = ''; render(); refresh(); });
  byId('hm-entity').addEventListener('change', render);
  byId('hm-refresh').addEventListener('click', refresh);
  byId('hm-report').addEventListener('click', send);
  return { load };
}
