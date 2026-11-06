param healthModelName string
param principalId string
param roleDefinitionId string

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-11-01' existing = {
  name: healthModelName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(healthModel.id, principalId, roleDefinitionId)
  scope: healthModel
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
