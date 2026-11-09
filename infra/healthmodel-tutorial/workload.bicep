// =============================================================================
// Lab Café: the workload the health model tutorial watches.
//
//   App Service (Linux, Node)  -> serves the menu page and the order API
//   Storage account            -> menu blob, order blobs, barista queue, reached over
//                                 private endpoints (many enterprise subscriptions
//                                 enforce private storage by policy)
//   Application Insights + LAW -> request and storage-call telemetry
//   2 availability tests       -> a synthetic customer browses and orders every 5 min,
//                                 so every signal has data even when nobody else visits
//
// Deployed by scripts/deploy-healthmodel-tutorial.ps1. See docs/HEALTH-MODEL-TUTORIAL.md.
// =============================================================================

@description('Region for every resource in the tutorial.')
param location string = resourceGroup().location

@description('Short prefix for resource names.')
@maxLength(8)
param namePrefix string = 'cafe'

@description('Resource tags.')
param tags object = {
  workload: 'lab-cafe'
  purpose: 'health-model-tutorial'
}

var suffix = uniqueString(resourceGroup().id)
var webAppName = 'app-${namePrefix}-${suffix}'
var storageName = take('st${namePrefix}${suffix}', 24)

// Storage Blob Data Contributor, Storage Queue Data Message Sender
var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var queueSenderRoleId = 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a'

// Synthetic customers run from three European test locations.
var testLocations = [
  { Id: 'emea-se-sto-edge' } // Sweden Central
  { Id: 'emea-nl-ams-azr' }  // West Europe
  { Id: 'emea-gb-db3-azr' }  // UK South
]

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${namePrefix}-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${namePrefix}-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// The web app reaches storage through the VNet: app subnet -> private endpoints.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.42.0.0/16' ] }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.42.1.0/24'
          delegations: [
            { name: 'web', properties: { serviceName: 'Microsoft.Web/serverFarms' } }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: { addressPrefix: '10.42.2.0/24' }
      }
    ]
  }
}

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for service in [ 'blob', 'queue' ]: {
    name: 'pe-${storage.name}-${service}'
    location: location
    tags: tags
    properties: {
      subnet: { id: vnet.properties.subnets[1].id }
      privateLinkServiceConnections: [
        {
          name: service
          properties: {
            privateLinkServiceId: storage.id
            groupIds: [ service ]
          }
        }
      ]
    }
  }
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for service in [ 'blob', 'queue' ]: {
    name: 'privatelink.${service}.${environment().suffixes.storage}'
    location: 'global'
    tags: tags
  }
]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (service, i) in [ 'blob', 'queue' ]: {
    parent: dnsZones[i]
    name: 'link-${vnet.name}'
    location: 'global'
    properties: {
      virtualNetwork: { id: vnet.id }
      registrationEnabled: false
    }
  }
]

resource dnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (service, i) in [ 'blob', 'queue' ]: {
    parent: privateEndpoints[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        { name: service, properties: { privateDnsZoneId: dnsZones[i].id } }
      ]
    }
  }
]

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource menuContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'menu'
}

resource ordersContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'orders'
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource orderEvents 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'order-events'
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${namePrefix}-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: vnet.properties.subnets[0].id
    vnetRouteAllEnabled: true
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts'
      appCommandLine: 'node server.js'
      alwaysOn: true
      healthCheckPath: '/healthz'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'STORAGE_ACCOUNT_NAME', value: storage.name }
        { name: 'CHAOS_ORDER_FAILURE_PERCENT', value: '0' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
      ]
    }
  }
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, site.id, blobContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, site.id, queueSenderRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueSenderRoleId)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Synthetic customer 1: opens the menu page.
resource browseTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'synthetic-browse-menu'
  location: location
  tags: union(tags, { 'hidden-link:${appi.id}': 'Resource' })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: 'synthetic-browse-menu'
    Name: 'synthetic-browse-menu'
    Description: 'A synthetic customer opens the café menu every 5 minutes.'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: false
    Locations: testLocations
    Request: {
      RequestUrl: 'https://${site.properties.defaultHostName}/'
      HttpVerb: 'GET'
      ParseDependentRequests: false
      FollowRedirects: true
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: false
    }
  }
}

// Synthetic customer 2: orders a flat white.
resource orderTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'synthetic-order-coffee'
  location: location
  tags: union(tags, { 'hidden-link:${appi.id}': 'Resource' })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: 'synthetic-order-coffee'
    Name: 'synthetic-order-coffee'
    Description: 'A synthetic customer orders a flat white every 5 minutes.'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: false
    Locations: testLocations
    Request: {
      RequestUrl: 'https://${site.properties.defaultHostName}/api/orders'
      HttpVerb: 'POST'
      RequestBody: base64('{"item":"flat-white"}')
      Headers: [
        { key: 'Content-Type', value: 'application/json' }
      ]
      ParseDependentRequests: false
      FollowRedirects: true
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 201
      SSLCheck: false
    }
  }
}

output appSubnetId string = vnet.properties.subnets[0].id
output webAppName string = site.name
output webAppId string = site.id
output webAppUrl string = 'https://${site.properties.defaultHostName}'
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output logAnalyticsWorkspaceId string = law.id
output appInsightsName string = appi.name
