@description('Central LAW name.')
param workspaceName string

@description('Central LAW resource ID.')
param workspaceId string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

resource sentinelSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${workspaceName})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: workspaceId
  }
  plan: {
    name: 'SecurityInsights(${workspaceName})'
    product: 'OMSGallery/SecurityInsights'
    publisher: 'Microsoft'
    promotionCode: ''
  }
}

resource lawRef 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource sentinelOnboarding 'Microsoft.SecurityInsights/onboardingStates@2024-09-01' = {
  scope: lawRef
  name: 'default'
  properties: {}
  dependsOn: [ sentinelSolution ]
}

output sentinelOnboarded bool = true
