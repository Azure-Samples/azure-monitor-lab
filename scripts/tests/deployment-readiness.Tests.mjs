import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const readJson = (relative) => JSON.parse(readFileSync(new URL(`../../${relative}`, import.meta.url), 'utf8'));
const deploymentId = (name) => `[resourceId('Microsoft.Resources/deployments', '${name}')]`;
const moduleByName = (template, name) => {
  const matches = template.resources.filter((resource) => resource.name === name);
  assert.equal(matches.length, 1, `Expected one ${name} module`);
  assert.equal(matches[0].type, 'Microsoft.Resources/deployments');
  return matches[0];
};
const retry = (resource, code) => assert.deepEqual(resource['@options'], { retryOn: [[code], 30] });

for (const path of ['infra/main.json', 'infra/stages/40-optional-advanced.json']) {
  test(`${path}: export retries the actual workspace activation error without extra resources`, () => {
    const parent = readJson(path);
    const module = moduleByName(parent, 'data-export');
    const template = module.properties.template;
    assert.equal(template.languageVersion, '2.0');
    assert.deepEqual(Object.keys(template.resources).sort(), ['exportRule', 'law']);
    assert.equal(template.resources.law.existing, true);
    assert.equal(template.resources.law.type, 'Microsoft.OperationalInsights/workspaces');
    const rule = template.resources.exportRule;
    retry(rule, 'ResourceNotFound');
    assert.equal(rule.type, 'Microsoft.OperationalInsights/workspaces/dataExports');
    assert.equal(rule.properties.enable, true);
    assert.equal(rule.properties.destination.resourceId, "[parameters('storageAccountId')]");
    assert.equal(rule.properties.tableNames, "[parameters('tables')]");
    assert.deepEqual(template.parameters.tables.defaultValue, ['Heartbeat']);
    assert.equal(module.condition, undefined);
    if (path === 'infra/main.json') {
      assert.deepEqual(module.dependsOn.toSorted(), [deploymentId('law-central'), deploymentId('storage-account')].toSorted());
    }
  });
}

for (const path of ['infra/main.json', 'infra/stages/00-foundation.json']) {
  test(`${path}: classic DCR waits for the workspace and bounds retries to its returned outer error`, () => {
    const parent = readJson(path);
    const module = moduleByName(parent, 'vm-insights-dcr');
    assert.equal(module.condition, undefined);
    assert.equal(module.properties.parameters.name.value, "[variables('dcrVmInsightsName')]");
    assert.equal(parent.variables.dcrVmInsightsName, "[format('dcr-{0}-vminsights', parameters('namePrefix'))]");
    assert.deepEqual(module.dependsOn, [deploymentId('law-central')]);
    assert.equal(module.properties.parameters.centralLawId.value,
      "[reference(resourceId('Microsoft.Resources/deployments', 'law-central'), '2025-04-01').outputs.id.value]");
    const template = module.properties.template;
    assert.equal(template.languageVersion, '2.0');
    assert.deepEqual(Object.keys(template.resources), ['dcr']);
    const dcr = template.resources.dcr;
    retry(dcr, 'InvalidPayload');
    assert.equal(dcr.type, 'Microsoft.Insights/dataCollectionRules');
    assert.equal(dcr.apiVersion, '2023-03-11');
    assert.equal(dcr.name, "[parameters('name')]");
    assert.equal(dcr.location, "[parameters('location')]");
    assert.equal(dcr.tags, "[parameters('tags')]");
    assert.equal(dcr.kind, 'Linux');
    assert.equal(dcr.condition, undefined);
    assert.deepEqual(dcr.properties, {
      dataSources: {
        performanceCounters: [{
          name: 'VMInsightsPerfCounters',
          streams: ['Microsoft-InsightsMetrics'],
          samplingFrequencyInSeconds: 60,
          counterSpecifiers: ['\\VmInsights\\DetailedMetrics'],
        }],
        extensions: [{
          name: 'DependencyAgentDataSource',
          streams: ['Microsoft-ServiceMap'],
          extensionName: 'DependencyAgent',
        }],
      },
      destinations: {
        logAnalytics: [{ workspaceResourceId: "[parameters('centralLawId')]", name: 'centralLaw' }],
      },
      dataFlows: [
        { streams: ['Microsoft-InsightsMetrics'], destinations: ['centralLaw'] },
        { streams: ['Microsoft-ServiceMap'], destinations: ['centralLaw'] },
      ],
    });
    assert.equal(template.outputs.id.type, 'string');
    assert.equal(template.outputs.id.value, "[resourceId('Microsoft.Insights/dataCollectionRules', parameters('name'))]");
  });
}

test('one-shot VMs wait for the retried classic DCR and retain the same associations', () => {
  const parent = readJson('infra/main.json');
  for (const os of ['linux', 'windows']) {
    const vm = moduleByName(parent, `vm-${os}`);
    assert.ok(vm.dependsOn.includes(deploymentId('vm-insights-dcr')));
    assert.equal(vm.properties.parameters.dcrId.value,
      "[reference(resourceId('Microsoft.Resources/deployments', 'vm-insights-dcr'), '2025-04-01').outputs.id.value]");
    const association = vm.properties.template.resources.find((resource) => resource.name === 'vminsights-association');
    assert.equal(association.properties.dataCollectionRuleId, "[parameters('dcrId')]");
    assert.equal(association.condition, undefined);
  }
});

const ui = readJson('infra/createUiDefinition.json');
const stages = ui.parameters.steps.find((step) => step.name === 'stages').elements;
const quota = stages.find((element) => element.name === 'observabilityAgentQuota');
const inventory = stages.find((element) => element.name === 'observabilityAgentInventory');
const subscriptionId = '/subscriptions/11111111-1111-1111-1111-111111111111';

// Evaluate the checked-in expressions with the documented CreateUiDefinition functions.
function evaluate(expression, enabled, response, statusText = '') {
  return runInNewContext(expression.slice(1, -1).replace(/\bif\(/g, 'choose('), {
    choose: (condition, whenTrue, whenFalse) => condition ? whenTrue : whenFalse,
    and: (...values) => values.every(Boolean),
    equals: (left, right) => left === right,
    less: (left, right) => left < right,
    string: (value) => typeof value === 'string' ? value : JSON.stringify(value),
    coalesce: (...values) => values.find((value) => value !== null && value !== undefined),
    empty: (value) => typeof value === 'string' || Array.isArray(value) ? value.length === 0 : Object.keys(value).length === 0,
    parse: JSON.parse,
    length: (value) => Array.isArray(value) || typeof value === 'string' ? value.length : Object.keys(value).length,
    take: (value, count) => typeof value === 'string' || Array.isArray(value)
      ? value.slice(0, count) : Object.fromEntries(Object.entries(value).slice(0, count)),
    concat: (...values) => values.join(''),
    subscription: () => ({ id: subscriptionId }),
    steps: (name) => {
      assert.equal(name, 'stages');
      return {
        enableObservabilityAgent: enabled,
        observabilityAgentInventory: response ?? {},
        observabilityAgentQuota: statusText,
      };
    },
  }, { timeout: 1000 });
}

const agents = (count, nextLink = null) => ({
  value: Array.from({ length: count }, (_, index) => ({ id: `${subscriptionId}/resourceGroups/test-${index}/providers/Microsoft.Monitor/observabilityAgents/agent-${index}` })),
  nextLink,
});
const valid = (enabled, response, statusText) =>
  quota.constraints.validations.every((validation) => evaluate(validation.isValid, enabled, response, statusText) === true);

test('portal inventory is a subscription-wide read, leaves feature selection explicit, and adds no ARM parameter', () => {
  assert.equal(inventory.type, 'Microsoft.Solutions.ArmApiControl');
  assert.equal(inventory.request.method, 'GET');
  assert.equal(evaluate(inventory.request.path), `${subscriptionId}/providers/Microsoft.Monitor/observabilityAgents?api-version=2026-05-01-preview`);
  assert.equal(stages.find((element) => element.name === 'enableObservabilityAgent').defaultValue, false);
  assert.equal(ui.parameters.outputs.enableObservabilityAgent, "[steps('stages').enableObservabilityAgent]");
  assert.equal(ui.parameters.outputs.observabilityAgentQuota, undefined);
  assert.equal(quota.type, 'Microsoft.Common.TextBox');
  assert.equal(quota.constraints.required, true);
  assert.equal(quota.constraints.validations.length, 2);
  assert.equal(evaluate(quota.visible, true, agents(0)), true);
  assert.equal(evaluate(quota.visible, false, agents(5)), false);
});

for (const count of [0, 4, 5, 6]) {
  test(`portal quota: ${count} agents ${count < 5 ? 'allows' : 'blocks'} an enabled stage`, () => {
    assert.equal(valid(true, agents(count)), count < 5);
    assert.equal(evaluate(quota.defaultValue, true, agents(count)), `${count} / 5 agents in subscription`);
  });
}

test('portal conservatively blocks even same-resource-group updates at five, as documented', () => {
  const response = agents(5);
  response.value[0].id = `${subscriptionId}/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.Monitor/observabilityAgents/obs-amlab-existing`;
  assert.equal(valid(true, response), false);
  assert.match(quota.constraints.validations[1].message, /also blocks updates at the limit/);
});

for (const [name, response] of [
  ['pending', undefined],
  ['empty response', {}],
  ['unauthorized', { error: { code: 'AuthorizationFailed' } }],
  ['provider unregistered', { error: { code: 'MissingSubscriptionRegistration' } }],
  ['error with partial values', { ...agents(0), error: { code: 'InternalServerError' } }],
  ['missing value', { value: null }],
  ['invalid object', { value: {} }],
  ['invalid string', { value: '[]' }],
  ['partial page', agents(4, 'https://management.azure.com/next-page')],
]) {
  test(`portal quota fails closed for ${name} without displaying zero spare usage`, () => {
    assert.equal(valid(true, response), false);
    assert.equal(evaluate(quota.defaultValue, true, response), 'Subscription inventory unavailable or incomplete');
  });
}

test('disabled agent stage does not block the rest of the lab, even when inventory fails or quota is full', () => {
  for (const response of [undefined, {}, { error: { code: 'AuthorizationFailed' } }, agents(0), agents(5), agents(6), agents(4, 'next-page')]) {
    assert.equal(valid(false, response), true);
  }
});

test('editing quota status cannot bypass API-based validation', () => {
  assert.equal(valid(true, agents(5), '0 / 5 agents in subscription'), false);
  assert.equal(valid(true, { error: { code: 'AuthorizationFailed' } }, '0 / 5 agents in subscription'), false);
});
