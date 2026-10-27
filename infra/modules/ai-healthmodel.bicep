// =====================================================================================
// Azure Monitor health model for the AI stage — turns the Foundry workload into a
// live topology of entities with health signals.
//
// Entities are added automatically by DISCOVERY RULES:
//   1. Application Insights topology  -> traced agents + dependencies (gen_ai.* spans).
//   2. Resource graph query           -> the Foundry (AI Services) account.
//   3. Resource graph query           -> the Foundry projects.
//   4. Resource graph query           -> the observability services (App Insights + LAW).
// Plus one explicit entity per agent persona, each carrying custom Log Analytics
// signals for error-rate and token volume.
//
// Region-pinned (aiLocation, swedencentral) like the workload health model — the
// CloudHealth preview is region-limited. Discovery + signals run under the model's
// system-assigned identity (Reader + Monitoring Reader + Log Analytics Reader on the RG).
// =====================================================================================

@description('Location for the health model (pinned to a CloudHealth-supported region).')
param location string

@description('App Insights component resource id (source for topology discovery).')
param appInsightsId string

@description('Log Analytics workspace resource id backing App Insights (source for custom agent signals).')
param lawId string

@description('Name of the health model.')
param healthModelName string

@description('Resource tags.')
param tags object = {}

// ARG queries are scoped to this resource group. The `id` column is required.
var rg = toLower(resourceGroup().name)
var authSettingName = 'managed-identity'

// Built-in role definition ids used by discovery + signal collection.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

// Demo agent personas (gen_ai.agent.name from workloads/ai/create_agents.py) modelled
// as explicit entities, since topology discovery only sees cloud-role nodes.
var agents = [
  { key: 'support-triage', display: 'Support Triage', x: 100, y: 100 }
  { key: 'finops-qa', display: 'FinOps Q&A', x: 420, y: 100 }
  { key: 'doc-summarizer', display: 'Doc Summarizer', x: 100, y: 320 }
  { key: 'context-rich-assistant', display: 'Context-Rich Assistant', x: 420, y: 320 }
]

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-05-01-preview' = {
  name: healthModelName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
}

resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-05-01-preview' = {
  parent: healthModel
  name: authSettingName
  properties: {
    displayName: 'Managed identity'
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
}

// 1) Agents + app dependencies from Application Insights topology.
resource discoverAgents 'Microsoft.CloudHealth/healthmodels/discoveryrules@2026-05-01-preview' = {
  parent: healthModel
  name: 'agents-topology'
  properties: {
    displayName: 'Agents (App Insights topology)'
    authenticationSetting: authSettingName
    addRecommendedSignals: 'Enabled'
    addResourceHealthSignal: 'Enabled'
    discoverRelationships: 'Enabled'
    specification: {
      kind: 'ApplicationInsightsTopology'
      applicationInsightsResourceId: appInsightsId
    }
  }
  dependsOn: [ authSetting ]
}

// 2) Foundry (AI Services) account.
resource discoverAccount 'Microsoft.CloudHealth/healthmodels/discoveryrules@2026-05-01-preview' = {
  parent: healthModel
  name: 'foundry-account'
  properties: {
    displayName: 'Foundry account'
    authenticationSetting: authSettingName
    addRecommendedSignals: 'Enabled'
    addResourceHealthSignal: 'Enabled'
    discoverRelationships: 'Enabled'
    specification: {
      kind: 'ResourceGraphQuery'
      resourceGraphQuery: 'resources | where resourceGroup =~ \'${rg}\' and type =~ \'microsoft.cognitiveservices/accounts\' | project id, name'
    }
  }
  dependsOn: [ authSetting ]
}

// 3) Foundry projects.
resource discoverProjects 'Microsoft.CloudHealth/healthmodels/discoveryrules@2026-05-01-preview' = {
  parent: healthModel
  name: 'foundry-projects'
  properties: {
    displayName: 'Foundry projects'
    authenticationSetting: authSettingName
    addRecommendedSignals: 'Enabled'
    addResourceHealthSignal: 'Enabled'
    discoverRelationships: 'Enabled'
    specification: {
      kind: 'ResourceGraphQuery'
      resourceGraphQuery: 'resources | where resourceGroup =~ \'${rg}\' and type =~ \'microsoft.cognitiveservices/accounts/projects\' | project id, name'
    }
  }
  dependsOn: [ authSetting ]
}

// 4) Observability services that capture the signals.
resource discoverObservability 'Microsoft.CloudHealth/healthmodels/discoveryrules@2026-05-01-preview' = {
  parent: healthModel
  name: 'observability-services'
  properties: {
    displayName: 'Observability services'
    authenticationSetting: authSettingName
    addRecommendedSignals: 'Enabled'
    addResourceHealthSignal: 'Enabled'
    discoverRelationships: 'Enabled'
    specification: {
      kind: 'ResourceGraphQuery'
      resourceGraphQuery: 'resources | where resourceGroup =~ \'${rg}\' and type in~ (\'microsoft.insights/components\', \'microsoft.operationalinsights/workspaces\') | project id, name'
    }
  }
  dependsOn: [ authSetting ]
}

// Grant the model's identity read access for ARG discovery...
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, readerRoleId)
  properties: {
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

// ...and to read monitoring data (App Insights topology + recommended signals).
resource monitoringReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, monitoringReaderRoleId)
  properties: {
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
  }
}

// ...and to run the custom Log Analytics query signals on the agent entities.
resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, logAnalyticsReaderRoleId)
  properties: {
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
  }
}

// One explicit entity per agent persona, each carrying two custom Log Analytics
// signals from the workspace-based App Insights `AppDependencies` table:
//   - error-rate : failed runs %      -> health of the agent
//   - token-volume : total tokens/hour -> anomalous volume drives the entity unhealthy
resource agentEntities 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = [for a in agents: {
  parent: healthModel
  name: 'agent-${a.key}'
  properties: {
    displayName: a.display
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: { x: a.x, y: a.y }
    signalGroups: {
      azureLogAnalytics: {
        authenticationSetting: authSettingName
        logAnalyticsWorkspaceResourceId: lawId
        signals: [
          {
            name: 'error-rate'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Error rate (%, 1h)'
            dataUnit: 'Percent'
            refreshInterval: 'PT5M'
            valueColumnName: 'ErrorPct'
            queryText: 'AppDependencies | where TimeGenerated > ago(1h) | where tostring(Properties[\'gen_ai.agent.name\']) == \'${a.display}\' | summarize total=count(), failures=countif(Success==false) | project ErrorPct=iff(total==0, 0.0, round(100.0*failures/total, 1))'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: 5 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 20 }
            }
          }
          {
            name: 'token-volume'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Total tokens/hour'
            dataUnit: 'Count'
            refreshInterval: 'PT5M'
            valueColumnName: 'TotalTokens'
            queryText: 'AppDependencies | where TimeGenerated > ago(1h) | where tostring(Properties[\'gen_ai.agent.name\']) == \'${a.display}\' | extend inTok=toint(Properties[\'gen_ai.usage.input_tokens\']), outTok=toint(Properties[\'gen_ai.usage.output_tokens\']) | summarize TotalTokens=coalesce(sum(inTok), 0)+coalesce(sum(outTok), 0)'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: 100000 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 200000 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}]

output healthModelName string = healthModel.name
output healthModelId string = healthModel.id
