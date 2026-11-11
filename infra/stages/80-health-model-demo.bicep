targetScope = 'resourceGroup'

@description('Region of the Cafe workload. Must be supported by App Service.')
param location string = 'swedencentral'
@description('CloudHealth-supported model region.')
param healthModelLocation string = 'swedencentral'
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'
param deployLinuxVm bool = true
param deployWindowsVm bool = true
@description('The exact core Control Center Web App resource ID, never the Cafe site.')
param webAppId string = resourceId('Microsoft.Web/sites', 'app-${namePrefix}-${take(uniqueString(resourceGroup().id), 5)}')
param appInsightsWorkspaceId string = resourceId('Microsoft.OperationalInsights/workspaces', 'law-${namePrefix}-appinsights-${take(uniqueString(resourceGroup().id), 5)}')
param centralWorkspaceId string = resourceId('Microsoft.OperationalInsights/workspaces', 'law-${namePrefix}-central-${take(uniqueString(resourceGroup().id), 5)}')
param monitorWorkspaceId string = resourceId('Microsoft.Monitor/accounts', 'amw-${namePrefix}')
param aksId string = resourceId('Microsoft.ContainerService/managedClusters', 'aks-${namePrefix}')
param vmssId string = resourceId('Microsoft.Compute/virtualMachineScaleSets', 'vmss-${namePrefix}')
@description('Name of the console availability test deployed by Stage E. One-shot main passes its own test name explicitly.')
param availabilityTestName string = 'test-${namePrefix}-app'
param vmIds array = concat(
  deployLinuxVm ? [resourceId('Microsoft.Compute/virtualMachines', 'vm-${namePrefix}-lin')] : [],
  deployWindowsVm ? [resourceId('Microsoft.Compute/virtualMachines', 'vmwin${take(uniqueString(resourceGroup().id), 4)}')] : []
)
param actionGroupId string = resourceId('Microsoft.Insights/actionGroups', 'ag-${namePrefix}-email')
param tags object = {}
@description('Optional existing Cafe RG Monitoring Reader assignment GUID. Empty uses non-conflicting resource-scoped read access.')
param cafeMonitoringReaderAssignmentName string = ''

module workload '../healthmodel-tutorial/workload.bicep' = {
  name: 'health-model-demo-cafe-workload'
  params: {
    location: location
    // Independent of the core prefix, for adoption of the standalone tutorial.
    namePrefix: 'cafe'
    tags: union(tags, { workload: 'lab-cafe', purpose: 'health-model-tutorial' })
  }
}

module flows '../healthmodel-lab/main.bicep' = {
  name: 'health-model-demo-flows'
  params: {
    healthModelName: 'hm-amlab-flows'
    location: healthModelLocation
    webAppId: webAppId
    appInsightsWorkspaceId: appInsightsWorkspaceId
    centralWorkspaceId: centralWorkspaceId
    monitorWorkspaceId: monitorWorkspaceId
    aksId: aksId
    vmssId: vmssId
    availabilityTestName: availabilityTestName
    vmIds: vmIds
    actionGroupId: actionGroupId
    tags: tags
  }
}

module cafe '../healthmodel-tutorial/model.bicep' = {
  name: 'health-model-demo-cafe'
  params: {
    healthModelName: 'hm-lab-cafe'
    location: healthModelLocation
    webAppId: workload.outputs.webAppId
    storageId: workload.outputs.storageAccountId
    workspaceId: workload.outputs.logAnalyticsWorkspaceId
    actionGroupId: actionGroupId
    controlCenterWebAppId: webAppId
    reporterRoleDefinitionId: flows.outputs.reporterRoleDefinitionId
    monitoringReaderAssignmentName: cafeMonitoringReaderAssignmentName
    tags: tags
  }
}

output healthModelDemoCafeWebAppName string = workload.outputs.webAppName
output healthModelDemoCafeWebAppUrl string = workload.outputs.webAppUrl
output healthModelDemoCafeModelName string = 'hm-lab-cafe'
output healthModelDemoFlowModelName string = 'hm-amlab-flows'
