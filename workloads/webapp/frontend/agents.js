import { initializeSreAssistant } from './sre-assistant.js';
import { initializeInfrastructureHealth } from './infrastructure-health.js';
import { initializeLabOperations } from './lab-operations.js';

export function initializeAgentViews({ resizeChart, toast, refreshIcons, checkWebAppHealth }) {
  const byId = id => document.getElementById(id);
  const sre = initializeSreAssistant();
  const infrastructure = initializeInfrastructureHealth({ refreshIcons, checkWebAppHealth });
  const operations = initializeLabOperations({ refreshIcons });
  let context = {};
  let availableAgents = [];
  let activeRequest = null;
  let alertStorm = null;
  let tokenAnomaly = null;
  let catalogLoaded = false;
  let refreshing = false;
  const tabs = [...document.querySelectorAll('[role="tab"]')];

  function activate(tab) {
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      byId(item.getAttribute('aria-controls')).hidden = !selected;
    }
    const consoleActive = tab.id === 'tab-console';
    document.querySelector('.mobile-feedback').hidden = !consoleActive;
    document.querySelector('.skip-link').href = consoleActive ? '#controls' : `#${tab.getAttribute('aria-controls')}`;
    document.querySelector('.skip-link').textContent = consoleActive ? 'Skip to lab controls' : 'Skip to active view';
    if (consoleActive) requestAnimationFrame(resizeChart);
    operations.activate(tab.id === 'tab-operations');
    if (tab.id === 'tab-health') infrastructure.load();
    if (tab.id === 'tab-sre') sre.load();
    if (tab.id === 'tab-foundry' && !catalogLoaded) loadCatalog();
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activate(tab));
    tab.addEventListener('keydown', event => {
      const next = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      tabs[next].focus();
      activate(tabs[next]);
    });
  });

  function setDestination(id, value) {
    const link = byId(id);
    link.removeAttribute('href');
    link.setAttribute('aria-disabled', 'true');
    link.title = 'Destination not configured';
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:' || url.username || url.password) return false;
      link.href = url.href;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.removeAttribute('aria-disabled');
      link.title = 'Open in Azure; your account permissions apply';
      return true;
    } catch { return false; }
  }
  async function loadContext() {
    try {
      const response = await fetch('/api/agents/context', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error('Context unavailable');
      context = await response.json();
      byId('lab-resource').textContent = context.resourceGroup || 'Not configured';
      byId('lab-app').textContent = context.appService || 'Not configured';
      byId('sre-resource').textContent = context.resourceGroup || 'Not configured';
      byId('sre-app').textContent = context.appService || 'Not configured';
      byId('sre-destination-status').textContent = setDestination('sre-open', context.sreUrl) ? 'SRE Agent destination configured' : 'SRE Agent destination not configured';
      setDestination('foundry-open', context.foundryUrl);
      setDestination('observability-open', context.observabilityAgentUrl);
    } catch {
      byId('lab-resource').textContent = 'Unavailable';
      byId('lab-app').textContent = 'Unavailable';
      byId('sre-destination-status').textContent = 'Agent destinations unavailable';
    }
  }

  function updateAgentControls() {
    const running = Boolean(activeRequest || alertStorm || tokenAnomaly);
    byId('agent-send').disabled = running || refreshing || !availableAgents.length || !byId('agent-prompt').value.trim() || !byId('agent-consent').checked;
    byId('agent-cancel').disabled = !activeRequest;
    byId('agent-choice').disabled = running || refreshing || !availableAgents.length;
    byId('agent-refresh').disabled = running || refreshing;
    byId('agent-prompt').disabled = running;
    byId('agent-consent').disabled = running;
    byId('agent-clear').disabled = running;
    byId('agent-model').textContent = availableAgents.find(item => item.key === byId('agent-choice').value)?.model || 'Model unavailable';
    byId('prompt-length').textContent = `${byId('agent-prompt').value.length.toLocaleString()} / 4,000`;
    updateScenarioControls();
    updateAlertStormControls();
    updateTokenAnomalyControls();
  }
  async function loadCatalog() {
    if (refreshing || activeRequest) return;
    refreshing = true;
    catalogLoaded = true;
    updateAgentControls();
    byId('agent-availability').textContent = 'Checking agent availability...';
    byId('foundry-connection').textContent = 'Checking...';
    const previous = byId('agent-choice').value;
    try {
      const response = await fetch('/api/agents/catalog', { cache: 'no-store', signal: AbortSignal.timeout(20000) });
      byId('agent-sign-in').hidden = response.status !== 401;
      const data = await response.json();
      availableAgents = response.ok && data.available && Array.isArray(data.agents) ? data.agents : [];
      byId('foundry-connection').textContent = response.status === 401 ? 'Sign-in required' : availableAgents.length
        ? `${availableAgents.length} agent${availableAgents.length === 1 ? '' : 's'} available` : 'Unavailable';
      byId('agent-availability').textContent = data.message || 'Agent discovery failed';
      byId('agent-choice').replaceChildren(...availableAgents.map(item => new Option(item.name, item.key)));
      byId('token-anomaly-agent').replaceChildren(...availableAgents.map(item => new Option(item.name, item.key)));
      if (!availableAgents.length) byId('agent-choice').append(new Option('No agents available', ''));
      if (!availableAgents.length) byId('token-anomaly-agent').append(new Option('No agents available', ''));
      if (availableAgents.some(item => item.key === previous)) byId('agent-choice').value = previous;
    } catch {
      availableAgents = [];
      byId('foundry-connection').textContent = 'Unavailable';
      byId('agent-choice').replaceChildren(new Option('No agents available', ''));
      byId('token-anomaly-agent').replaceChildren(new Option('No agents available', ''));
      byId('agent-availability').textContent = 'Agent discovery unavailable. Retry shortly.';
    } finally { refreshing = false; updateAgentControls(); }
  }
  byId('agent-refresh').addEventListener('click', loadCatalog);
  for (const id of ['agent-choice', 'agent-prompt', 'agent-consent']) byId(id).addEventListener('input', updateAgentControls);

  function updateScenarioControls() {
    byId('agent-scenario-run').disabled = Boolean(activeRequest || alertStorm || tokenAnomaly)
      || !byId('agent-scenario-consent').checked || !byId('agent-scenario').value;
  }
  function updateAlertStormControls() {
    const running = Boolean(alertStorm);
    const count = Number(byId('alert-storm-count').value);
    const durationMinutes = Number(byId('alert-storm-duration').value);
    const safeRate = count / durationMinutes <= 5;
    byId('alert-storm-start').disabled = Boolean(activeRequest || alertStorm || tokenAnomaly)
      || !byId('alert-storm-consent').checked || !safeRate;
    byId('alert-storm-stop').disabled = !running;
    byId('alert-storm-count').disabled = running;
    byId('alert-storm-duration').disabled = running;
    byId('alert-storm-consent').disabled = running;
  }
  function updateTokenAnomalyControls() {
    const running = Boolean(tokenAnomaly);
    byId('token-anomaly-start').disabled = Boolean(activeRequest || alertStorm || tokenAnomaly)
      || !availableAgents.length || !byId('token-anomaly-agent').value || !byId('token-anomaly-consent').checked;
    byId('token-anomaly-stop').disabled = !running;
    byId('token-anomaly-agent').disabled = running || refreshing || !availableAgents.length;
    byId('token-anomaly-count').disabled = running;
    byId('token-anomaly-consent').disabled = running;
  }
  async function loadScenarioCatalog() {
    try {
      const response = await fetch('/api/agents/scenarios', { cache: 'no-store', referrerPolicy: 'same-origin' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const select = byId('agent-scenario');
      select.replaceChildren();
      const scenarios = Array.isArray(data) ? data : data.scenarios || [];
      for (const scenario of scenarios) {
        const option = document.createElement('option');
        option.value = scenario.key;
        option.textContent = scenario.name;
        select.append(option);
      }
      if (!select.value) throw new Error('No scenarios are available');
      updateScenarioControls();
    } catch (error) {
      byId('agent-scenario').replaceChildren();
      byId('agent-scenario-status').textContent = `Scenario catalog unavailable: ${error.message || 'request failed'}`;
      updateScenarioControls();
    }
  }
  byId('agent-scenario-consent').addEventListener('input', updateScenarioControls);
  byId('agent-scenario-copy').addEventListener('click', async () => {
    const prompt = byId('agent-scenario-prompt').value;
    try {
      await navigator.clipboard.writeText(prompt);
      toast('Observability Agent prompt copied');
    } catch {
      toast('Clipboard unavailable. Select the prompt to copy it.');
    }
  });
  byId('agent-scenario-form').addEventListener('submit', async event => {
    event.preventDefault();
    const button = byId('agent-scenario-run');
    button.disabled = true;
    byId('agent-scenario-status').textContent = 'Generating deterministic agent telemetry...';
    const payload = {
      scenario: byId('agent-scenario').value,
      mode: byId('agent-scenario-mode').value,
      consent: byId('agent-scenario-consent').checked
    };
    try {
      const response = await fetch('/api/agents/scenarios/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
        referrerPolicy: 'same-origin',
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10000)
      });
      const data = await response.json();
      if (!response.ok && !data.status) throw new Error(data.error || `HTTP ${response.status}`);
      const trace = data.traceId || 'unavailable';
      byId('agent-scenario-status').textContent = `${data.scenario} / ${data.mode}: ${data.status}; ${Math.round(data.durationMs).toLocaleString()} ms; selected ${data.selectedTool}; trace ${trace}`;
      if (typeof data.investigationPrompt === 'string' && data.investigationPrompt.trim()) {
        byId('agent-scenario-prompt').value = data.investigationPrompt;
        byId('agent-scenario-investigation').hidden = false;
      } else {
        byId('agent-scenario-prompt').value = '';
        byId('agent-scenario-investigation').hidden = true;
      }
    } catch (error) {
      byId('agent-scenario-status').textContent = `Scenario failed: ${error.message || 'request unavailable'}`;
      byId('agent-scenario-prompt').value = '';
      byId('agent-scenario-investigation').hidden = true;
    } finally {
      byId('agent-scenario-consent').checked = false;
      updateScenarioControls();
    }
  });

  function waitForBatch(delayMs, batch) {
    return new Promise(resolve => {
      const timer = setTimeout(resolve, delayMs);
      batch.wake = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }

  for (const id of ['alert-storm-count', 'alert-storm-duration', 'alert-storm-consent']) {
    byId(id).addEventListener('input', () => {
      const count = Number(byId('alert-storm-count').value);
      byId('alert-storm-progress').max = count;
      byId('alert-storm-progress').value = 0;
      byId('alert-storm-counter').textContent = `0 / ${count}`;
      byId('alert-storm-status').textContent = count / Number(byId('alert-storm-duration').value) <= 5
        ? 'Ready' : 'Choose a longer duration to stay within the request safety limit.';
      updateAlertStormControls();
    });
  }
  byId('alert-storm-start').addEventListener('click', async () => {
    if (activeRequest || alertStorm || tokenAnomaly) return;
    const count = Math.min(24, Math.max(1, Number(byId('alert-storm-count').value) || 18));
    const durationMs = Math.max(180000, Number(byId('alert-storm-duration').value) * 60000);
    if (count / (durationMs / 60000) > 5) {
      byId('alert-storm-status').textContent = 'Choose a longer duration to stay within the request safety limit.';
      return;
    }
    alertStorm = { stopped: false, completed: 0, failed: 0, slow: 0, wake: null, controller: new AbortController() };
    const batch = alertStorm;
    const intervalMs = count > 1 ? durationMs / (count - 1) : 0;
    const pattern = ['slow-tool', 'partial-failure', 'partial-failure'];
    byId('alert-storm-progress').max = count;
    byId('alert-storm-progress').value = 0;
    byId('alert-storm-status').textContent = 'Generating mixed broken traces...';
    byId('alert-storm-counter').textContent = `0 / ${count}`;
    updateAgentControls();
    try {
      for (let index = 0; index < count && !batch.stopped; index++) {
        const started = performance.now();
        const scenario = pattern[index % pattern.length];
        const response = await fetch('/api/agents/scenarios/run', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
          referrerPolicy: 'same-origin',
          body: JSON.stringify({ scenario, mode: 'broken', consent: true }),
          signal: AbortSignal.any([batch.controller.signal, AbortSignal.timeout(10000)])
        });
        const data = await response.json().catch(() => null);
        if (!data?.status || (!response.ok && response.status !== 502)) {
          const retry = response.headers.get('Retry-After');
          throw new Error(retry ? `HTTP ${response.status}; retry after ${retry} seconds` : `HTTP ${response.status}`);
        }
        batch.completed++;
        if (response.status === 502) batch.failed++;
        if (scenario === 'slow-tool') batch.slow++;
        byId('alert-storm-progress').value = batch.completed;
        byId('alert-storm-counter').textContent = `${batch.completed} / ${count}`;
        byId('alert-storm-status').textContent = `Running: ${batch.slow} slow, ${batch.failed} failed`;
        if (batch.stopped || batch.completed === count) break;
        await waitForBatch(Math.max(0, intervalMs - (performance.now() - started)), batch);
        batch.wake = null;
      }
      byId('alert-storm-status').textContent = batch.stopped
        ? `Stopped after ${batch.completed}: ${batch.slow} slow, ${batch.failed} failed`
        : `Completed ${batch.completed}: ${batch.slow} slow, ${batch.failed} failed`;
    } catch (error) {
      byId('alert-storm-status').textContent = batch.stopped || error.name === 'AbortError'
        ? `Stopped after ${batch.completed}: ${batch.slow} slow, ${batch.failed} failed`
        : `Stopped after ${batch.completed}; ${error.message || 'request failed'}. No request was replayed.`;
    } finally {
      byId('alert-storm-consent').checked = false;
      alertStorm = null;
      updateAgentControls();
    }
  });
  byId('alert-storm-stop').addEventListener('click', () => {
    if (!alertStorm) return;
    alertStorm.stopped = true;
    alertStorm.controller.abort();
    alertStorm.wake?.();
    byId('alert-storm-status').textContent = 'Stopping...';
  });

  function tokenAnomalyPrompt(batchId, callNumber) {
    const context = [
      'Synthetic retail support policy: orders can be returned within 30 days when unused.',
      'Synthetic operations policy: escalate suspected fraud and never request secrets.',
      'Synthetic FinOps policy: state assumptions, quantify token use, and recommend bounded guardrails.',
      'Synthetic service context: customer, inventory, order, payment, shipping, and notification systems are independent.',
      'Synthetic reliability context: retries require idempotency and latency budgets apply to every dependency.'
    ].join(' ');
    const uniquePrefix = `Token anomaly demonstration ${batchId}, call ${callNumber}. `;
    const body = `${uniquePrefix}${context}\n`.repeat(18);
    return `${body.slice(0, 3650)}\nUsing only this synthetic context, return exactly three concise bullets: the likely cost risk, one monitoring check, and one guardrail.`;
  }

  function tokenAnomalyCostSummary(batch) {
    if (batch.unpricedCalls > 0) {
      return batch.pricedCalls > 0
        ? `partial estimate $${batch.cost.toFixed(6)}; pricing unavailable for ${batch.unpricedCalls} call${batch.unpricedCalls === 1 ? '' : 's'}`
        : 'cost unavailable; model pricing is not configured';
    }
    return `estimated $${batch.cost.toFixed(6)}`;
  }

  for (const id of ['token-anomaly-agent', 'token-anomaly-count', 'token-anomaly-consent']) {
    byId(id).addEventListener('input', () => {
      const count = Number(byId('token-anomaly-count').value);
      byId('token-anomaly-progress').max = count;
      byId('token-anomaly-progress').value = 0;
      byId('token-anomaly-counter').textContent = `0 / ${count}`;
      updateTokenAnomalyControls();
    });
  }
  byId('token-anomaly-start').addEventListener('click', async () => {
    if (activeRequest || alertStorm || tokenAnomaly || !availableAgents.length) return;
    const count = Math.min(10, Math.max(1, Number(byId('token-anomaly-count').value) || 5));
    const batchId = crypto.randomUUID();
    tokenAnomaly = {
      stopped: false, completed: 0, inputTokens: 0, outputTokens: 0, cost: 0,
      pricedCalls: 0, unpricedCalls: 0, batchId, controller: new AbortController()
    };
    const batch = tokenAnomaly;
    byId('token-anomaly-progress').max = count;
    byId('token-anomaly-progress').value = 0;
    byId('token-anomaly-counter').textContent = `0 / ${count}`;
    byId('token-anomaly-status').textContent = 'Submitting billable Foundry calls...';
    updateAgentControls();
    try {
      for (let index = 0; index < count && !batch.stopped; index++) {
        const response = await fetch('/api/agents/run', {
          method: 'POST',
          cache: 'no-store',
          referrerPolicy: 'same-origin',
          headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
          body: JSON.stringify({
            agent: byId('token-anomaly-agent').value,
            prompt: tokenAnomalyPrompt(batchId, index + 1),
            consent: true,
            scenario: 'token-anomaly',
            batchId
          }),
          signal: AbortSignal.any([batch.controller.signal, AbortSignal.timeout(115000)])
        });
        const data = await response.json().catch(() => null);
        batch.inputTokens += Number(data?.inputTokens) || 0;
        batch.outputTokens += Number(data?.outputTokens) || 0;
        if (typeof data?.estimatedCostUsd === 'number' && Number.isFinite(data.estimatedCostUsd)) {
          batch.cost += data.estimatedCostUsd;
          batch.pricedCalls++;
        } else {
          batch.unpricedCalls++;
        }
        if (!response.ok || typeof data?.agent !== 'string') {
          const retry = response.headers.get('Retry-After');
          const message = typeof data?.error === 'string' ? data.error : `HTTP ${response.status}`;
          throw new Error(`${message}${retry ? ` Retry after ${retry} seconds.` : ''}`);
        }
        batch.completed++;
        byId('token-anomaly-progress').value = batch.completed;
        byId('token-anomaly-counter').textContent = `${batch.completed} / ${count}`;
        byId('token-anomaly-status').textContent = `Running: ${(batch.inputTokens + batch.outputTokens).toLocaleString()} tokens; ${tokenAnomalyCostSummary(batch)}`;
      }
      byId('token-anomaly-status').textContent = `${batch.stopped ? 'Stopped' : 'Completed'} ${batch.completed} calls; ${batch.inputTokens.toLocaleString()} input + ${batch.outputTokens.toLocaleString()} output tokens; ${tokenAnomalyCostSummary(batch)}; batch ${batch.batchId}`;
    } catch (error) {
      byId('token-anomaly-status').textContent = batch.stopped || error.name === 'AbortError'
        ? `Stopped after ${batch.completed} completed calls; ${(batch.inputTokens + batch.outputTokens).toLocaleString()} reported tokens may still be billed.`
        : `Stopped after ${batch.completed} completed calls; ${(batch.inputTokens + batch.outputTokens).toLocaleString()} reported tokens; ${error.message || 'request failed'}. No billable call was replayed.`;
    } finally {
      byId('token-anomaly-consent').checked = false;
      tokenAnomaly = null;
      updateAgentControls();
    }
  });
  byId('token-anomaly-stop').addEventListener('click', () => {
    if (!tokenAnomaly) return;
    tokenAnomaly.stopped = true;
    tokenAnomaly.controller.abort();
    byId('token-anomaly-status').textContent = 'Stopping after the current Foundry cancellation request...';
  });

  function element(tag, text, className) {
    const item = document.createElement(tag);
    item.textContent = text;
    if (className) item.className = className;
    return item;
  }
  function showAnswer(data, prompt, traceId) {
    const result = element('article', '', 'agent-result');
    result.append(element('h3', data.agent), element('p', prompt, 'submitted-task'), element('div', data.text || 'No text response was returned.', 'agent-answer'));
    const metadata = element('dl', '', 'agent-metadata');
    for (const [label, value] of [
      ['Model', data.model || 'Unavailable'], ['Latency', `${Math.round(data.durationMs).toLocaleString()} ms`],
      ['Input tokens', data.inputTokens?.toLocaleString() ?? 'Not reported'],
      ['Output tokens', data.outputTokens?.toLocaleString() ?? 'Not reported'],
      ['Estimated USD', data.estimatedCostUsd == null ? 'Rates not configured' : `$${Number(data.estimatedCostUsd).toFixed(6)}`],
      ['Run ID', data.runId || 'Unavailable'], ['Trace ID', traceId || 'Unavailable']
    ]) metadata.append(element('dt', label), element('dd', value));
    result.append(metadata);
    if (traceId) {
      const copy = element('button', '', 'icon-button');
      copy.title = 'Copy agent trace ID';
      copy.setAttribute('aria-label', copy.title);
      const icon = document.createElement('i');
      icon.dataset.lucide = 'copy';
      copy.append(icon);
      copy.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(traceId); toast('Agent trace ID copied'); }
        catch { toast('Clipboard unavailable. Select the trace ID to copy it.'); }
      });
      result.append(copy);
    }
    byId('agent-results').prepend(result);
    while (byId('agent-results').children.length > 10) byId('agent-results').lastElementChild.remove();
    refreshIcons();
  }
  byId('agent-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (byId('agent-send').disabled) return;
    const prompt = byId('agent-prompt').value.trim();
    activeRequest = new AbortController();
    updateAgentControls();
    const started = performance.now();
    const ticker = setInterval(() => { byId('agent-status').textContent = `Agent task running / ${Math.floor((performance.now() - started) / 1000)} s`; }, 500);
    byId('agent-status').textContent = 'Submitting agent task...';
    try {
      const response = await fetch('/api/agents/run', {
        method: 'POST', cache: 'no-store', referrerPolicy: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
        body: JSON.stringify({ agent: byId('agent-choice').value, prompt, consent: true }),
        signal: AbortSignal.any([activeRequest.signal, AbortSignal.timeout(115000)])
      });
      const traceId = response.headers.get('X-Amlab-Trace-Id') || '';
      const data = await response.json().catch(error => {
        if (error instanceof SyntaxError) return null;
        throw error;
      });
      byId('agent-sign-in').hidden = response.status !== 401 && response.status !== 403;
      if (!response.ok) {
        const retry = response.headers.get('Retry-After');
        const message = typeof data?.error === 'string' ? data.error : response.status === 401
          ? 'Sign in with an approved lab operator account before submitting again.' : response.status === 403
          ? 'App Service or the application rejected the request. Check sign-in and same-origin access.'
          : 'The app returned an unexpected response. Check the server trace before retrying.';
        byId('agent-status').textContent = `HTTP ${response.status}: ${message}${retry ? ` Retry after ${retry} seconds.` : ''}${traceId ? ` Trace: ${traceId}` : ''}`;
        return;
      }
      if (typeof data?.agent !== 'string' || typeof data?.text !== 'string') {
        byId('agent-status').textContent = `The app returned an invalid agent response (HTTP ${response.status}). Check sign-in and the server trace before retrying.${traceId ? ` Trace: ${traceId}` : ''}`;
        return;
      }
      showAnswer(data, prompt, data.traceId || traceId);
      byId('agent-status').textContent = `Completed / ${new Date().toISOString()}`;
    } catch (error) {
      byId('agent-status').textContent = error.name === 'AbortError' || error.name === 'TimeoutError'
        ? 'Stopped waiting. Server cancellation and cleanup are best-effort; incurred usage may still be billed.'
        : 'The app could not return a result. Check connectivity and the server trace before retrying.';
    } finally {
      clearInterval(ticker);
      activeRequest = null;
      byId('agent-consent').checked = false;
      updateAgentControls();
    }
  });
  byId('agent-cancel').addEventListener('click', () => activeRequest?.abort());
  byId('agent-clear').addEventListener('click', () => {
    byId('agent-results').replaceChildren();
    byId('agent-status').textContent = 'No tasks submitted';
    byId('agent-prompt').value = '';
    byId('agent-consent').checked = false;
    updateAgentControls();
  });
  activate(tabs[0]);
  loadScenarioCatalog();
  loadContext();
}