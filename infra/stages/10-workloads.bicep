targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Admin username for the demo VMs.')
param vmAdminUsername string = 'azureuser'

@description('Admin password for the demo VMs.')
@secure()
param vmAdminPassword string

@description('Deploy the Windows demo VM.')
param deployWindowsVm bool = true

@description('Deploy the Linux demo VM.')
param deployLinuxVm bool = true

@description('Collect default OpenTelemetry guest metrics in the Azure Monitor workspace for the demo VMs, alongside classic VM Insights. Does not apply to VM Scale Sets.')
param enableVmOtelMetrics bool = true

@description('VM size.')
param vmSize string = 'Standard_B2s'

@description('AKS node VM size.')
param aksNodeVmSize string = 'Standard_B2s'

@description('AKS node count.')
param aksNodeCount int = 1

@description('Optional Microsoft Entra object ID of the Grafana lab operator or group. Empty grants Grafana Admin to the deployment identity; set explicitly for CI deployments.')
param grafanaAdminObjectId string = ''

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Enable the isolated customer Web App slot-recovery scenario. Reuses the App Service plan, upgrading it to Standard S1 when needed.')
param enableSlotFailureScenario bool = false

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var lawAppInsightsName = 'law-${namePrefix}-appinsights-${take(suffix, 5)}'
var appInsightsName = 'appi-${namePrefix}-${take(suffix, 5)}'
var amwName = 'amw-${namePrefix}'
var grafanaName = 'amg-${namePrefix}-${take(suffix, 4)}'
var vnetName = 'vnet-${namePrefix}'
var linuxVmName = 'vm-${namePrefix}-lin'
var windowsVmName = 'vmwin${take(suffix, 4)}'
var aksName = 'aks-${namePrefix}'
var aksDnsPrefix = '${namePrefix}-${take(suffix, 6)}'
var appPlanName = 'plan-${namePrefix}'
var webAppName = 'app-${namePrefix}-${take(suffix, 5)}'
var customerWebAppName = 'app-${namePrefix}-${take(suffix, 5)}-customer'
var dcrVmInsightsName = 'dcr-${namePrefix}-vminsights'
var deployVmOtelMetrics = enableVmOtelMetrics && (deployLinuxVm || deployWindowsVm)
var dcrPrometheusName = 'dcr-${namePrefix}-prometheus'
var dceName = 'dce-${namePrefix}'
var storageAccountName = 'st${namePrefix}${take(suffix, 8)}'
// Dedicated storage co-located with the App Service (westeurope) for its archive diag
// setting — storage diag destinations must match the source region.
var appDiagStorageName = 'stapp${namePrefix}${take(suffix, 8)}'
var eventHubNsName = 'evhns-${namePrefix}-${take(suffix, 5)}'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// App Service is pinned to westeurope, independent of the lab region — the sponsored
// lab subscriptions have no Basic (B1) App Service quota in northeurope, so the plan
// would fail ARM preflight there. westeurope has unlimited Basic quota.
var appServiceLocation = 'westeurope'

var workloadSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-workload')

resource lawCentral 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawCentralName
}

resource lawAppInsights 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawAppInsightsName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource amw 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: amwName
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' existing = {
  name: dceName
}

resource dcrVmInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: dcrVmInsightsName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource eventHubNs 'Microsoft.EventHub/namespaces@2022-10-01-preview' existing = {
  name: eventHubNsName
}

resource eventHubAuthRule 'Microsoft.EventHub/namespaces/authorizationRules@2022-10-01-preview' existing = {
  parent: eventHubNs
  name: 'RootManageSharedAccessKey'
}

module vmOtelMetrics '../modules/vm-otel-metrics.bicep' = if (deployVmOtelMetrics) {
  name: 'vm-otel-metrics'
  params: {
    name: 'dcr-${namePrefix}-vm-otel'
    location: location
    monitoringAccountId: amw.id
    tags: commonTags
  }
}

module vmLinux '../modules/vm-linux.bicep' = if (deployLinuxVm) {
  name: 'vm-linux'
  params: {
    vmName: linuxVmName
    location: location
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: workloadSubnetId
    dcrId: dcrVmInsights.id
    otelDcrId: deployVmOtelMetrics ? vmOtelMetrics!.outputs.id : ''
    tags: commonTags
  }
}

module vmWindows '../modules/vm-windows.bicep' = if (deployWindowsVm) {
  name: 'vm-windows'
  params: {
    vmName: windowsVmName
    location: location
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: workloadSubnetId
    dcrId: dcrVmInsights.id
    otelDcrId: deployVmOtelMetrics ? vmOtelMetrics!.outputs.id : ''
    tags: commonTags
  }
}

module aks '../modules/aks.bicep' = {
  name: 'aks'
  params: {
    name: aksName
    dnsPrefix: aksDnsPrefix
    location: location
    nodeVmSize: aksNodeVmSize
    nodeCount: aksNodeCount
    centralLawId: lawCentral.id
    azureMonitorWorkspaceId: amw.id
    dataCollectionEndpointId: dce.id
    dcrPrometheusName: dcrPrometheusName
    tags: commonTags
  }
}

module grafana '../modules/grafana.bicep' = {
  name: 'grafana'
  params: {
    name: grafanaName
    adminObjectId: grafanaAdminObjectId
    location: location
    azureMonitorWorkspaceId: amw.id
    tags: commonTags
  }
}

// Dedicated storage for the App Service archive-to-blob diag setting, co-located with
// the App Service in westeurope (storage diag destinations must match the source region).
module appDiagStorage '../modules/storage-account.bicep' = {
  name: 'app-diag-storage'
  params: {
    name: appDiagStorageName
    location: appServiceLocation
    centralLawId: lawCentral.id
    tags: commonTags
  }
}

module appService '../modules/appservice.bicep' = {
  name: 'appservice'
  params: {
    planName: appPlanName
    webAppName: webAppName
    location: appServiceLocation
    appInsightsConnectionString: appInsights.properties.ConnectionString
    appInsightsInstrumentationKey: appInsights.properties.InstrumentationKey
    centralLawId: lawCentral.id
    diagStorageAccountId: appDiagStorage.outputs.id
    diagEventHubAuthRuleId: eventHubAuthRule.id
    diagEventHubName: 'diagstream'
    enableSlotFailureScenario: enableSlotFailureScenario
    tags: commonTags
  }
}

module customerWebApp '../modules/customer-webapp.bicep' = if (enableSlotFailureScenario) {
  name: 'customer-webapp'
  params: {
    webAppName: customerWebAppName
    location: appServiceLocation
    serverFarmResourceId: appService.outputs.planId
    appInsightsConnectionString: appInsights.properties.ConnectionString
    appInsightsInstrumentationKey: appInsights.properties.InstrumentationKey
    centralLawId: lawCentral.id
    tags: commonTags
  }
}

module consolePlatform '../modules/lab-console-platform.bicep' = {
  name: 'lab-console-platform'
  params: {
    webAppName: appService.outputs.webAppName
    centralLawId: lawCentral.id
    location: appServiceLocation
    tags: commonTags
    cpuVmNames: deployLinuxVm && deployWindowsVm ? [vmLinux!.outputs.vmName, vmWindows!.outputs.vmName] : []
    enableSlotFailureScenario: enableSlotFailureScenario
    customerWebAppName: enableSlotFailureScenario ? customerWebApp!.outputs.webAppName : ''
  }
}

module consoleCustomLogs '../modules/custom-logs.bicep' = {
  name: 'custom-logs'
  params: {
    namePrefix: namePrefix
    location: location
    centralLawId: lawCentral.id
    centralLawName: lawCentralName
    tags: commonTags
  }
}

module connectionMonitor '../modules/connection-monitor.bicep' = {
  scope: resourceGroup(subscription().subscriptionId, 'NetworkWatcherRG')
  name: 'connection-monitor'
  params: {
    location: location
    centralLawId: lawCentral.id
    linuxVmId: deployLinuxVm ? vmLinux.outputs.vmId : ''
    windowsVmId: deployWindowsVm ? vmWindows.outputs.vmId : ''
    appServiceHost: appService.outputs.defaultHost
    tags: commonTags
  }
}

module flowLogs '../modules/flow-logs.bicep' = {
  scope: resourceGroup(subscription().subscriptionId, 'NetworkWatcherRG')
  name: 'flow-logs'
  params: {
    name: 'fl-${namePrefix}'
    location: location
    targetVnetId: resourceId('Microsoft.Network/virtualNetworks', vnetName)
    networkWatcherId: connectionMonitor.outputs.networkWatcherId
    storageAccountId: storageAccount.id
    centralLawId: lawCentral.id
    centralLawRegion: location
    centralLawCustomerId: lawCentral.properties.customerId
    retentionDays: 7
    tags: commonTags
  }
}

output webAppName string = appService.outputs.webAppName
output customerWebAppName string = enableSlotFailureScenario ? customerWebApp!.outputs.webAppName : ''
output customerWebAppDefaultHost string = enableSlotFailureScenario ? customerWebApp!.outputs.defaultHost : ''
