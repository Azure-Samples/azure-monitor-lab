@description('Deterministic name prefix shared with the dedicated customer app.')
param namePrefix string
param suffix string
param location string
param centralLawId string
param appInsightsName string
param sqlEntraAdminObjectId string
param sqlEntraAdminName string
@allowed(['User', 'Group', 'Application'])
param sqlEntraAdminType string = 'Group'
param tags object = {}

var sqlName = 'sql-${namePrefix}-${take(suffix, 8)}'
var busName = 'sb-${namePrefix}-${take(suffix, 8)}'
var storageName = 'storders${namePrefix}${take(suffix, 8)}'
var networkName = 'vnet-${namePrefix}-customer'
var functionName = 'func-${namePrefix}-${take(suffix, 8)}-orders'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageSubresources = ['blob', 'queue']

module customerIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'customer-dependency-identity'
  params: {
    name: 'id-${namePrefix}-customer'
    location: location
    enableTelemetry: false
    tags: tags
  }
}

module workerIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'orders-processor-identity'
  params: {
    name: 'id-${namePrefix}-orders'
    location: location
    enableTelemetry: false
    tags: tags
  }
}

// SQL and processor storage are reached privately by both integrated runtimes.
module network 'br/public:avm/res/network/virtual-network:0.10.0' = {
  name: 'customer-dependency-network'
  params: {
    name: networkName
    location: location
    addressPrefixes: ['10.61.0.0/24']
    subnets: [
      { name: 'customer', addressPrefix: '10.61.0.0/26', delegation: 'Microsoft.Web/serverFarms' }
      { name: 'processor', addressPrefix: '10.61.0.64/26', delegation: 'Microsoft.App/environments' }
      { name: 'private-endpoints', addressPrefix: '10.61.0.128/26', privateEndpointNetworkPolicies: 'Disabled' }
    ]
    enableTelemetry: false
    tags: tags
  }
}

// AVM SQL server currently exposes password-auth fields; this declaration
// deliberately excludes that path entirely, including in compiled templates.
resource sql 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlEntraAdminName
      sid: sqlEntraAdminObjectId
      tenantId: subscription().tenantId
      principalType: sqlEntraAdminType
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sql
  name: 'customer-orders'
  location: location
  tags: tags
  sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
  properties: {
    maxSizeBytes: 2147483648
    collation: 'SQL_Latin1_General_CP1_CI_AS'
  }
}

module sqlDns 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'customer-sql-dns'
  params: {
    name: 'privatelink.database.windows.net'
    virtualNetworkLinks: [
      { virtualNetworkResourceId: network.outputs.resourceId, registrationEnabled: false }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module sqlEndpoint 'br/public:avm/res/network/private-endpoint:0.12.0' = {
  name: 'customer-sql-private-endpoint'
  params: {
    name: 'pe-${namePrefix}-customer-sql'
    location: location
    subnetResourceId: '${network.outputs.resourceId}/subnets/private-endpoints'
    privateLinkServiceConnections: [
      { name: 'sql', properties: { privateLinkServiceId: sql.id, groupIds: ['sqlServer'] } }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        { name: 'sql', privateDnsZoneResourceId: sqlDns.outputs.resourceId }
      ]
    }
    enableTelemetry: false
    tags: tags
  }
}

module bus 'br/public:avm/res/service-bus/namespace:0.17.0' = {
  name: 'customer-orders-bus'
  params: {
    name: busName
    location: location
    skuObject: { name: 'Standard', capacity: 0 }
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    queues: [
      {
        name: 'orders'
        requiresDuplicateDetection: true
        duplicateDetectionHistoryTimeWindow: 'PT10M'
        maxDeliveryCount: 5
        maxSizeInMegabytes: 1024
        defaultMessageTimeToLive: 'PT1H'
        deadLetteringOnMessageExpiration: true
        lockDuration: 'PT1M'
        roleAssignments: [
          {
            principalId: customerIdentity.outputs.principalId
            principalType: 'ServicePrincipal'
            roleDefinitionIdOrName: '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
          }
          {
            principalId: workerIdentity.outputs.principalId
            principalType: 'ServicePrincipal'
            roleDefinitionIdOrName: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
          }
        ]
      }
    ]
    diagnosticSettings: [
      {
        name: 'send-to-central-law'
        workspaceResourceId: centralLawId
        logCategoriesAndGroups: [{ category: 'OperationalLogs', enabled: true }]
        metricCategories: [{ category: 'AllMetrics', enabled: true }]
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'orders-processor-storage'
  params: {
    name: storageName
    location: location
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    blobServices: {
      containers: [{ name: 'deployment', publicAccess: 'None' }]
      diagnosticSettings: [
        {
          name: 'send-to-central-law'
          workspaceResourceId: centralLawId
          logCategoriesAndGroups: [
            { category: 'StorageRead', enabled: true }
            { category: 'StorageWrite', enabled: true }
            { category: 'StorageDelete', enabled: true }
          ]
          metricCategories: [{ category: 'AllMetrics', enabled: true }]
        }
      ]
    }
    roleAssignments: [
      { principalId: workerIdentity.outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: blobOwner }
      { principalId: workerIdentity.outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: queueContributor }
    ]
    diagnosticSettings: [
      {
        name: 'send-to-central-law'
        workspaceResourceId: centralLawId
        metricCategories: [{ category: 'AllMetrics', enabled: true }]
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module storageDns 'br/public:avm/res/network/private-dns-zone:0.8.0' = [for service in storageSubresources: {
  name: 'customer-storage-${service}-dns'
  params: {
    name: 'privatelink.${service}.core.windows.net'
    virtualNetworkLinks: [
      { virtualNetworkResourceId: network.outputs.resourceId, registrationEnabled: false }
    ]
    enableTelemetry: false
    tags: tags
  }
}]

module storageEndpoints 'br/public:avm/res/network/private-endpoint:0.12.0' = [for (service, index) in storageSubresources: {
  name: 'customer-storage-${service}-private-endpoint'
  params: {
    name: 'pe-${namePrefix}-orders-${service}'
    location: location
    subnetResourceId: '${network.outputs.resourceId}/subnets/private-endpoints'
    privateLinkServiceConnections: [
      { name: service, properties: { privateLinkServiceId: storage.outputs.resourceId, groupIds: [service] } }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        { name: service, privateDnsZoneResourceId: storageDns[index].outputs.resourceId }
      ]
    }
    enableTelemetry: false
    tags: tags
  }
}]

module processor './customer-functions.bicep' = {
  name: 'customer-orders-processor'
  params: {
    name: functionName
    location: location
    identityId: workerIdentity.outputs.resourceId
    identityClientId: workerIdentity.outputs.clientId
    storageAccountName: storage.outputs.name
    virtualNetworkSubnetId: '${network.outputs.resourceId}/subnets/processor'
    appInsightsName: appInsightsName
    centralLawId: centralLawId
    appSettings: {
      CustomerDependencies__Enabled: 'true'
      CustomerDependencies__SqlConnectionString: 'Server=tcp:${sqlName}.database.windows.net,1433;Database=${database.name};Authentication=Active Directory Managed Identity;User Id=${workerIdentity.outputs.clientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=15;'
      CustomerDependencies__ServiceBusNamespace: '${busName}.servicebus.windows.net'
      CustomerDependencies__QueueName: 'orders'
      CustomerOrdersQueueName: 'orders'
      CustomerDependencies__ManagedIdentityClientId: workerIdentity.outputs.clientId
      CustomerDependencies__FailProcessing: 'false'
      OrdersBus__fullyQualifiedNamespace: '${busName}.servicebus.windows.net'
      OrdersBus__credential: 'managedidentity'
      OrdersBus__clientId: workerIdentity.outputs.clientId
    }
    tags: tags
  }
  dependsOn: [sqlEndpoint, storageEndpoints, bus]
}

resource sqlDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-central-law'
  scope: database
  properties: {
    workspaceId: centralLawId
    logs: [
      { category: 'Errors', enabled: true }
      { category: 'Timeouts', enabled: true }
      { category: 'Blocks', enabled: true }
      { category: 'Deadlocks', enabled: true }
      { category: 'SQLInsights', enabled: true }
    ]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output customerIdentityId string = customerIdentity.outputs.resourceId
output customerIdentityClientId string = customerIdentity.outputs.clientId
output customerIdentityPrincipalId string = customerIdentity.outputs.principalId
output workerIdentityClientId string = workerIdentity.outputs.clientId
output workerIdentityId string = workerIdentity.outputs.resourceId
output workerIdentityPrincipalId string = workerIdentity.outputs.principalId
output customerSubnetId string = '${network.outputs.resourceId}/subnets/customer'
output sqlServerName string = sql.name
output sqlServerId string = sql.id
output sqlDatabaseName string = database.name
output sqlDatabaseId string = database.id
output serviceBusNamespace string = '${busName}.servicebus.windows.net'
output serviceBusNamespaceId string = bus.outputs.resourceId
output queueName string = 'orders'
output workerName string = processor.outputs.name
output workerId string = processor.outputs.id
output workerStorageId string = storage.outputs.resourceId
output customerDependencies object = {
  enabled: true
  sqlServerName: sql.name
  sqlServerId: sql.id
  sqlDatabaseName: database.name
  sqlDatabaseId: database.id
  serviceBusNamespace: '${busName}.servicebus.windows.net'
  serviceBusNamespaceId: bus.outputs.resourceId
  queueName: 'orders'
  workerName: processor.outputs.name
  workerId: processor.outputs.id
  workerStorageId: storage.outputs.resourceId
  customerIdentityId: customerIdentity.outputs.resourceId
  customerIdentityClientId: customerIdentity.outputs.clientId
  customerIdentityPrincipalId: customerIdentity.outputs.principalId
  workerIdentityClientId: workerIdentity.outputs.clientId
  workerIdentityId: workerIdentity.outputs.resourceId
  workerIdentityPrincipalId: workerIdentity.outputs.principalId
}
output customerSettings object = {
  CustomerDependencies__Enabled: 'true'
  CustomerDependencies__SqlConnectionString: 'Server=tcp:${sqlName}.database.windows.net,1433;Database=${database.name};Authentication=Active Directory Managed Identity;User Id=${customerIdentity.outputs.clientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=15;'
  CustomerDependencies__ServiceBusNamespace: '${busName}.servicebus.windows.net'
  CustomerDependencies__QueueName: 'orders'
  CustomerDependencies__ManagedIdentityClientId: customerIdentity.outputs.clientId
  CustomerDependencies__SqlDelaySeconds: '0'
}
