@description('Central LAW name.')
param workspaceName string

@description('Central LAW resource ID.')
param workspaceId string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

module onboarding 'sentinel-onboarding.bicep' = {
  params: {
    workspaceName: workspaceName
    workspaceId: workspaceId
    location: location
    tags: tags
  }
}

module analyticsRule 'sentinel-rule.bicep' = {
  params: {
    workspaceName: workspaceName
  }
  dependsOn: [ onboarding ]
}

output sentinelOnboarded bool = true
output ruleName string = analyticsRule.outputs.ruleName
