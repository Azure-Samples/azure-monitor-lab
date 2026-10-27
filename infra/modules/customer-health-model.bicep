@description('Customer model name is always hm-<prefix>-customer, separate from the workload model.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'
@allowed(['swedencentral'])
param location string = 'swedencentral'
@description('Exact component resource IDs in this deployment resource group.')
param customerWebAppId string
param customerAppServicePlanId string
param customerSqlDatabaseId string
param customerServiceBusId string
param customerWorkerId string
param customerWorkerStorageId string
param customerCentralLawId string
param tags object = {}

var modelName = 'hm-${namePrefix}-customer'
var authName = 'systemAssigned'
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logReader = '73c42c96-874c-492b-b04d-ab87d138a893'

resource customerSite 'Microsoft.Web/sites@2023-12-01' existing = {
  name: last(split(customerWebAppId, '/'))
}
resource customerPlan 'Microsoft.Web/serverfarms@2023-12-01' existing = {
  name: last(split(customerAppServicePlanId, '/'))
}
resource customerSql 'Microsoft.Sql/servers/databases@2023-08-01' existing = {
  name: '${split(customerSqlDatabaseId, '/')[8]}/${last(split(customerSqlDatabaseId, '/'))}'
}
resource customerBus 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: last(split(customerServiceBusId, '/'))
}
resource customerWorker 'Microsoft.Web/sites@2023-12-01' existing = {
  name: last(split(customerWorkerId, '/'))
}
resource customerStorage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: last(split(customerWorkerStorageId, '/'))
}
resource customerLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(customerCentralLawId, '/'))
}

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-01-01-preview' = {
  name: modelName
  location: location
  identity: { type: 'SystemAssigned' }
  tags: tags
  properties: {}
}
resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-01-01-preview' = {
  parent: healthModel
  name: authName
  properties: {
    displayName: 'Customer model system-assigned identity'
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
}

resource siteReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerSite.id, healthModel.id, monitoringReader)
  scope: customerSite
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource planReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerPlan.id, healthModel.id, monitoringReader)
  scope: customerPlan
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource sqlReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerSql.id, healthModel.id, monitoringReader)
  scope: customerSql
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource busReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerBus.id, healthModel.id, monitoringReader)
  scope: customerBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource workerReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerWorker.id, healthModel.id, monitoringReader)
  scope: customerWorker
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource storageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerStorage.id, healthModel.id, monitoringReader)
  scope: customerStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(customerLaw.id, healthModel.id, logReader)
  scope: customerLaw
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logReader)
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource root 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: modelName
  properties: {
    displayName: 'Customer application architecture'
    impact: 'Standard'
    signalGroups: { dependencies: { aggregationType: 'WorstOf', ignoreUnknown: false } }
  }
}
var metricComponents = [
  { key: 'customer-webapp', display: 'Customer storefront', id: customerSite.id, namespace: 'Microsoft.Web/sites', metric: 'HttpResponseTime', aggregation: 'Average', unit: 'Seconds', degraded: 1, unhealthy: 3 }
  { key: 'customer-appservice-plan', display: 'Shared customer App Service plan', id: customerPlan.id, namespace: 'Microsoft.Web/serverfarms', metric: 'CpuPercentage', aggregation: 'Average', unit: 'Percent', degraded: 70, unhealthy: 90 }
  { key: 'customer-sql', display: 'Customer orders SQL', id: customerSql.id, namespace: 'Microsoft.Sql/servers/databases', metric: 'dtu_consumption_percent', aggregation: 'Average', unit: 'Percent', degraded: 70, unhealthy: 90 }
  { key: 'customer-servicebus', display: 'Orders queue runtime (Service Bus)', id: customerBus.id, namespace: 'Microsoft.ServiceBus/namespaces', metric: 'DeadletteredMessages', aggregation: 'Maximum', unit: 'Count', degraded: 0, unhealthy: 4 }
  { key: 'customer-worker-storage', display: 'Processor host storage', id: customerStorage.id, namespace: 'Microsoft.Storage/storageAccounts', metric: 'Availability', aggregation: 'Average', unit: 'Percent', degraded: 99, unhealthy: 95 }
]
resource metricEntities 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = [for item in metricComponents: {
  parent: healthModel
  name: item.key
  properties: {
    displayName: item.display
    impact: 'Standard'
    signalGroups: {
      dependencies: { aggregationType: 'WorstOf', ignoreUnknown: false }
      azureResource: {
        authenticationSetting: authName
        azureResourceId: item.id
        signals: concat([{
          name: replace(item.metric, '_', '-')
          signalKind: 'AzureResourceMetric'
          displayName: item.display
          metricNamespace: item.namespace
          metricName: item.metric
          aggregationType: item.aggregation
          dataUnit: item.unit
          timeGrain: 'PT5M'
          refreshInterval: 'PT1M'
          evaluationRules: {
            degradedRule: { operator: item.key == 'customer-worker-storage' ? 'LessThan' : 'GreaterThan', threshold: item.degraded }
            unhealthyRule: { operator: item.key == 'customer-worker-storage' ? 'LessThan' : 'GreaterThan', threshold: item.unhealthy }
          }
        }], item.key == 'customer-webapp' ? [{
          name: 'Http5xx'
          signalKind: 'AzureResourceMetric'
          displayName: 'Customer HTTP 5xx (5 min)'
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'Http5xx'
          aggregationType: 'Total'
          dataUnit: 'Count'
          timeGrain: 'PT5M'
          refreshInterval: 'PT1M'
          evaluationRules: {
            degradedRule: { operator: 'GreaterThan', threshold: 0 }
            unhealthyRule: { operator: 'GreaterThan', threshold: 4 }
          }
        }] : [])
      }
    }
  }
  dependsOn: [authSetting, siteReader, planReader, sqlReader, busReader, storageReader]
}]
resource processorEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'customer-processor'
  properties: {
    displayName: 'Orders processor'
    impact: 'Standard'
    signalGroups: {
      dependencies: { aggregationType: 'WorstOf', ignoreUnknown: false }
      azureLogAnalytics: {
        authenticationSetting: authName
        logAnalyticsWorkspaceResourceId: customerLaw.id
        signals: [{
          name: 'processor-errors'
          signalKind: 'LogAnalyticsQuery'
          displayName: 'Orders processor errors (5 min; no observations means Unknown)'
          dataUnit: 'Count'
          refreshInterval: 'PT1M'
          valueColumnName: 'Errors'
          // No rows for idle/unobserved hosts: do not fabricate a healthy zero.
          queryText: 'FunctionAppLogs | where TimeGenerated > ago(5m) | where _ResourceId =~ \'${customerWorker.id}\' | summarize Samples=count(), Errors=countif(Level in (\'Error\', \'Critical\')) | where Samples > 0 | project Errors'
          evaluationRules: {
            degradedRule: { operator: 'GreaterThan', threshold: 0 }
            unhealthyRule: { operator: 'GreaterThan', threshold: 4 }
          }
        }]
      }
    }
  }
  dependsOn: [authSetting, workerReader, workspaceReader]
}
var customerEdges = [
  { parent: modelName, child: 'customer-webapp' }
  { parent: 'customer-webapp', child: 'customer-appservice-plan' }
  { parent: 'customer-webapp', child: 'customer-sql' }
  { parent: 'customer-webapp', child: 'customer-servicebus' }
  { parent: 'customer-servicebus', child: 'customer-processor' }
  { parent: 'customer-processor', child: 'customer-sql' }
  { parent: 'customer-processor', child: 'customer-worker-storage' }
]
resource relationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = [for edge in customerEdges: {
  parent: healthModel
  name: '${edge.parent}-to-${edge.child}'
  properties: {
    parentEntityName: edge.parent
    childEntityName: edge.child
  }
  dependsOn: [root, metricEntities, processorEntity]
}]
output healthModelName string = healthModel.name
output healthModelId string = healthModel.id
output healthModelPrincipalId string = healthModel.identity.principalId
