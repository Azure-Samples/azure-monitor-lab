param monitorWorkspaceName string
param principalId string
param roleDefinitionId string

resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: monitorWorkspaceName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitorWorkspace.id, principalId, roleDefinitionId)
  scope: monitorWorkspace
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
