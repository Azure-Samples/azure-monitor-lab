targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Enable Microsoft Sentinel on the central workspace.')
param enableSentinel bool = true

@description('Deploy the Windows demo VM.')
param deployWindowsVm bool = true

@description('Deploy the Linux demo VM.')
param deployLinuxVm bool = true

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Enable the platform-logs DCR (scenario 51, public preview). Off by default — preview + region-limited.')
param enablePlatformLogsDcr bool = false

@description('Enable the metrics-export DCR (scenario 52, GA). Off by default — DCR + LAW must share a region.')
param enableMetricsExportDcr bool = false

@description('Fold the AI (Foundry) workload into the workload health model as a fourth "AI" tier. Requires the AI stage (50-ai) to have run.')
param enableAi bool = false

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var amwName = 'amw-${namePrefix}'
var grafanaName = 'amg-${namePrefix}-${take(suffix, 4)}'
var aksName = 'aks-${namePrefix}'
var actionGroupName = 'ag-${namePrefix}-email'
var storageAccountName = 'st${namePrefix}${take(suffix, 8)}'
var keyVaultName = 'kv-${namePrefix}-${take(suffix, 5)}'
var appInsightsName = 'appi-${namePrefix}-${take(suffix, 5)}'
var webAppName = 'app-${namePrefix}-${take(suffix, 5)}'
var vmssName = 'vmss-${namePrefix}'
var linuxVmName = 'vm-${namePrefix}-lin'
var windowsVmName = 'vmwin${take(suffix, 4)}'
var sliUamiName = 'id-sli-${namePrefix}'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

resource lawCentral 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawCentralName
}

resource amw 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: amwName
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' existing = {
  name: aksName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' existing = {
  name: actionGroupName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' existing = {
  name: vmssName
}

resource vmLinux 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployLinuxVm) {
  name: linuxVmName
}

resource vmWindows 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployWindowsVm) {
  name: windowsVmName
}

module sentinel '../modules/sentinel-onboarding.bicep' = if (enableSentinel) {
  name: 'sentinel'
  params: {
    workspaceName: lawCentral.name
    workspaceId: lawCentral.id
    location: location
    tags: commonTags
  }
}

module dataExport '../modules/data-export.bicep' = {
  name: 'data-export'
  params: {
    name: 'exp-${namePrefix}-heartbeat'
    workspaceName: lawCentral.name
    storageAccountId: storageAccount.id
    tables: [
      'Heartbeat'
    ]
  }
}

module prometheusRules '../modules/prometheus-rules.bicep' = {
  name: 'prometheus-rules'
  params: {
    name: 'prg-${namePrefix}'
    location: location
    azureMonitorWorkspaceId: amw.id
    aksClusterId: aks.id
    actionGroupId: actionGroup.id
    tags: commonTags
  }
}

module availabilityTest '../modules/availability-test.bicep' = {
  name: 'availability-test'
  params: {
    name: 'test-${namePrefix}-app'
    location: location
    appInsightsId: appInsights.id
    testUrl: 'https://${webApp.properties.defaultHostName}/'
    actionGroupId: actionGroup.id
    tags: commonTags
  }
}

module agentTaskAvailabilityTest '../modules/availability-test.bicep' = {
  name: 'agent-task-availability-test'
  params: {
    name: 'test-${namePrefix}-agent-task'
    location: location
    appInsightsId: appInsights.id
    testUrl: 'https://${webApp.properties.defaultHostName}/api/agent-task-availability'
    actionGroupId: actionGroup.id
    tags: commonTags
  }
}

module healthModel '../modules/health-model.bicep' = {
  name: 'health-model'
  params: {
    healthModelName: 'hm-${namePrefix}-workload'
    // Health Model (preview) is only available in a limited set of regions
    // (UK South, Canada Central, Central US, Sweden Central, Southeast Asia),
    // so its region is pinned to swedencentral independent of the lab location.
    location: 'swedencentral'
    webAppId: webApp.id
    appInsightsId: appInsights.id
    aksId: aks.id
    linuxVmId: deployLinuxVm ? vmLinux.id : ''
    windowsVmId: deployWindowsVm ? vmWindows.id : ''
    vmssId: vmss.id
    keyVaultId: resourceId('Microsoft.KeyVault/vaults', 'kv-${namePrefix}-${take(suffix, 5)}')
    storageAccountId: storageAccount.id
    actionGroupId: actionGroup.id
    // Fold the AI tier in when the Foundry account (from the AI stage) exists.
    enableAi: enableAi
    foundryAccountId: enableAi ? resourceId('Microsoft.CognitiveServices/accounts', toLower('ai${namePrefix}${take(suffix, 8)}')) : ''
    appInsightsLawId: appInsights.properties.WorkspaceResourceId
    tags: commonTags
  }
}

module sliIdentity '../modules/sli-identity.bicep' = {
  name: 'sli-identity'
  params: {
    uamiName: sliUamiName
    location: location
    azureMonitorWorkspaceId: amw.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Scenario 51 — Platform logs at scale with DCRs (public preview).
//   Single PlatformTelemetry DCR + association on Azure Managed Grafana, replacing the
//   per-resource diagnostic-setting model. Off by default (preview + region-limited).
// ---------------------------------------------------------------------------------
module platformLogsDcr '../modules/platform-logs-dcr.bicep' = if (enablePlatformLogsDcr) {
  name: 'platform-logs-dcr'
  params: {
    name: 'dcr-${namePrefix}-platformlogs'
    location: location
    centralLawId: lawCentral.id
    grafanaName: grafanaName
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Scenario 52 — Azure Monitor Metrics Export via DCRs (GA).
//   Single PlatformTelemetry DCR + association on the Key Vault, exporting
//   dimensional platform metrics to the central LAW. Off by default (region-bound).
// ---------------------------------------------------------------------------------
module metricsExportDcr '../modules/metrics-export-dcr.bicep' = if (enableMetricsExportDcr) {
  name: 'metrics-export-dcr'
  params: {
    name: 'dcr-${namePrefix}-metricsexport'
    location: location
    centralLawId: lawCentral.id
    keyVaultName: keyVaultName
    tags: commonTags
  }
}
