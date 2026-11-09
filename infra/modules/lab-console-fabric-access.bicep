@description('Existing lab F2 capacity name.')
@minLength(3)
param capacityName string

@description('Lab Operations runner managed identity principal ID.')
param principalId string

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' existing = {
  name: capacityName
}

resource resumeRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'lab-console-fabric-resume-role')
  properties: {
    roleName: 'Lab Console Fabric Resume ${take(uniqueString(resourceGroup().id), 8)}'
    description: 'Read and resume the lab Fabric capacity; assigned only on that capacity.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.Fabric/capacities/read'
          'Microsoft.Fabric/capacities/resume/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource resumeAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(capacity.id, principalId, resumeRole.id)
  scope: capacity
  properties: {
    roleDefinitionId: resumeRole.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
