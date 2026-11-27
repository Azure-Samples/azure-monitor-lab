import { guides } from './guides.js';

const source = 'https://github.com/Azure-Samples/azure-monitor-lab/blob/main/docs/DEMO-SCENARIOS.md';
const deepLinked = new URLSearchParams(location.search).has('scenario');
const state = {
  scenarios: [],
  lane: 'all',
  stage: 'all',
  query: '',
  selected: Number(new URLSearchParams(location.search).get('scenario')) || 1,
  progressAvailable: true
};
const list = document.querySelector('#scenario-list');
const detail = document.querySelector('#scenario-detail');
const count = document.querySelector('#result-count');
const search = document.querySelector('#scenario-search');
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (character) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[character]);
const progressKey = (id) => `amlab-manual-v1-${id}`;

function readProgress(id) {
  try {
    const saved = JSON.parse(localStorage.getItem(progressKey(id)) ?? '[]');
    if (!Array.isArray(saved) || !saved.every((step) => typeof step === 'string')) throw new Error('Invalid checklist data');
    return saved;
  } catch {
    state.progressAvailable = false;
    return [];
  }
}

function writeProgress(id, steps) {
  try {
    localStorage.setItem(progressKey(id), JSON.stringify(steps));
  } catch {
    state.progressAvailable = false;
    renderDetail();
  }
}

function filteredScenarios() {
  const query = state.query.toLocaleLowerCase();
  return state.scenarios.filter((scenario) =>
    (state.lane === 'all' || scenario.lane === state.lane) &&
    (state.stage === 'all' || (state.stage === 'core' ? !scenario.stage : Boolean(scenario.stage))) &&
    (!query || `${scenario.title} ${scenario.id} ${scenario.summary} ${scenario.categories.join(' ')} ${scenario.stage ?? ''}`.toLocaleLowerCase().includes(query))
  );
}

function updateLocation() {
  const url = new URL(location.href);
  url.searchParams.set('scenario', state.selected);
  url.hash = 'explorer';
  history.pushState({ scenario: state.selected }, '', url);
}

function renderList() {
  const scenarios = filteredScenarios();
  count.textContent = `${scenarios.length} ${scenarios.length === 1 ? 'scenario' : 'scenarios'} found`;
  if (scenarios.length && !scenarios.some(({ id }) => id === state.selected)) {
    state.selected = scenarios[0].id;
    updateLocation();
  }
  list.innerHTML = scenarios.length ? scenarios.map((scenario) => `
    <div role="listitem"><button type="button" class="scenario-card ${scenario.id === state.selected ? 'selected' : ''}"
      data-scenario="${scenario.id}" aria-current="${scenario.id === state.selected ? 'true' : 'false'}">
      <span class="card-top"><span class="scenario-number">SCENARIO ${String(scenario.id).padStart(2, '0')}</span>
      <span class="card-badge ${guides[scenario.id] ? 'badge-guided' : scenario.stage ? '' : 'badge-core'}">${guides[scenario.id] ? 'GUIDED' : scenario.stage ? 'OPTIONAL' : 'CORE'}</span></span>
      <span class="card-title">${escapeHtml(scenario.title)}</span>
      ${scenario.summary ? `<span class="card-summary">${escapeHtml(scenario.summary)}</span>` : ''}
    </button></div>`).join('') : '<p class="empty-state">No matching scenarios. Try another service or choose “All scenarios”.</p>';
  renderDetail(scenarios.length > 0);
}

function stepList(id, prefix, steps) {
  const completed = readProgress(id);
  return `<ol class="step-list">${steps.map((step, index) => {
    const key = `${prefix}${index}`;
    return `<li><label class="step"><input type="checkbox" data-step="${key}" ${completed.includes(key) ? 'checked' : ''}>
      <span class="step-number">${prefix === 's' ? String(index + 1).padStart(2, '0') : '✓'}</span>
      <span class="step-text">${escapeHtml(step)}</span></label></li>`;
  }).join('')}</ol>`;
}

function renderDetail(visible = true) {
  const scenario = state.scenarios.find(({ id }) => id === state.selected);
  if (!visible || !scenario) {
    detail.innerHTML = '<p class="empty-state">Select a scenario to see its guide.</p>';
    return;
  }
  const guide = guides[scenario.id];
  const progress = guide ? readProgress(scenario.id) : [];
  const total = guide ? guide.before.length + guide.steps.length : 0;
  const completed = guide ? [...guide.before.map((_, i) => `b${i}`), ...guide.steps.map((_, i) => `s${i}`)].filter((step) => progress.includes(step)).length : 0;
  const stage = scenario.stage ? `<div class="stage-warning"><strong>Optional stage: ${escapeHtml(scenario.stage)}.</strong> Confirm deployment, completion, permissions and costs in the full walkthrough before you begin.</div>` : '';

  detail.innerHTML = `
    <div class="detail-topline"><span class="detail-index">SCENARIO ${String(scenario.id).padStart(2, '0')} / ${escapeHtml(scenario.lane.toUpperCase())}</span>
      <span class="detail-tag">${guide ? 'STEP-BY-STEP GUIDE' : 'SOURCE WALKTHROUGH'}</span></div>
    <h3>${escapeHtml(scenario.title)}</h3>
    <p class="detail-lead">${escapeHtml(guide?.intro || scenario.summary || 'Explore this scenario in the full documented walkthrough.')}</p>
    <div class="detail-meta">${scenario.time ? `<span>◷ ${escapeHtml(scenario.time)}</span>` : ''}<span>${scenario.stage ? escapeHtml(scenario.stage) : 'Core lab / check scenario prerequisites'}</span></div>
    ${stage}
    ${guide ? `
      <div class="guide-progress"><div class="guide-progress-top"><span>Your checklist</span><span>${completed} / ${total} complete</span></div>
        <div class="progress-track" role="progressbar" aria-label="Guide progress" aria-valuenow="${completed}" aria-valuemin="0" aria-valuemax="${total}"><div class="progress-fill" style="width:${Math.round(completed / total * 100)}%"></div></div>
        <p class="progress-note">${state.progressAvailable ? 'Saved only in this browser. Checkmarks are reminders, not proof of Azure deployment or recovery.' : 'Browser storage is unavailable; checkmarks will not persist.'}</p></div>
      <section class="guide-section"><h4>Before you start</h4>${stepList(scenario.id, 'b', guide.before)}</section>
      <section class="guide-section"><h4>Run the demo</h4>${stepList(scenario.id, 's', guide.steps)}</section>
      <div class="result-box"><strong>What you should see</strong>${escapeHtml(guide.verify)}</div>
      <div class="result-box after-box"><strong>Recovery &amp; cleanup</strong>${escapeHtml(guide.after)}</div>
      <div class="more-links">${guide.docs.map((doc) => `<a href="${escapeHtml(doc.href)}" target="_blank" rel="noopener noreferrer">${escapeHtml(doc.label)} ↗<span class="sr-only"> (opens in a new tab)</span></a>`).join('')}</div>
    ` : `<div class="source-note"><strong>Full tutorial in the repository.</strong><br>The numbered walkthrough has the detailed click-path, commands and caveats for this scenario. Open it before changing your lab; this overview does not replace its setup or safety instructions.</div>`}
    <div class="detail-actions"><a href="${source}#s${scenario.id}" target="_blank" rel="noopener noreferrer">Open full walkthrough ↗<span class="sr-only"> (opens in a new tab)</span></a>
      <button type="button" data-copy>Copy link to scenario</button>${guide && completed ? '<button type="button" data-reset>Reset checklist</button>' : ''}</div>
    <p class="sr-only" id="action-status" role="status"></p>`;
}

function setLane(lane) {
  state.lane = lane;
  document.querySelectorAll('.filter-button').forEach((button) => {
    const active = button.dataset.lane === lane;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
  renderList();
}

document.querySelectorAll('[data-lane]').forEach((button) => button.addEventListener('click', () => {
  search.value = '';
  state.query = '';
  setLane(button.dataset.lane);
  document.querySelector('#explorer').scrollIntoView({ behavior: 'smooth' });
}));

document.querySelectorAll('[data-component]').forEach((button) => button.addEventListener('click', () => {
  state.query = button.dataset.component;
  search.value = state.query;
  setLane(button.dataset.componentLane);
  document.querySelector('#explorer').scrollIntoView({ behavior: 'smooth' });
  search.focus({ preventScroll: true });
}));

search.addEventListener('input', () => { state.query = search.value.trim(); renderList(); });
document.querySelector('#stage-filter').addEventListener('change', (event) => {
  state.stage = event.target.value;
  renderList();
});
list.addEventListener('click', (event) => {
  const button = event.target.closest('[data-scenario]');
  if (!button) return;
  state.selected = Number(button.dataset.scenario);
  updateLocation();
  renderList();
  if (matchMedia('(max-width: 900px)').matches) detail.scrollIntoView({ behavior: 'smooth' });
});
detail.addEventListener('change', (event) => {
  const checkbox = event.target.closest('[data-step]');
  if (!checkbox) return;
  const completed = new Set(readProgress(state.selected));
  if (checkbox.checked) completed.add(checkbox.dataset.step);
  else completed.delete(checkbox.dataset.step);
  writeProgress(state.selected, [...completed]);
  renderDetail();
  detail.querySelector(`[data-step="${checkbox.dataset.step}"]`)?.focus();
});
detail.addEventListener('click', async (event) => {
  if (event.target.closest('[data-reset]')) {
    if (!confirm('Clear this scenario’s checklist in this browser?')) return;
    writeProgress(state.selected, []);
    renderDetail();
  }
  if (event.target.closest('[data-copy]')) {
    try {
      await navigator.clipboard.writeText(location.href);
      detail.querySelector('#action-status').textContent = 'Scenario link copied.';
      event.target.textContent = 'Copied!';
    } catch {
      detail.querySelector('#action-status').textContent = 'Could not copy the link. Copy the address from your browser instead.';
      event.target.textContent = 'Copy unavailable';
    }
  }
});
window.addEventListener('popstate', () => {
  state.selected = Number(new URLSearchParams(location.search).get('scenario')) || 1;
  state.lane = 'all';
  state.stage = 'all';
  state.query = '';
  search.value = '';
  document.querySelector('#stage-filter').value = 'all';
  setLane('all');
});

try {
  const response = await fetch('./catalog.json');
  if (!response.ok) throw new Error(`Catalog request failed (${response.status})`);
  state.scenarios = await response.json();
  if (!state.scenarios.some(({ id }) => id === state.selected)) state.selected = 1;
  renderList();
  if (deepLinked && !location.hash) requestAnimationFrame(() => document.querySelector('#explorer').scrollIntoView());
} catch (error) {
  count.textContent = 'Catalog unavailable';
  detail.innerHTML = `<p class="empty-state">The scenario catalog could not be loaded. Rebuild the site and try again. ${escapeHtml(error.message)}</p>`;
}
