@description('Existing lab Fabric capacity name. The identity can act only on this capacity.')
param capacityName string

param location string

@minValue(0)
@maxValue(23)
param hourUtc int

@minValue(0)
@maxValue(59)
param minuteUtc int

@description('First scheduled run, strictly in the future, in UTC ISO 8601 format.')
param firstRunUtc string

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' existing = {
  name: capacityName
}

var capacityUrl = uri(environment().resourceManager, capacity.id)
var roleName = guid(resourceGroup().id, capacity.id, 'fabric-auto-suspend-role')

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${capacityName}-auto-suspend'
  location: location
  tags: {
    purpose: 'Azure Monitor Lab opt-in daily Fabric suspension'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        Daily_UTC: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Day'
            interval: 1
            startTime: firstRunUtc
            timeZone: 'UTC'
            schedule: {
              hours: [ hourUtc ]
              minutes: [ minuteUtc ]
            }
          }
        }
      }
      actions: {
        Read_capacity: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: '${capacityUrl}?api-version=2023-11-01'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
          }
          runAfter: {}
        }
        Suspend_if_active: {
          type: 'If'
          expression: {
            equals: [
              '@body(\'Read_capacity\')?[\'properties\']?[\'state\']'
              'Active'
            ]
          }
          actions: {
            Suspend: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: '${capacityUrl}/suspend?api-version=2023-11-01'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: environment().resourceManager
                }
              }
            }
            Await_suspension: {
              type: 'Until'
              operationOptions: 'FailWhenLimitsReached'
              expression: '@or(equals(body(\'Read_suspended_capacity\')?[\'properties\']?[\'state\'], \'Suspended\'), equals(body(\'Read_suspended_capacity\')?[\'properties\']?[\'state\'], \'Paused\'))'
              limit: {
                count: 60
                timeout: 'PT10M'
              }
              actions: {
                Wait_for_state: {
                  type: 'Wait'
                  inputs: {
                    interval: { count: 10, unit: 'Second' }
                  }
                }
                Read_suspended_capacity: {
                  type: 'Http'
                  inputs: {
                    method: 'GET'
                    uri: '${capacityUrl}?api-version=2023-11-01'
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: environment().resourceManager
                    }
                  }
                  runAfter: {
                    Wait_for_state: [ 'Succeeded' ]
                  }
                }
              }
              runAfter: {
                Suspend: [ 'Succeeded' ]
              }
            }
          }
          else: {
            actions: {
              Capacity_not_active: {
                type: 'Compose'
                inputs: '@concat(\'Capacity was not suspended because its state is: \', body(\'Read_capacity\')?[\'properties\']?[\'state\'])'
              }
            }
          }
          runAfter: {
            Read_capacity: [ 'Succeeded' ]
          }
        }
      }
    }
  }
}

resource suspendRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleName
  properties: {
    roleName: 'Azure Monitor Lab Fabric Suspend ${take(uniqueString(capacity.id), 8)}'
    description: 'Read and suspend the single lab Fabric capacity. No resume, write, or data permissions.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Fabric/capacities/read'
          'Microsoft.Fabric/capacities/suspend/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [ resourceGroup().id ]
  }
}

resource suspendAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(capacity.id, workflow.id, suspendRole.id)
  scope: capacity
  properties: {
    roleDefinitionId: suspendRole.id
    principalId: workflow.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
