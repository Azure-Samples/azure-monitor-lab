// =====================================================================================
// Stage Fabric (optional) - Microsoft Fabric F2 capacity.
//
// The capacity is pinned to swedencentral and bills while active. Fabric workspace and
// Real-Time Intelligence items are tenant-scoped SaaS objects created afterward by
// scripts/setup-fabric.ps1.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Administrator UPN for the Fabric capacity.')
param fabricAdminEmail string

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var fabricCapacityName = toLower('fab${namePrefix}${take(suffix, 8)}')
var fabricLocation = 'swedencentral'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-demo-lab'
  costCenter: 'demo'
  costWarning: 'F2-about-USD-0.36-per-hour-while-active'
}

module fabricCapacity '../modules/fabric-capacity.bicep' = {
  name: 'fabric-capacity'
  params: {
    name: fabricCapacityName
    location: fabricLocation
    administrators: [ fabricAdminEmail ]
    tags: commonTags
  }
}

output fabricCapacityId string = fabricCapacity.outputs.id
output fabricCapacityName string = fabricCapacity.outputs.name
output fabricCapacityLocation string = fabricCapacity.outputs.location
output fabricCapacitySku string = fabricCapacity.outputs.sku
