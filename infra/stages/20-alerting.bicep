targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Email address that receives Action Group notifications.')
param alertEmail string

@description('Optional secondary SIEM webhook URL added to the Action Group.')
@secure()
param siemWebhookUrl string = ''

@description('Admin username for VMSS.')
param vmAdminUsername string = 'azureuser'

@description('Admin password for VMSS.')
@secure()
param vmAdminPassword string

@description('Deploy the Windows demo VM.')
param deployWindowsVm bool = true

@description('Deploy the Linux demo VM.')
param deployLinuxVm bool = true

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var appInsightsName = 'appi-${namePrefix}-${take(suffix, 5)}'
var linuxVmName = 'vm-${namePrefix}-lin'
var windowsVmName = 'vmwin${take(suffix, 4)}'
var aksName = 'aks-${namePrefix}'
var appPlanName = 'plan-${namePrefix}'
var webAppName = 'app-${namePrefix}-${take(suffix, 5)}'
var actionGroupName = 'ag-${namePrefix}-email'
var vmssName = 'vmss-${namePrefix}'
var vnetName = 'vnet-${namePrefix}'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// App Service (Stage B) is pinned to westeurope; metric alerts targeting the web app /
// plan must declare that region as targetResourceRegion.
var appServiceLocation = 'westeurope'

var workloadSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-workload')

resource lawCentral 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawCentralName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' existing = {
  name: aksName
}

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource appPlan 'Microsoft.Web/serverfarms@2023-12-01' existing = {
  name: appPlanName
}

resource vmLinux 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployLinuxVm) {
  name: linuxVmName
}

resource vmWindows 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployWindowsVm) {
  name: windowsVmName
}

module automitigation '../modules/automitigation-logicapp.bicep' = {
  name: 'automitigation-logicapp'
  params: {
    name: 'la-${namePrefix}-automitigate'
    location: location
    tags: commonTags
  }
}

module actionGroup '../modules/actiongroup.bicep' = {
  name: 'actiongroup'
  params: {
    name: actionGroupName
    email: alertEmail
    webhookUrl: automitigation.outputs.callbackUrl
    siemWebhookUrl: siemWebhookUrl
    tags: commonTags
  }
}

module alerts '../modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    location: location
    actionGroupId: actionGroup.outputs.id
    aksId: aks.id
    webAppId: webApp.id
    webAppRegion: appServiceLocation
    appInsightsId: appInsights.id
    linuxVmId: deployLinuxVm ? vmLinux.id : ''
    windowsVmId: deployWindowsVm ? vmWindows.id : ''
    tags: commonTags
  }
}

module amba '../modules/amba.bicep' = {
  name: 'amba'
  params: {
    actionGroupId: actionGroup.outputs.id
    vmIds: concat(deployLinuxVm ? [ vmLinux.id ] : [], deployWindowsVm ? [ vmWindows.id ] : [])
    webAppId: webApp.id
    aksId: aks.id
    appPlanId: appPlan.id
    location: location
    webAppRegion: appServiceLocation
    tags: commonTags
  }
}

module healthAlerts '../modules/health-alerts.bicep' = {
  name: 'health-alerts'
  params: {
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

module alertProcessingRules '../modules/alert-processing-rules.bicep' = {
  name: 'alert-processing-rules'
  params: {
    namePrefix: namePrefix
    resourceGroupId: resourceGroup().id
    primaryActionGroupId: actionGroup.outputs.id
    vmIds: concat(deployLinuxVm ? [ vmLinux.id ] : [], deployWindowsVm ? [ vmWindows.id ] : [])
    tags: commonTags
  }
}

module vmss '../modules/vmss.bicep' = {
  name: 'vmss'
  params: {
    name: vmssName
    location: location
    vmSize: 'Standard_B1s'
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: workloadSubnetId
    tags: commonTags
  }
}
