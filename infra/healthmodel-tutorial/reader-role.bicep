param principalId string
param assignmentName string = ''
param webAppId string
param storageId string
param workspaceId string

var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(assignmentName)) {
  name: assignmentName
  properties: {
    principalId: principalId
    roleDefinitionId: roleId
    principalType: 'ServicePrincipal'
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' existing = {
  name: last(split(webAppId, '/'))
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageId, '/'))
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(workspaceId, '/'))
}

// Different scopes from the standalone script's RG assignment, so adopting its
// model never attempts to recreate an existing assignment under another GUID.
resource siteReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(assignmentName)) {
  name: guid(webAppId, principalId, roleId)
  scope: site
  properties: {
    principalId: principalId
    roleDefinitionId: roleId
    principalType: 'ServicePrincipal'
  }
}

resource storageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(assignmentName)) {
  name: guid(storageId, principalId, roleId)
  scope: storage
  properties: {
    principalId: principalId
    roleDefinitionId: roleId
    principalType: 'ServicePrincipal'
  }
}

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(assignmentName)) {
  name: guid(workspaceId, principalId, roleId)
  scope: workspace
  properties: {
    principalId: principalId
    roleDefinitionId: roleId
    principalType: 'ServicePrincipal'
  }
}
