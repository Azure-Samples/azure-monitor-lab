// =============================================================================
// hm-amlab-flows: the lab's user-flow health model.
//
// Plan: docs/healthmodel/lab/plan.md, modelspec: docs/healthmodel/lab/modelspec.md.
// Deployed by scripts/deploy-lab-healthmodel.ps1 next to the resource-tier demo
// model hm-amlab-workload (scenario 45), which stays unchanged.
//
//   hm-amlab-flows (root)
//   ├─ Operate the lab                -> Control Center, Lab operations (limited, no resource
//   │                                    entity: Container Apps jobs emit metrics only while running)
//   ├─ Show the shop app live         -> Shop API, Test shoppers
//   └─ Show live infrastructure data  -> Log pipeline, Metrics pipeline,
//                                        Kubernetes workloads, Virtual machines (limited)
//
// Chaos routes (/api/explode, /api/slow, /api/inefficient, ...) fail on purpose,
// so no signal counts them.
// =============================================================================

@minLength(3)
@maxLength(44)
param healthModelName string = 'hm-amlab-flows'

@description('Region for the health model: az provider show -n Microsoft.CloudHealth lists them.')
param location string = resourceGroup().location

param webAppId string
param appInsightsWorkspaceId string
param centralWorkspaceId string
param monitorWorkspaceId string
param aksId string
param vmssId string

@description('Resource IDs of the demo VMs that send heartbeats (Linux and Windows, when deployed).')
param vmIds array

@description('Action group notified by the user flow alerts.')
param actionGroupId string

param tags object = {}

var actionGroupIds = [actionGroupId]
var auth = 'system-assigned'

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-11-01' = {
  name: healthModelName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// The model reads with its own identity: Monitoring Reader covers metrics and Log Analytics,
// Monitoring Data Reader is needed for PromQL on the Azure Monitor workspace.
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var monitoringDataReaderRoleId = 'b0d8363b-8ddd-447d-831f-62ca05bff136'

resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: last(split(monitorWorkspaceId, '/'))
}

resource monitoringDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitorWorkspace.id, healthModel.id, monitoringDataReaderRoleId)
  scope: monitorWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringDataReaderRoleId)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-11-01' = {
  parent: healthModel
  name: auth
  properties: {
    displayName: 'System-assigned managed identity'
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
  dependsOn: [
    monitoringReader
    monitoringDataReader
  ]
}

// -----------------------------------------------------------------------------
// Reusable signals (each used by more than one entity)
// -----------------------------------------------------------------------------
func rules(operator string, degraded int, unhealthy int) object => {
  degradedRule: { operator: operator, threshold: degraded }
  unhealthyRule: { operator: operator, threshold: unhealthy }
}

var metricDefinitions = [
  {
    name: 'sd-app-health-check'
    displayName: 'Web app health check'
    metricNamespace: 'Microsoft.Web/sites'
    metricName: 'HealthCheckStatus'
    aggregationType: 'Average'
    dataUnit: 'Percent'
    evaluationRules: rules('LessThan', 100, 50)
  }
  {
    name: 'sd-node-cpu'
    displayName: 'Cluster node CPU'
    metricNamespace: 'Microsoft.ContainerService/managedClusters'
    metricName: 'node_cpu_usage_percentage'
    aggregationType: 'Average'
    dataUnit: 'Percent'
    evaluationRules: rules('GreaterThan', 80, 95)
  }
  {
    name: 'sd-node-memory'
    displayName: 'Cluster node memory'
    metricNamespace: 'Microsoft.ContainerService/managedClusters'
    metricName: 'node_memory_working_set_percentage'
    aggregationType: 'Average'
    dataUnit: 'Percent'
    evaluationRules: rules('GreaterThan', 80, 95)
  }
  {
    name: 'sd-vm-cpu'
    displayName: 'VM CPU'
    metricNamespace: 'Microsoft.Compute/virtualMachines'
    metricName: 'Percentage CPU'
    aggregationType: 'Average'
    dataUnit: 'Percent'
    evaluationRules: rules('GreaterThan', 80, 95)
  }
]

resource signalDefinitions 'Microsoft.CloudHealth/healthmodels/signaldefinitions@2026-11-01' = [
  for d in metricDefinitions: {
    parent: healthModel
    name: d.name
    properties: {
      signalKind: 'AzureResourceMetric'
      displayName: d.displayName
      metricNamespace: d.metricNamespace
      metricName: d.metricName
      aggregationType: d.aggregationType
      timeGrain: 'PT5M'
      refreshInterval: 'PT1M'
      dataUnit: d.dataUnit
      evaluationRules: d.evaluationRules
    }
  }
]

// -----------------------------------------------------------------------------
// Signal builders
// -----------------------------------------------------------------------------
func logSignal(name string, displayName string, query string, window string, unit string, evaluationRules object) object => {
  name: name
  signalKind: 'LogAnalyticsQuery'
  displayName: displayName
  queryText: query
  valueColumnName: 'value'
  timeGrain: window
  refreshInterval: 'PT1M'
  dataUnit: unit
  evaluationRules: evaluationRules
}

func promSignal(name string, displayName string, query string, unit string, evaluationRules object) object => {
  name: name
  signalKind: 'PrometheusMetricsQuery'
  displayName: displayName
  queryText: query
  timeGrain: 'PT5M'
  refreshInterval: 'PT1M'
  dataUnit: unit
  evaluationRules: evaluationRules
}

func metricSignal(name string, displayName string, namespace string, metric string, aggregation string, unit string, evaluationRules object) object => {
  name: name
  signalKind: 'AzureResourceMetric'
  displayName: displayName
  metricNamespace: namespace
  metricName: metric
  aggregationType: aggregation
  timeGrain: 'PT5M'
  refreshInterval: 'PT1M'
  dataUnit: unit
  evaluationRules: evaluationRules
}

func definitionSignals(names array) array => map(names, n => {
  name: substring(n, 3)
  signalKind: 'AzureResourceMetric'
  signalDefinitionName: n
})

func lawGroup(workspaceId string, signals array) object => {
  azureLogAnalytics: {
    authenticationSetting: 'system-assigned'
    logAnalyticsWorkspaceResourceId: workspaceId
    signals: signals
  }
}

func resourceGroupOf(resourceId string, signals array) object => {
  azureResource: {
    authenticationSetting: 'system-assigned'
    azureResourceId: resourceId
    signals: signals
  }
}

// Console routes from workloads/webapp/Program.cs. The root URL has an empty path and the
// static UI is logged as /index.html.
var consolePathFilter = 'path in ("", "/", "/index.html", "/healthz", "/api/console/config", "/api/console/version", "/api/infra/health") or path startswith "/api/operations/"'
var webAppName = last(split(webAppId, '/'))
var aksName = last(split(aksId, '/'))

// -----------------------------------------------------------------------------
// Entities: user flows, system components, Azure resources
// -----------------------------------------------------------------------------
var entities = [
  // Layer 1: user flows
  {
    name: 'operate-lab'
    displayName: 'Operate the lab'
    icon: 'UserFlow'
    healthObjective: json('99.5')
    alerts: {
      unhealthy: { severity: 'Sev2', description: 'Presenters cannot use the Lab Control Center', actionGroupIds: actionGroupIds }
    }
  }
  {
    name: 'shop-demo'
    displayName: 'Show the shop app live'
    icon: 'UserFlow'
    healthObjective: json('99.5')
    alerts: {
      degraded: { severity: 'Sev3', description: 'The shop demo is losing checkouts or traffic', actionGroupIds: actionGroupIds }
      unhealthy: { severity: 'Sev2', description: 'The shop demo shows no live checkouts', actionGroupIds: actionGroupIds }
    }
  }
  {
    name: 'live-telemetry'
    displayName: 'Show live infrastructure data'
    icon: 'UserFlow'
    healthObjective: json('99')
    alerts: {
      unhealthy: { severity: 'Sev2', description: 'Dashboards and queries show stale or broken lab data', actionGroupIds: actionGroupIds }
    }
  }

  // Layer 2: system components
  {
    name: 'control-center'
    displayName: 'Control Center'
    icon: 'SystemComponent'
    signalGroups: lawGroup(appInsightsWorkspaceId, [
      logSignal('failed-console-requests', 'Failed console requests', $'''
AppRequests
| extend path = tostring(parse_url(Url).Path)
| where ${consolePathFilter}
| summarize value = countif(ResultCode startswith "5")
''', 'PT5M', 'Count', rules('GreaterThan', 0, 5))
      logSignal('console-availability-failures', 'Test visitor cannot load the console', '''
AppAvailabilityResults
| where Name == "avail-amlab-appservice"
| summarize value = countif(Success == false)
''', 'PT15M', 'Count', rules('GreaterThan', 0, 4))
    ])
  }
  {
    name: 'lab-operations'
    displayName: 'Lab operations (optional)'
    icon: 'SystemComponent'
    impact: 'Limited'
    signalGroups: lawGroup(appInsightsWorkspaceId, [
      logSignal('failed-operation-requests', 'Failed lab operation requests', '''
AppRequests
| where tostring(parse_url(Url).Path) startswith "/api/operations/"
| summarize value = countif(ResultCode startswith "5")
''', 'PT15M', 'Count', rules('GreaterThan', 0, 2))
    ])
  }
  {
    name: 'shop-api'
    displayName: 'Shop API'
    icon: 'SystemComponent'
    signalGroups: lawGroup(appInsightsWorkspaceId, [
      // 402 is a declined payment, a business outcome, not a failure.
      logSignal('failed-checkouts', 'Checkouts failing with server errors', '''
AppRequests
| where tostring(parse_url(Url).Path) == "/api/checkout"
| summarize value = countif(ResultCode startswith "5")
''', 'PT5M', 'Count', rules('GreaterThan', 0, 2))
      logSignal('completed-checkouts', 'Completed checkouts', '''
AppEvents
| where Name == "CheckoutCompleted"
| summarize value = count()
''', 'PT15M', 'Count', rules('LessThan', 5, 1))
    ])
  }
  {
    name: 'synthetic-shoppers'
    displayName: 'Test shoppers'
    icon: 'SystemComponent'
    signalGroups: {
      azureMonitorWorkspace: {
        authenticationSetting: auth
        azureMonitorWorkspaceResourceId: monitorWorkspaceId
        signals: [
          promSignal('shopper-replicas-available', 'Test shopper apps running', 'sum(kube_deployment_status_replicas_available{namespace="demo", deployment=~"otel-caller|nodeapp-otel"}) or vector(0)', 'Count', rules('LessThan', 2, 1))
        ]
      }
    }
  }
  {
    name: 'log-pipeline'
    displayName: 'Log pipeline'
    icon: 'SystemComponent'
    signalGroups: lawGroup(centralWorkspaceId, [
      logSignal('log-freshness', 'Minutes since the newest log record', '''
union isfuzzy=true KubeNodeInventory, AppServiceHTTPLogs
| summarize newest = max(TimeGenerated)
| project value = coalesce(datetime_diff('minute', now(), newest), 30)
''', 'PT30M', 'Count', rules('GreaterThan', 10, 20))
    ])
  }
  {
    name: 'metrics-pipeline'
    displayName: 'Metrics pipeline'
    icon: 'SystemComponent'
    signalGroups: {
      azureMonitorWorkspace: {
        authenticationSetting: auth
        azureMonitorWorkspaceResourceId: monitorWorkspaceId
        signals: [
          promSignal('scrape-targets-up', 'Metric sources answering', '(sum(up) / count(up) * 100) or vector(0)', 'Percent', rules('LessThan', 100, 90))
        ]
      }
    }
  }
  {
    name: 'kubernetes-workloads'
    displayName: 'Kubernetes workloads'
    icon: 'SystemComponent'
    signalGroups: lawGroup(centralWorkspaceId, [
      logSignal('crashlooping-containers', 'Containers crash-looping in the demo namespace', '''
KubePodInventory
| where Namespace == "demo" and ContainerStatusReason == "CrashLoopBackOff"
| summarize value = dcount(ContainerName)
''', 'PT5M', 'Count', rules('GreaterThan', 0, 1))
    ])
  }
  {
    name: 'virtual-machines'
    displayName: 'Virtual machines (optional)'
    icon: 'SystemComponent'
    impact: 'Limited'
    signalGroups: lawGroup(centralWorkspaceId, [
      logSignal('vms-without-heartbeat', 'VMs silent for 10 minutes', $'''
print value = ${length(vmIds)} - toscalar(Heartbeat | where TimeGenerated > ago(10m) and _ResourceId has "/microsoft.compute/virtualmachines/" | summarize dcount(_ResourceId))
''', 'PT15M', 'Count', rules('GreaterThan', 0, 1))
    ])
  }

  // Layer 3: Azure resources, one copy per component
  {
    name: 'console-app'
    displayName: 'App Service: ${webAppName} (console)'
    signalGroups: resourceGroupOf(webAppId, definitionSignals(['sd-app-health-check']))
  }
  {
    name: 'shop-app'
    displayName: 'App Service: ${webAppName} (shop)'
    signalGroups: resourceGroupOf(webAppId, definitionSignals(['sd-app-health-check']))
  }
  {
    name: 'shoppers-aks'
    displayName: 'AKS: ${aksName} (shoppers)'
    signalGroups: resourceGroupOf(aksId, definitionSignals(['sd-node-cpu', 'sd-node-memory']))
  }
  {
    name: 'central-law'
    displayName: 'Log Analytics: ${last(split(centralWorkspaceId, '/'))}'
    signalGroups: resourceGroupOf(centralWorkspaceId, [
      metricSignal('query-availability', 'Query availability', 'Microsoft.OperationalInsights/workspaces', 'AvailabilityRate_Query', 'Average', 'Percent', rules('LessThan', 99, 95))
      metricSignal('ingestion-time', 'Ingestion delay', 'Microsoft.OperationalInsights/workspaces', 'Ingestion Time', 'Average', 'Seconds', rules('GreaterThan', 300, 900))
    ])
  }
  {
    name: 'monitor-workspace'
    displayName: 'Azure Monitor workspace: ${last(split(monitorWorkspaceId, '/'))}'
    signalGroups: resourceGroupOf(monitorWorkspaceId, [
      metricSignal('ingestion-limit-used', 'Ingestion limit used', 'Microsoft.Monitor/accounts', 'EventsPerMinuteIngestedPercentUtilization', 'Average', 'Percent', rules('GreaterThan', 80, 95))
    ])
  }
  {
    name: 'cluster-aks'
    displayName: 'AKS: ${aksName} (cluster)'
    signalGroups: resourceGroupOf(aksId, definitionSignals(['sd-node-cpu', 'sd-node-memory']))
  }
  {
    name: 'vmss'
    displayName: 'VM scale set: ${last(split(vmssId, '/'))}'
    signalGroups: resourceGroupOf(vmssId, [
      metricSignal('vmss-cpu', 'Scale set CPU', 'Microsoft.Compute/virtualMachineScaleSets', 'Percentage CPU', 'Average', 'Percent', rules('GreaterThan', 80, 95))
    ])
  }
]

var vmEntities = [
  for (vmId, i) in vmIds: {
    name: 'vm-${i}'
    displayName: 'VM: ${last(split(vmId, '/'))}'
    signalGroups: resourceGroupOf(vmId, definitionSignals(['sd-vm-cpu']))
  }
]

resource entityResources 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [
  for e in concat(entities, vmEntities): {
    parent: healthModel
    name: e.name
    properties: {
      displayName: e.displayName
      icon: contains(e, 'icon') ? { iconName: e.icon } : null
      impact: e.?impact ?? 'Standard'
      healthObjective: e.?healthObjective
      alerts: e.?alerts
      signalGroups: e.?signalGroups
    }
    dependsOn: [
      authSetting
      signalDefinitions
    ]
  }
]

// -----------------------------------------------------------------------------
// Relationships: health flows from child to parent
// -----------------------------------------------------------------------------
var edges = concat(
  [
    { parent: healthModelName, child: 'operate-lab' }
    { parent: healthModelName, child: 'shop-demo' }
    { parent: healthModelName, child: 'live-telemetry' }
    { parent: 'operate-lab', child: 'control-center' }
    { parent: 'operate-lab', child: 'lab-operations' }
    { parent: 'shop-demo', child: 'shop-api' }
    { parent: 'shop-demo', child: 'synthetic-shoppers' }
    { parent: 'live-telemetry', child: 'log-pipeline' }
    { parent: 'live-telemetry', child: 'metrics-pipeline' }
    { parent: 'live-telemetry', child: 'kubernetes-workloads' }
    { parent: 'live-telemetry', child: 'virtual-machines' }
    { parent: 'control-center', child: 'console-app' }
    { parent: 'shop-api', child: 'shop-app' }
    { parent: 'synthetic-shoppers', child: 'shoppers-aks' }
    { parent: 'log-pipeline', child: 'central-law' }
    { parent: 'metrics-pipeline', child: 'monitor-workspace' }
    { parent: 'kubernetes-workloads', child: 'cluster-aks' }
    { parent: 'virtual-machines', child: 'vmss' }
  ],
  map(range(0, length(vmIds)), i => { parent: 'virtual-machines', child: 'vm-${i}' })
)

resource relationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-11-01' = [
  for edge in edges: {
    parent: healthModel
    name: '${edge.parent}--${edge.child}'
    properties: {
      parentEntityName: edge.parent
      childEntityName: edge.child
    }
    dependsOn: [
      entityResources
    ]
  }
]

output healthModelId string = healthModel.id
output principalId string = healthModel.identity.principalId
