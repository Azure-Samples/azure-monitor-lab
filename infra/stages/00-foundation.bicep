targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Daily ingestion cap (GB) on the central Log Analytics workspace. Set to -1 to disable.')
param dailyCapGb int = 1

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Enable LAW cross-region replication.')
param enableLawReplication bool = false

@description('Secondary region for LAW replication.')
param lawReplicationLocation string = ''

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var lawAppInsightsName = 'law-${namePrefix}-appinsights-${take(suffix, 5)}'
var appInsightsName = 'appi-${namePrefix}'
var amwName = 'amw-${namePrefix}'
var vnetName = 'vnet-${namePrefix}'
var nsgName = 'nsg-${namePrefix}'
var workbookName = 'wb-${namePrefix}-trafficlights'
var dcrVmInsightsName = 'dcr-${namePrefix}-vminsights'
var dceName = 'dce-${namePrefix}'
var storageAccountName = 'st${namePrefix}${take(suffix, 8)}'
var eventHubNsName = 'evhns-${namePrefix}-${take(suffix, 5)}'
var keyVaultName = 'kv-${namePrefix}-${take(suffix, 5)}'
var costWorkbookName = 'wb-${namePrefix}-cost'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// App Service (Stage B) is pinned to westeurope (no Basic App Service quota in
// northeurope on the sponsored subs). The Event Hub below is the App Service's
// diagnostic fan-out target, and Event Hub diag destinations MUST be in the same
// region as the monitored resource — so it is co-located in westeurope too.
var appServiceLocation = 'westeurope'

module lawCentral '../modules/law.bicep' = {
  name: 'law-central'
  params: {
    name: lawCentralName
    location: location
    dailyQuotaGb: dailyCapGb
    tags: commonTags
    // VM Insights and Container Insights are wired the modern way:
    //  - VM Insights via the inline `dcr-${namePrefix}-vminsights` DCR + AMA on each VM.
    //  - Container Insights via the AKS `omsagent` addon (Stage B) + Managed Prometheus DCR.
    // The legacy `Microsoft.OperationsManagement/solutions` workspace add-ons are intentionally
    // omitted; they are not required for these DCR/addon-driven pipelines.
    enableReplication: enableLawReplication
    replicationLocation: lawReplicationLocation
  }
}

module lawAppInsights '../modules/law.bicep' = {
  name: 'law-appinsights'
  params: {
    name: lawAppInsightsName
    location: location
    dailyQuotaGb: dailyCapGb
    tags: commonTags
  }
}

module appInsights '../modules/appinsights.bicep' = {
  name: 'appi'
  params: {
    name: appInsightsName
    location: location
    workspaceId: lawAppInsights.outputs.id
    tags: commonTags
  }
}

module amw '../modules/azure-monitor-workspace.bicep' = {
  name: 'amw'
  params: {
    name: amwName
    location: location
    tags: commonTags
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: commonTags
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

module network '../modules/network.bicep' = {
  name: 'network'
  params: {
    vnetName: vnetName
    nsgName: nsgName
    location: location
    tags: commonTags
  }
}

module storageAccount '../modules/storage-account.bicep' = {
  name: 'storage-account'
  params: {
    name: storageAccountName
    location: location
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

module eventHub '../modules/eventhub.bicep' = {
  name: 'eventhub'
  params: {
    namespaceName: eventHubNsName
    location: appServiceLocation
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

module keyVault '../modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

resource dcrVmInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrVmInsightsName
  location: location
  tags: commonTags
  kind: 'Linux'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'VMInsightsPerfCounters'
          streams: [
            'Microsoft-InsightsMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\VmInsights\\DetailedMetrics'
          ]
        }
      ]
      extensions: [
        {
          name: 'DependencyAgentDataSource'
          streams: [
            'Microsoft-ServiceMap'
          ]
          extensionName: 'DependencyAgent'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: lawCentral.outputs.id
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-InsightsMetrics'
        ]
        destinations: [
          'centralLaw'
        ]
      }
      {
        streams: [
          'Microsoft-ServiceMap'
        ]
        destinations: [
          'centralLaw'
        ]
      }
    ]
  }
}

module workspaceTransforms '../modules/dcr-workspace-transforms.bicep' = {
  name: 'workspace-transforms'
  params: {
    // Suffixed to match the LAW: WorkspaceTransforms DCRs have an IMMUTABLE
    // destination (kind=WorkspaceTransforms), so renaming the LAW forces a
    // new DCR — ARM cannot update the destination in place.
    name: 'dcr-${namePrefix}-workspace-transforms-${take(suffix, 5)}'
    location: location
    centralLawId: lawCentral.outputs.id
    centralLawName: lawCentral.outputs.name
    tags: commonTags
  }
}

module policyDiag '../modules/policy-diagnostics.bicep' = {
  name: 'policy-diagnostics'
  params: {
    centralLawId: lawCentral.outputs.id
  }
}

module savedQueries '../modules/saved-queries.bicep' = {
  name: 'saved-queries'
  params: {
    centralLawName: lawCentral.outputs.name
    appInsightsLawName: lawAppInsights.outputs.name
  }
}

module kqlFunctions '../modules/kql-functions.bicep' = {
  name: 'kql-functions'
  params: {
    centralLawName: lawCentral.outputs.name
    appInsightsLawName: lawAppInsights.outputs.name
  }
}

module workbook '../modules/workbook.bicep' = {
  name: 'workbook-traffic-lights'
  params: {
    name: guid(resourceGroup().id, workbookName)
    location: location
    centralLawId: lawCentral.outputs.id
    appInsightsLawName: lawAppInsights.outputs.name
    tags: commonTags
  }
}

module costWorkbook '../modules/cost-workbook.bicep' = {
  name: 'workbook-cost'
  params: {
    name: guid(resourceGroup().id, costWorkbookName)
    location: location
    centralLawId: lawCentral.outputs.id
    dailyCapGb: dailyCapGb
    tags: commonTags
  }
}
