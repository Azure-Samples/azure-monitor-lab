@description('Existing lab Web App name.')
param webAppName string

@description('Existing central Log Analytics workspace ID.')
param centralLawId string

@description('Runner region.')
param location string

param tags object = {}

@description('Existing runner tags indexed by resource name, captured before bootstrap updates.')
param existingResourceTags object = {}

@description('Names of the two demo VMs allowed to receive the CPU simulation Run Command. Empty when the pair is not deployed.')
@maxLength(2)
param cpuVmNames array = []

var suffix = uniqueString(resourceGroup().id, webAppName)
var registryName = 'acrlabops${take(suffix, 12)}'
var environmentName = 'cae-labops-${take(suffix, 8)}'
var identityName = 'id-labops-${take(suffix, 8)}'
var jobName = 'job-labops-${take(suffix, 8)}'

resource site 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'console-runner-identity'
  params: {
    name: identityName
    location: location
    tags: union(existingResourceTags[?identityName] ?? {}, tags)
    enableTelemetry: false
  }
}

module registry 'br/public:avm/res/container-registry/registry:0.13.0' = {
  name: 'console-runner-registry'
  params: {
    name: registryName
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleSetDefaultAction: 'Allow'
    azureADAuthenticationAsArmPolicyStatus: 'enabled'
    enableTelemetry: false
    tags: union(existingResourceTags[?registryName] ?? {}, tags, { 'amlab-component': 'console-registry' })
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'AcrPull'
        principalId: identity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

module environment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'console-runner-environment'
  params: {
    name: environmentName
    location: location
    enableTelemetry: false
    zoneRedundant: false
    tags: union(existingResourceTags[?environmentName] ?? {}, tags, { 'amlab-component': 'console-environment' })
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    appLogsConfiguration: { destination: 'azure-monitor' }
  }
}

resource environmentResource 'Microsoft.App/managedEnvironments@2025-07-01' existing = {
  name: environmentName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'console-runner-logs'
  scope: environmentResource
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
  dependsOn: [environment]
}

resource runnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'lab-console-runner-role')
  properties: {
    roleName: 'Lab Console Runner ${take(suffix, 8)}'
    description: 'Lifecycle and annotation actions used by the lab console scripts at resource-group scope.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Resources/subscriptions/resources/read'
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/instanceView/read'
          'Microsoft.Compute/virtualMachines/start/action'
          'Microsoft.Compute/virtualMachines/deallocate/action'
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/instanceView/read'
          'Microsoft.Compute/virtualMachineScaleSets/start/action'
          'Microsoft.Compute/virtualMachineScaleSets/deallocate/action'
          'Microsoft.ContainerService/managedClusters/read'
          'Microsoft.ContainerService/managedClusters/start/action'
          'Microsoft.ContainerService/managedClusters/stop/action'
          'Microsoft.ContainerService/managedClusters/listClusterUserCredential/action'
          'Microsoft.Web/sites/read'
          'Microsoft.Web/sites/start/action'
          'Microsoft.Web/sites/stop/action'
          'Microsoft.Insights/components/read'
          'Microsoft.Insights/components/Annotations/read'
          'Microsoft.Insights/components/Annotations/write'
          'Microsoft.Insights/dataCollectionRules/read'
          'Microsoft.Insights/dataCollectionEndpoints/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

module runnerAssignment './lab-console-role.bicep' = {
  name: 'console-runner-access'
  params: {
    roleDefinitionId: runnerRole.id
    principalId: identity.outputs.principalId
  }
}

resource cpuRunCommandRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'lab-console-cpu-run-command-role')
  properties: {
    roleName: 'Lab Console VM Run Command ${take(suffix, 8)}'
    description: 'Elevated guest Run Command execution for CPU simulation, assigned only on the selected demo VMs.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: ['Microsoft.Compute/virtualMachines/runCommand/action']
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource cpuVms 'Microsoft.Compute/virtualMachines@2024-03-01' existing = [for vmName in cpuVmNames: {
  name: vmName
}]

resource cpuRunCommandAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (vmName, vmIndex) in cpuVmNames: {
  name: guid(cpuVms[vmIndex].id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', identityName), cpuRunCommandRole.id)
  scope: cpuVms[vmIndex]
  properties: {
    roleDefinitionId: cpuRunCommandRole.id
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}]

module consoleReader './lab-console-role.bicep' = {
  name: 'console-health-reader'
  params: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: site.identity.principalId
  }
}

module runnerReader './lab-console-role.bicep' = {
  name: 'console-runner-reader'
  params: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: identity.outputs.principalId
  }
}

output registryName string = registry.outputs.name
output registryId string = registry.outputs.resourceId
output environmentId string = environment.outputs.resourceId
output runnerIdentityId string = identity.outputs.resourceId
output runnerPrincipalId string = identity.outputs.principalId
output jobName string = jobName
