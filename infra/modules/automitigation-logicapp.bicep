// =====================================================================================
// FEATURE 5 — Auto-mitigation Logic App
//
// Consumption-tier Logic App with a system-assigned managed identity.
//
// Trigger:  HTTP webhook (Common Alert Schema). Wired to the existing Action Group
//           via a webhook receiver (see actiongroup.bicep).
// Workflow:
//   1. Parse the inbound alert (Common Alert Schema).
//   2. If alertTargetIDs[0] is a VM → call ARM `start` on it.
//   3. Otherwise → no-op (logs the payload).
//
// Identity: System-assigned. Granted a custom VM-start role only on the
//           configured Linux and Windows demo VMs.
// =====================================================================================

@description('Logic App name.')
param name string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Resource ID of the optional Linux demo VM.')
param linuxVmId string = ''

@description('Resource ID of the optional Windows demo VM.')
param windowsVmId string = ''

var vmStartRoleName = 'Azure Monitor Lab VM Start'

resource linuxVm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (!empty(linuxVmId)) {
  name: last(split(linuxVmId, '/'))
}

resource windowsVm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (!empty(windowsVmId)) {
  name: last(split(windowsVmId, '/'))
}

// ---------------------------------------------------------------------------------
// Logic App workflow (Consumption)
// ---------------------------------------------------------------------------------
resource logic 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
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
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                schemaId: { type: 'string' }
                data: {
                  type: 'object'
                  properties: {
                    essentials: {
                      type: 'object'
                      properties: {
                        alertId: { type: 'string' }
                        alertRule: { type: 'string' }
                        severity: { type: 'string' }
                        signalType: { type: 'string' }
                        monitorCondition: { type: 'string' }
                        alertTargetIDs: { type: 'array' }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      actions: {
        Parse_target: {
          type: 'Compose'
          inputs: '@first(triggerBody()?[\'data\']?[\'essentials\']?[\'alertTargetIDs\'])'
          runAfter: {}
        }
        Is_VM: {
          type: 'If'
          expression: {
            and: [
              {
                contains: [
                  '@toLower(outputs(\'Parse_target\'))'
                  'microsoft.compute/virtualmachines'
                ]
              }
              {
                equals: [
                  '@toLower(triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\'])'
                  'fired'
                ]
              }
            ]
          }
          runAfter: {
            Parse_target: [ 'Succeeded' ]
          }
          actions: {
            Start_VM: {
              type: 'Http'
              inputs: {
                // /start works for BOTH cases:
                //   - VM is deallocated  → it starts up
                //   - VM is already running → returns 409 Conflict (we ignore, see runAfter on Respond)
                // /restart would fail on a deallocated VM (the most common demo "break") so we don't use it.
                method: 'POST'
                uri: '@{concat(\'https://management.azure.com\', outputs(\'Parse_target\'), \'/start?api-version=2024-03-01\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://management.azure.com'
                }
              }
            }
          }
          else: {
            actions: {
              Log_no_op: {
                type: 'Compose'
                inputs: 'No matching mitigation action for this alert.'
              }
            }
          }
        }
        Respond: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            body: {
              message: 'Auto-mitigation Logic App processed the alert.'
              target: '@outputs(\'Parse_target\')'
              fired: '@triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\']'
            }
          }
          runAfter: {
            Is_VM: [ 'Succeeded', 'Skipped', 'Failed' ]
          }
        }
      }
    }
  }
}

resource vmStartRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, vmStartRoleName)
  properties: {
    roleName: vmStartRoleName
    description: 'Allows the lab auto-mitigation Logic App to start the configured demo VMs.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/start/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource linuxVmStartAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(linuxVmId)) {
  name: guid(linuxVmId, logic.id, vmStartRole.id)
  scope: linuxVm
  properties: {
    principalId: logic.identity.principalId
    roleDefinitionId: vmStartRole.id
    principalType: 'ServicePrincipal'
  }
}

resource windowsVmStartAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(windowsVmId)) {
  name: guid(windowsVmId, logic.id, vmStartRole.id)
  scope: windowsVm
  properties: {
    principalId: logic.identity.principalId
    roleDefinitionId: vmStartRole.id
    principalType: 'ServicePrincipal'
  }
}

// Expose the trigger URL with SAS so the Action Group can call it.
output id string = logic.id
output name string = logic.name
output callbackUrl string = listCallbackURL('${logic.id}/triggers/manual', '2019-05-01').value
