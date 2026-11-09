@description('Stable model name; updating it preserves the existing model history.')
param healthModelName string = 'hm-lab-cafe'
param location string = 'swedencentral'
param webAppId string
param storageId string
param workspaceId string
param actionGroupId string
param controlCenterWebAppId string
@description('Shared reporter role created by healthmodel-lab/main.bicep.')
param reporterRoleDefinitionId string
@description('Optional existing RG Monitoring Reader assignment GUID. Empty grants resource-scoped read access without conflicting with a standalone CLI assignment.')
param monitoringReaderAssignmentName string = ''
param tags object = {}

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-11-01' = {
  name: healthModelName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
}

module reader 'reader-role.bicep' = {
  name: '${healthModelName}-monitoring-reader'
  params: {
    principalId: healthModel.identity.principalId
    assignmentName: monitoringReaderAssignmentName
    webAppId: webAppId
    storageId: storageId
    workspaceId: workspaceId
  }
}

resource console 'Microsoft.Web/sites@2023-12-01' existing = {
  name: last(split(controlCenterWebAppId, '/'))
  scope: resourceGroup(split(controlCenterWebAppId, '/')[2], split(controlCenterWebAppId, '/')[4])
}

module reporter '../healthmodel-lab/health-model-role.bicep' = {
  name: '${healthModelName}-console-reporter'
  params: {
    healthModelName: healthModel.name
    principalId: console.identity.principalId
    roleDefinitionId: reporterRoleDefinitionId
  }
}

resource auth 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-11-01' = {
  parent: healthModel
  name: 'auth-system'
  properties: {
    displayName: 'System-assigned managed identity'
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
  dependsOn: [reader]
}

func rules(operator string, degraded string, unhealthy string) object => {
  degradedRule: { operator: operator, threshold: json(degraded) }
  unhealthyRule: { operator: operator, threshold: json(unhealthy) }
}

var definitions = [
  {
    name: 'sd-app-health-check'
    displayName: 'Web app health check'
    metricNamespace: 'Microsoft.Web/sites'
    metricName: 'HealthCheckStatus'
    evaluationRules: rules('LessThan', '100', '50')
  }
  {
    name: 'sd-storage-availability'
    displayName: 'Storage availability'
    metricNamespace: 'Microsoft.Storage/storageAccounts'
    metricName: 'Availability'
    evaluationRules: rules('LessThan', '99.9', '99')
  }
]

resource signalDefinitions 'Microsoft.CloudHealth/healthmodels/signaldefinitions@2026-11-01' = [for d in definitions: {
  parent: healthModel
  name: d.name
  properties: {
    signalKind: 'AzureResourceMetric'
    displayName: d.displayName
    metricNamespace: d.metricNamespace
    metricName: d.metricName
    aggregationType: 'Average'
    timeGrain: 'PT5M'
    refreshInterval: 'PT1M'
    dataUnit: 'Percent'
    evaluationRules: d.evaluationRules
  }
}]

func logSignal(name string, displayName string, query string, unit string, evaluationRules object) object => {
  name: name
  displayName: displayName
  signalKind: 'LogAnalyticsQuery'
  queryText: query
  valueColumnName: 'value'
  timeGrain: 'PT5M'
  refreshInterval: 'PT1M'
  dataUnit: unit
  evaluationRules: evaluationRules
}

func logGroup(workspaceId string, signals array) object => {
  azureLogAnalytics: {
    authenticationSetting: 'auth-system'
    logAnalyticsWorkspaceResourceId: workspaceId
    signals: signals
  }
}

func resourceSignals(id string, definition string) object => {
  azureResource: {
    authenticationSetting: 'auth-system'
    azureResourceId: id
    signals: [
      {
        name: substring(definition, 3)
        signalKind: 'AzureResourceMetric'
        signalDefinitionName: definition
      }
    ]
  }
}

var failureRules = rules('GreaterThan', '0', '2')
var actionGroupIds = [actionGroupId]
var webAppName = last(split(webAppId, '/'))
var storageName = last(split(storageId, '/'))
var entities = [
  {
    name: 'browse-menu'
    displayName: 'Browse the menu'
    icon: 'UserFlow'
    healthObjective: json('99.5')
    alerts: {
      unhealthy: { severity: 'Sev2', description: 'Customers cannot see the café menu', actionGroupIds: actionGroupIds }
    }
  }
  {
    name: 'order-coffee'
    displayName: 'Order coffee'
    icon: 'UserFlow'
    healthObjective: json('99.9')
    alerts: {
      degraded: { severity: 'Sev3', description: 'Ordering coffee is slow or partly failing', actionGroupIds: actionGroupIds }
      unhealthy: { severity: 'Sev1', description: 'Customers cannot order coffee', actionGroupIds: actionGroupIds }
    }
  }
  {
    name: 'cafe-website'
    displayName: 'Café website'
    icon: 'SystemComponent'
    signalGroups: logGroup(workspaceId, [
      logSignal('failed-menu-requests', 'Failed menu requests', '''
AppRequests
| where TimeGenerated > ago(5min)
| extend path = tostring(parse_url(Url).Path)
| where path in ("", "/", "/api/menu")  // the root URL has an empty path
| summarize value = countif(Success == false)
''', 'Count', failureRules)
      logSignal('synthetic-browse-failures', 'Synthetic customer cannot open the menu', '''
AppAvailabilityResults
| where TimeGenerated > ago(5min)
| where Name == "synthetic-browse-menu"
| summarize value = countif(Success == false)
''', 'Count', failureRules)
    ])
  }
  {
    name: 'menu-catalog'
    displayName: 'Menu catalog'
    icon: 'SystemComponent'
    signalGroups: logGroup(workspaceId, [
      logSignal('failed-menu-reads', 'Failed menu reads from storage', '''
AppDependencies
| where TimeGenerated > ago(5min)
| where Target has "blob.core.windows.net" and Data has "/menu/"
| summarize value = countif(Success == false)
''', 'Count', failureRules)
    ])
  }
  {
    name: 'order-api'
    displayName: 'Order API'
    icon: 'SystemComponent'
    signalGroups: logGroup(workspaceId, [
      logSignal('failed-order-requests', 'Failed order requests', '''
AppRequests
| where TimeGenerated > ago(5min)
| where Url has "/api/orders"
| summarize value = countif(ResultCode startswith "5")  // a 404 for a mistyped order ID is not an outage
''', 'Count', failureRules)
      logSignal('slow-orders', 'Order time for most customers (p95)', '''
AppRequests
| where TimeGenerated > ago(5min)
| where Url has "/api/orders"
| summarize p95 = percentile(DurationMs, 95)
| project value = coalesce(p95, 0.0)
''', 'MilliSeconds', rules('GreaterThan', '1000', '3000'))
      logSignal('synthetic-order-failures', 'Synthetic customer cannot order', '''
AppAvailabilityResults
| where TimeGenerated > ago(5min)
| where Name == "synthetic-order-coffee"
| summarize value = countif(Success == false)
''', 'Count', failureRules)
    ])
  }
  {
    name: 'order-store'
    displayName: 'Order store'
    icon: 'SystemComponent'
    signalGroups: logGroup(workspaceId, [
      logSignal('failed-order-writes', 'Failed order storage calls', '''
AppDependencies
| where TimeGenerated > ago(5min)
| where Target has "blob.core.windows.net" and Data has "/orders/"
| summarize value = countif(Success == false and ResultCode != "404")  // 404: looked-up order doesn't exist
''', 'Count', failureRules)
    ])
  }
  {
    name: 'barista-display'
    displayName: 'Barista display (optional)'
    icon: 'SystemComponent'
    impact: 'Limited'
    signalGroups: logGroup(workspaceId, [
      logSignal('failed-barista-notifications', 'Orders the barista display missed', '''
AppDependencies
| where TimeGenerated > ago(5min)
| where Target has "queue.core.windows.net"
| summarize value = countif(Success == false)
''', 'Count', failureRules)
    ])
  }
  {
    name: 'menu-app'
    displayName: 'App Service: ${webAppName} (menu)'
    signalGroups: resourceSignals(webAppId, 'sd-app-health-check')
  }
  {
    name: 'menu-storage'
    displayName: 'Storage: ${storageName} (menu blob)'
    signalGroups: resourceSignals(storageId, 'sd-storage-availability')
  }
  {
    name: 'order-app'
    displayName: 'App Service: ${webAppName} (orders)'
    signalGroups: resourceSignals(webAppId, 'sd-app-health-check')
  }
  {
    name: 'order-storage'
    displayName: 'Storage: ${storageName} (order blobs)'
    signalGroups: resourceSignals(storageId, 'sd-storage-availability')
  }
  {
    name: 'queue-storage'
    displayName: 'Storage: ${storageName} (order queue)'
    signalGroups: resourceSignals(storageId, 'sd-storage-availability')
  }
]

// Same leaf ordering and centering as Get-CanvasLayout in the standalone builder.
var canvas = json('''
{
  "order-coffee": { "x": -312.5, "y": 193 },
  "browse-menu": { "x": 312.5, "y": 193 },
  "order-store": { "x": -562.5, "y": 386 },
  "order-api": { "x": -312.5, "y": 386 },
  "barista-display": { "x": -62.5, "y": 386 },
  "menu-catalog": { "x": 187.5, "y": 386 },
  "cafe-website": { "x": 437.5, "y": 386 },
  "order-storage": { "x": -562.5, "y": 579 },
  "order-app": { "x": -312.5, "y": 579 },
  "queue-storage": { "x": -62.5, "y": 579 },
  "menu-storage": { "x": 187.5, "y": 579 },
  "menu-app": { "x": 437.5, "y": 579 }
}
''')

// CloudHealth creates this root automatically. PUT the same child ID, never a second root.
resource root 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: healthModelName
  properties: {
    canvasPosition: { x: 0, y: 0 }
  }
}

resource entityResources 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [for e in entities: {
  parent: healthModel
  name: e.name
  properties: {
    displayName: e.displayName
    icon: contains(e, 'icon') ? { iconName: e.icon } : null
    impact: e.?impact ?? 'Standard'
    healthObjective: e.?healthObjective
    alerts: e.?alerts
    signalGroups: e.?signalGroups
    canvasPosition: canvas[e.name]
  }
  dependsOn: [auth, signalDefinitions]
}]

var edges = [
  { parent: healthModelName, child: 'order-coffee' }
  { parent: healthModelName, child: 'browse-menu' }
  { parent: 'order-coffee', child: 'order-store' }
  { parent: 'order-coffee', child: 'order-api' }
  { parent: 'order-coffee', child: 'barista-display' }
  { parent: 'browse-menu', child: 'menu-catalog' }
  { parent: 'browse-menu', child: 'cafe-website' }
  { parent: 'order-store', child: 'order-storage' }
  { parent: 'order-api', child: 'order-app' }
  { parent: 'barista-display', child: 'queue-storage' }
  { parent: 'menu-catalog', child: 'menu-storage' }
  { parent: 'cafe-website', child: 'menu-app' }
]

resource relationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-11-01' = [for edge in edges: {
  parent: healthModel
  name: '${edge.parent}--${edge.child}'
  properties: {
    parentEntityName: edge.parent
    childEntityName: edge.child
  }
  dependsOn: [root, entityResources]
}]

output healthModelId string = healthModel.id
