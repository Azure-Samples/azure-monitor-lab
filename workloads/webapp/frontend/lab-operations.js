export function initializeLabOperations({ refreshIcons }) {
  const byId = id => document.getElementById(id);
  const dialog = byId('operation-dialog');
  const ids = new Set(['start', 'stop', 'break', 'restore', 'ramp', 'usage', 'cpu', 'logs', 'annotation']);
  const labels = { queued: 'Queued', waiting: 'Awaiting runner', running: 'Running', succeeded: 'Succeeded', failed: 'Failed', cancelled: 'Cancelled', dispatch_unknown: 'Dispatch outcome unknown', skipped: 'Skipped' };
  const terminal = run => ['succeeded', 'failed', 'cancelled'].includes(run.state);
  let actions = [];
  let target = null;
  let runs = [];
  let selected = null;
  let proposal = null;
  let active = false;
  let loaded = false;
  let available = false;
  let pending = false;
  let approvalSent = false;
  let timer;
  let failures = 0;

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function controls() {
    const blocked = !available || pending || runs.some(run => !terminal(run));
    document.querySelectorAll('[data-operation]').forEach(button => { button.disabled = blocked || !actions.some(action => action.id === button.dataset.operation); });
    byId('operations-connect').disabled = pending || dialog.open;
    byId('operations-refresh').disabled = pending || !available || !runs.some(run => !terminal(run));
    byId('operation-review').disabled = pending;
    byId('operation-approve').disabled = pending || approvalSent || !proposal || Date.now() >= Date.parse(proposal.expiresAt)
      || !byId('operation-consent').checked || byId('operation-target-confirm').value.trim().toLowerCase() !== proposal.target.resourceGroup.toLowerCase();
    document.querySelectorAll('[data-operation-cancel]').forEach(button => { button.disabled = pending; });
  }
  async function request(path, body) {
    const response = await fetch(`/api/operations/${path}`, {
      method: body ? 'POST' : 'GET', cache: 'no-store', signal: AbortSignal.timeout(35000),
      referrerPolicy: 'same-origin',
      headers: body ? { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' } : {},
      body: body ? JSON.stringify(body) : undefined
    });
    byId('operations-sign-in').hidden = response.status !== 401;
    const content = await response.text();
    let data;
    try { data = content ? JSON.parse(content) : null; } catch { data = null; }
    if (!response.ok) {
      if (response.status === 401) available = false;
      const message = typeof data?.error === 'string' ? data.error : typeof data?.message === 'string' ? data.message : null;
      const fallback = response.status === 401 ? 'Sign in again with an approved lab operator account.'
        : response.status === 403 ? 'The request was rejected. Refresh your sign-in before trying again.'
        : 'The operation request could not be completed.';
      throw new Error(message || `${fallback} (HTTP ${response.status})`);
    }
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error(`The server returned an incomplete response (HTTP ${response.status}). No result could be confirmed.`);
    return data;
  }
  function details(values) {
    const list = element('dl', undefined, 'operation-details');
    for (const [name, value] of Object.entries(values)) list.append(element('dt', name), element('dd', String(value ?? 'Not configured')));
    return list;
  }
  function renderRuns() {
    const opened = new Set([...byId('operations-runs').querySelectorAll('details[open]')].map(node => node.dataset.run));
    byId('operations-runs').replaceChildren(...runs.map((run, index) => {
      const item = element('details', undefined, 'operation-run');
      item.dataset.run = run.id;
      item.open = index === 0 || opened.has(run.id);
      const summary = element('summary');
      summary.append(element('strong', actions.find(action => action.id === run.parameters.operation)?.title || 'Lab operation'), element('span', labels[run.state] || 'Unknown', `operation-state ${terminal(run) && run.state !== 'succeeded' ? 'infra-critical' : run.state === 'succeeded' ? 'infra-healthy' : 'infra-warning'}`));
      item.append(summary, element('p', run.message, 'operation-message'));
      const submitted = new Date(run.submittedAt);
      item.append(details({ 'Request ID': run.id, Submitted: Number.isFinite(submitted.getTime()) ? submitted.toLocaleString() : 'Not reported', 'Resource group': run.target.resourceGroup, Execution: run.executionName || 'Pending', Image: run.target.image }));
      const steps = element('ol', undefined, 'operation-steps');
      for (const step of Array.isArray(run.steps) ? run.steps : []) {
        const row = element('li');
        const icon = element('i');
        icon.dataset.lucide = step.state === 'succeeded' ? 'check' : step.state === 'running' ? 'activity' : step.state === 'failed' ? 'triangle-alert' : 'circle-help';
        row.append(icon, element('span', step.name), element('span', labels[step.state] || 'Unknown', 'muted'));
        steps.append(row);
      }
      item.append(steps);
      try {
        const url = new URL(run.url);
        if (url.protocol === 'https:' && url.hostname === 'portal.azure.com' && !url.port && !url.username && !url.password && !url.search
          && url.pathname === '/' && url.hash === `#resource${target.jobResourceId}/overview`) {
          const link = element('a', 'Open Azure job', 'operation-run-link');
          link.href = url.href; link.target = '_blank'; link.rel = 'noopener noreferrer';
          item.append(link);
        }
      } catch {}
      return item;
    }));
    byId('operations-empty').hidden = runs.length > 0;
    byId('operations-run-count').textContent = `${runs.length} run${runs.length === 1 ? '' : 's'}`;
    refreshIcons();
    controls();
  }
  function schedule() {
    clearTimeout(timer);
    if (active && !document.hidden && available && runs.some(run => !terminal(run)) && failures < 3) timer = setTimeout(refreshRuns, 10000);
  }
  async function refreshRuns() {
    if (pending || !available) return;
    pending = true;
    controls();
    try {
      for (const run of runs.filter(run => !terminal(run))) {
        const data = await request(`runs/${encodeURIComponent(run.id)}`);
        if (!data.run || data.run.id !== run.id) throw new Error('Run identity could not be verified.');
        runs = runs.map(item => item.id === run.id ? data.run : item);
      }
      failures = 0;
      byId('operations-updated').textContent = `Updated ${new Date().toLocaleTimeString()}`;
      byId('operations-status').textContent = runs.some(run => !terminal(run)) ? 'An operation is active. Further actions are locked.' : 'Runner status updated.';
    } catch (error) {
      failures++;
      byId('operations-status').textContent = `${error.message} Previous run state is retained.${failures >= 3 ? ' Automatic status checks paused.' : ''}`;
    } finally { pending = false; renderRuns(); schedule(); }
  }
  async function load(force = false) {
    if (pending || (loaded && !force)) { schedule(); return; }
    pending = true;
    loaded = true;
    byId('operations-status').textContent = 'Checking the independent runner...';
    controls();
    try {
      const data = await request('catalog');
      available = data.available === true;
      actions = (Array.isArray(data.actions) ? data.actions : []).filter(action => ids.has(action.id));
      target = data.target;
      byId('operations-status').textContent = data.message;
      byId('operations-context').replaceChildren(details({ 'Resource group': target?.resourceGroup, 'Azure job': target?.jobResourceId, Image: target?.image }));
      if (available) { runs = Array.isArray(data.runs) ? data.runs : []; failures = 0; }
    } catch (error) { available = false; byId('operations-status').textContent = error.message; }
    finally { pending = false; renderRuns(); schedule(); }
  }
  document.querySelectorAll('[data-operation]').forEach(button => button.addEventListener('click', () => {
    if (button.disabled) return;
    selected = actions.find(action => action.id === button.dataset.operation);
    proposal = null;
    approvalSent = false;
    byId('operation-heading').textContent = selected.title;
    byId('operation-impact').textContent = selected.impact;
    byId('operation-prepare-form').reset();
    byId('operation-approve-form').reset();
    const counted = selected.id === 'logs' || selected.id === 'usage';
    byId('operation-count-field').hidden = !counted;
    byId('operation-count-label').textContent = selected.id === 'usage' ? 'Synthetic users' : 'Event count';
    byId('operation-count').value = selected.id === 'usage' ? '24' : '10';
    byId('operation-usage-fields').hidden = selected.id !== 'usage';
    byId('operation-concurrency').disabled = selected.id !== 'usage';
    byId('operation-repeat-users').disabled = selected.id !== 'usage';
    byId('operation-marker-fields').hidden = selected.id !== 'annotation';
    byId('operation-name').required = selected.id === 'annotation';
    byId('operation-name').disabled = selected.id !== 'annotation';
    byId('operation-prepare-form').hidden = false;
    byId('operation-approve-form').hidden = true;
    byId('operation-error').textContent = '';
    dialog.showModal();
    controls();
  }));
  byId('operation-prepare-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (pending || !selected) return;
    pending = true;
    controls();
    try {
      const body = { operation: selected.id };
      if (selected.id === 'logs' || selected.id === 'usage') body.count = Number(byId('operation-count').value);
      if (selected.id === 'usage') {
        body.concurrency = Number(byId('operation-concurrency').value);
        body.repeatUsers = Number(byId('operation-repeat-users').value);
      }
      if (selected.id === 'annotation') { body.name = byId('operation-name').value.trim(); body.category = byId('operation-category').value; }
      const data = await request('prepare', body);
      if (!data.proposal || data.proposal.parameters.operation !== selected.id) throw new Error('Operation approval could not be verified.');
      proposal = data.proposal;
      byId('operation-preview').replaceChildren(details({ Script: proposal.action.script, 'Resource group': proposal.target.resourceGroup, Subscription: proposal.target.subscriptionId,
        Tenant: proposal.target.tenantId, 'Azure job': proposal.target.jobResourceId, Image: proposal.target.image,
        ...(selected.id === 'logs' ? { Events: proposal.parameters.count } : {}),
        ...(selected.id === 'usage' ? { Users: proposal.parameters.count, Concurrency: proposal.parameters.concurrency, 'Repeat users': proposal.parameters.repeatUsers, Route: '/customer/' } : {}),
        ...(selected.id === 'annotation' ? { Marker: proposal.parameters.name, Category: proposal.parameters.category } : {}) }));
      byId('operation-expiry').textContent = `Approval expires ${new Date(proposal.expiresAt).toLocaleTimeString()}`;
      byId('operation-prepare-form').hidden = true;
      byId('operation-approve-form').hidden = false;
      byId('operation-error').textContent = '';
      byId('operation-target-confirm').focus();
    } catch (error) { byId('operation-error').textContent = error.message; }
    finally { pending = false; controls(); }
  });
  byId('operation-approve-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (byId('operation-approve').disabled || !proposal) return;
    pending = true;
    approvalSent = true;
    controls();
    try {
      const data = await request('approval', { proposalId: proposal.id, resourceGroup: byId('operation-target-confirm').value.trim(), approve: true });
      if (!data.run) throw new Error('Dispatch response was not confirmed. Refresh runner history before another operation.');
      runs.unshift(data.run);
      proposal = null;
      dialog.close();
      byId('operations-status').textContent = data.run.message;
      failures = 0;
    } catch (error) {
      available = false;
      proposal = null;
      byId('operation-error').textContent = `${error.message} This approval cannot be resent. Close the dialog and refresh runner history.`;
    } finally { pending = false; renderRuns(); schedule(); }
  });
  async function cancel() {
    if (pending) return;
    const current = proposal;
    proposal = null;
    dialog.close();
    if (current && !approvalSent) {
      pending = true;
      controls();
      try { await request('approval', { proposalId: current.id, resourceGroup: '', approve: false }); }
      catch { byId('operations-status').textContent = 'The unused proposal will expire. No execution was approved.'; }
      finally { pending = false; controls(); }
    }
  }
  document.querySelectorAll('[data-operation-cancel]').forEach(button => button.addEventListener('click', cancel));
  dialog.addEventListener('cancel', event => { event.preventDefault(); void cancel(); });
  dialog.addEventListener('close', controls);
  byId('operation-target-confirm').addEventListener('input', controls);
  byId('operation-consent').addEventListener('change', controls);
  byId('operations-connect').addEventListener('click', () => load(true));
  byId('operations-refresh').addEventListener('click', () => { failures = 0; void refreshRuns(); });
  document.addEventListener('visibilitychange', schedule);
  setInterval(() => { if (dialog.open) controls(); }, 1000);
  return { activate(value) { active = value; if (active) void load(); else clearTimeout(timer); } };
}