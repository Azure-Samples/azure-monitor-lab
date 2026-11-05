@description('Globally unique Microsoft Fabric capacity name.')
@minLength(3)
@maxLength(63)
param name string

@description('Fabric capacity region. The lab pins this to swedencentral.')
param location string = 'swedencentral'

@description('Fabric capacity SKU. F2 is the smallest paid Fabric capacity.')
@allowed([
  'F2'
])
param skuName string = 'F2'

@description('User principal names that administer the Fabric capacity.')
@minLength(1)
param administrators array

@description('Resource tags.')
param tags object = {}

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'Fabric'
  }
  properties: {
    administration: {
      members: administrators
    }
  }
}

output id string = capacity.id
output name string = capacity.name
output location string = capacity.location
output sku string = capacity.sku.name
