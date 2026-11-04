targetScope = 'resourceGroup'

@description('Scoped dependencies and dedicated customer Health Model for the existing customer app; does not redeploy other lab workloads.')
param enableCustomerDependencies bool = true
param namePrefix string = 'amlab'
param location string = 'westeurope'
param appInsightsName string
param centralLawId string
param sqlEntraAdminObjectId string
param sqlEntraAdminName string
@allowed(['User', 'Group', 'Application'])
param sqlEntraAdminType string
param tags object = {
  purpose: 'azure-monitor-lab'
  owner: 'demo-lab'
  costCenter: 'demo'
}

var suffix = uniqueString(resourceGroup().id)
var customerName = 'app-${namePrefix}-${take(suffix, 5)}-customer'

module dependencies 'modules/customer-dependencies.bicep' = if (enableCustomerDependencies) {
  name: 'customer-dependencies'
  params: {
    namePrefix: namePrefix
    suffix: suffix
    location: location
    centralLawId: centralLawId
    appInsightsName: appInsightsName
    sqlEntraAdminObjectId: sqlEntraAdminObjectId
    sqlEntraAdminName: sqlEntraAdminName
    sqlEntraAdminType: sqlEntraAdminType
    tags: tags
  }
}

module customerHealthModel 'modules/customer-health-model.bicep' = if (enableCustomerDependencies) {
  name: 'customer-health-model'
  params: {
    namePrefix: namePrefix
    location: 'swedencentral'
    customerWebAppId: resourceId('Microsoft.Web/sites', customerName)
    customerAppServicePlanId: resourceId('Microsoft.Web/serverfarms', 'plan-${namePrefix}')
    customerSqlDatabaseId: dependencies!.outputs.sqlDatabaseId
    customerServiceBusId: dependencies!.outputs.serviceBusNamespaceId
    customerWorkerId: dependencies!.outputs.workerId
    customerWorkerStorageId: dependencies!.outputs.workerStorageId
    customerCentralLawId: centralLawId
    tags: tags
  }
}

output customerWebAppName string = customerName
output webAppName string = 'app-${namePrefix}-${take(suffix, 5)}'
output customerDependencies object = enableCustomerDependencies ? union(dependencies!.outputs.customerDependencies, {
  healthModelName: customerHealthModel!.outputs.healthModelName
  healthModelId: customerHealthModel!.outputs.healthModelId
  healthModelPrincipalId: customerHealthModel!.outputs.healthModelPrincipalId
}) : { enabled: false }
output customerIdentityId string = enableCustomerDependencies ? dependencies!.outputs.customerIdentityId : ''
output customerSubnetId string = enableCustomerDependencies ? dependencies!.outputs.customerSubnetId : ''
output customerSettings object = enableCustomerDependencies ? dependencies!.outputs.customerSettings : { CustomerDependencies__Enabled: 'false' }
