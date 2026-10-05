// =====================================================================================
// Stage AI (optional) — Microsoft Foundry GenAI workload + token observability.
//
// Adds a Foundry account + project, four model deployments (chat, embedding,
// optimization, Model Router), an Application Insights connection on the project,
// and two token-consumption metric alerts. Depends on Stage A (foundation) for the
// lab Application Insights (`appi-${namePrefix}-<suffix>`).
//
// The Foundry resources are pinned to swedencentral (via `aiLocation`), independent
// of the lab region, because the gpt-5-* / model-router SKUs and the Foundry portal
// features are region-limited — the same reason the workload Health Model is pinned.
//
// Agents and the traffic simulator are provisioned afterwards by scripts/setup-ai.ps1.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Region for the Foundry account + models. Pinned to swedencentral by default.')
param aiLocation string = 'swedencentral'

@description('Optional email for the token anomaly/spike alerts. Empty = alerts without notifications.')
param alertEmail string = ''

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Model Router deployment version. VERIFY for your region before enabling this stage.')
param routerModelVersion string = '2025-08-07'

@description('Deploy the AI FinOps query pack + workbook.')
param enableObservability bool = true

@description('Deploy a SEPARATE AI health model. Off by default — the AI tier is folded into the workload health model (hm-<prefix>-workload, Stage E) instead. Turn on only for a standalone A+AI deployment with no Stage E.')
param enableHealthModel bool = false

var suffix = uniqueString(resourceGroup().id)
var appInsightsName = 'appi-${namePrefix}-${take(suffix, 5)}'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// Created in Stage A (foundation). The project connects to it for GenAI tracing.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

module foundry '../modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location: aiLocation
    namePrefix: namePrefix
    appInsightsId: appInsights.id
    appInsightsConnectionString: appInsights.properties.ConnectionString
    routerModelVersion: routerModelVersion
    alertEmail: alertEmail
    tags: commonTags
  }
}

// GenAI token/cost/health query pack + FinOps workbook.
module observability '../modules/ai-observability.bicep' = if (enableObservability) {
  name: 'ai-observability'
  params: {
    location: aiLocation
    appInsightsId: appInsights.id
    tags: commonTags
  }
}

// Health model: discovers agents, the Foundry account/projects and services as entities.
module healthModel '../modules/ai-healthmodel.bicep' = if (enableHealthModel) {
  name: 'ai-healthmodel'
  params: {
    location: aiLocation
    appInsightsId: appInsights.id
    lawId: appInsights.properties.WorkspaceResourceId
    healthModelName: 'hm-${namePrefix}-ai'
    tags: commonTags
  }
}

output foundryAccountName string = foundry.outputs.accountName
output foundryProjectName string = foundry.outputs.projectName
output projectEndpoint string = foundry.outputs.projectEndpoint
output chatDeployment string = foundry.outputs.chatDeployment
output routerDeployment string = foundry.outputs.routerDeployment
output appInsightsName string = appInsightsName
