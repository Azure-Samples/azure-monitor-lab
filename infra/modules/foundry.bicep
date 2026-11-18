// =====================================================================================
// Microsoft Foundry (AI Services) workload — the lab's GenAI observability pillar.
//
// Deploys a Foundry account + project, four model deployments (chat, embedding,
// optimization, and Model Router), and wires the project to the lab's EXISTING
// Application Insights so the Foundry portal's Tracing / token / cost views light up.
// Also lands two token-consumption metric alerts (dynamic anomaly + static spike)
// on the account's TotalTokens metric.
//
// Region: this module is deployed to `location` (the AI stage pins it to
// swedencentral, independent of the lab region) because the gpt-5-* / model-router
// SKUs and the Foundry portal features are region-limited — the same reason the
// workload Health Model is pinned to swedencentral.
// =====================================================================================

@description('Region for the Foundry account + models. Pinned to swedencentral by the AI stage.')
param location string

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Resource ID of the lab Application Insights the project connects to (for tracing).')
param appInsightsId string

@description('Connection string of the lab Application Insights.')
@secure()
param appInsightsConnectionString string

@description('Chat model, version and capacity (thousands TPM).')
param chatModel string = 'gpt-5-mini'
param chatModelVersion string = '2025-08-07'
param chatCapacity int = 10

@description('Embedding model, version and capacity.')
param embedModel string = 'text-embedding-3-small'
param embedModelVersion string = '1'
param embedCapacity int = 10

@description('Optimization model (Agent Optimizer target), version and capacity.')
param optModel string = 'gpt-5.4'
param optModelVersion string = '2026-03-05'
param optCapacity int = 10

// Model Router picks a cheaper/stronger underlying model per request. Confirm the
// current version for your region with:
//   az cognitiveservices account list-models --name <account> -g <rg> -o table
@description('Model Router deployment version and capacity. VERIFY the version for your region.')
param routerModelVersion string = '2025-08-07'
param routerCapacity int = 10

@description('Optional email. When set, an action group is created and attached to both token alerts.')
param alertEmail string = ''

@description('Static spike ceiling: TotalTokens (prompt+completion) per 5-minute window, per deployment.')
param spikeThresholdTokens int = 200000

@description('Dynamic-threshold sensitivity for the token anomaly alert.')
@allowed([ 'Low', 'Medium', 'High' ])
param anomalySensitivity string = 'Medium'

@description('Resource tags.')
param tags object = {}

var suffix = uniqueString(resourceGroup().id)
var accountName = toLower('ai${namePrefix}${take(suffix, 8)}')
var projectName = '${namePrefix}-ai-proj'
var metricNamespace = 'Microsoft.CognitiveServices/accounts'
var foundryUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

// Foundry (AI Services) account with project management enabled.
resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Azure Monitor Lab — AI'
    description: 'GenAI workload generating token/trace/cost telemetry for the observability lab.'
  }
  // Account allows only one write at a time — order the project after all deployments.
  dependsOn: [ router ]
}

resource deployerFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, deployer().objectId, foundryUserRole)
  scope: project
  properties: {
    principalId: deployer().objectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRole)
  }
}

resource projectFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, project.id, foundryUserRole)
  scope: account
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRole)
  }
}

// Deployments must be created sequentially (the account serializes deployment writes).
resource chat 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: chatModel
  sku: { name: 'GlobalStandard', capacity: chatCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModel, version: chatModelVersion }
  }
}

resource embed 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: embedModel
  sku: { name: 'GlobalStandard', capacity: embedCapacity }
  properties: {
    model: { format: 'OpenAI', name: embedModel, version: embedModelVersion }
  }
  dependsOn: [ chat ]
}

resource optimize 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: optModel
  sku: { name: 'GlobalStandard', capacity: optCapacity }
  properties: {
    model: { format: 'OpenAI', name: optModel, version: optModelVersion }
  }
  dependsOn: [ embed ]
}

// Model Router — the deployment the traffic simulator's "router" persona targets.
resource router 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: 'model-router'
  sku: { name: 'GlobalStandard', capacity: routerCapacity }
  properties: {
    model: { format: 'OpenAI', name: 'model-router', version: routerModelVersion }
  }
  dependsOn: [ optimize ]
}

// Attach the lab App Insights to the project so the portal Observability/Tracing tab lights up.
resource appiConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: '${namePrefix}-appinsights'
  properties: {
    category: 'AppInsights'
    target: appInsightsId
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: appInsightsConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsightsId
    }
  }
}

// Optional notification channel (alerts still fire and surface in Monitor > Alerts without it).
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-${namePrefix}-ai'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'amlabai'
    enabled: true
    emailReceivers: [
      {
        name: 'owner'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

var actions = empty(alertEmail) ? [] : [ { actionGroupId: actionGroup.id } ]
var deploymentDimension = [
  {
    name: 'ModelDeploymentName'
    operator: 'Include'
    values: [ '*' ]
  }
]

// 1) Anomaly detection — dynamic thresholds learn the baseline per deployment.
resource tokenAnomalyAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${namePrefix}-token-anomaly'
  location: 'global'
  tags: tags
  properties: {
    description: 'Token consumption (TotalTokens) deviates from the learned normal pattern for a model deployment. Uses Azure Monitor dynamic thresholds.'
    severity: 2
    enabled: true
    scopes: [ account.id ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    targetResourceType: metricNamespace
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'TokenAnomaly'
          criterionType: 'DynamicThresholdCriterion'
          metricNamespace: metricNamespace
          metricName: 'TotalTokens'
          operator: 'GreaterThan'
          timeAggregation: 'Total'
          alertSensitivity: anomalySensitivity
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 3
          }
          dimensions: deploymentDimension
        }
      ]
    }
    actions: actions
  }
}

// 2) Hard spike guardrail — static ceiling per deployment.
resource tokenSpikeAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${namePrefix}-token-spike'
  location: 'global'
  tags: tags
  properties: {
    description: 'Token consumption (TotalTokens) for a model deployment exceeded the static ceiling in a 5-minute window.'
    severity: 3
    enabled: true
    scopes: [ account.id ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'TokenSpike'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: metricNamespace
          metricName: 'TotalTokens'
          operator: 'GreaterThan'
          threshold: spikeThresholdTokens
          timeAggregation: 'Total'
          dimensions: deploymentDimension
        }
      ]
    }
    actions: actions
  }
}

output accountName string = account.name
output accountId string = account.id
output projectName string = project.name
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output chatDeployment string = chat.name
output embedDeployment string = embed.name
output optimizeDeployment string = optimize.name
output routerDeployment string = router.name
