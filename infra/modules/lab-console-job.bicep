param name string
param location string
param webAppName string
param customerWebAppName string = ''
param environmentId string
param registryServer string
param runnerIdentityId string
param runnerClientId string
@description('Immutable image built by the automatic console bootstrap.')
param image string
param tags object = {}

@description('Existing runner tags indexed by resource name, captured before bootstrap updates.')
param existingResourceTags object = {}

resource site 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource launcherRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'lab-console-launcher-role')
  properties: {
    roleName: 'Lab Console Job Launcher ${uniqueString(resourceGroup().id)}'
    description: 'Start and inspect the approved console job without editing job configuration.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.App/jobs/read'
          'Microsoft.App/jobs/start/action'
          'Microsoft.App/jobs/execution/read'
          'Microsoft.App/jobs/executions/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

module job 'br/public:avm/res/app/job:0.7.2' = {
  name: 'console-runner-job'
  params: {
    name: name
    location: location
    environmentResourceId: environmentId
    enableTelemetry: false
    triggerType: 'Manual'
    replicaRetryLimit: 0
    replicaTimeout: 1800
    manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
    workloadProfileName: 'Consumption'
    managedIdentities: { userAssignedResourceIds: [runnerIdentityId] }
    registries: [ { server: registryServer, identity: runnerIdentityId } ]
    containers: [
      {
        name: 'runner'
        image: image
        command: ['pwsh', '-NoLogo', '-NoProfile', '-File', '/runner/scripts/invoke-lab-operation.ps1']
        resources: { cpu: '1.0', memory: '2Gi' }
        env: [
          { name: 'LAB_SUBSCRIPTION_ID', value: subscription().subscriptionId }
          { name: 'LAB_TENANT_ID', value: tenant().tenantId }
          { name: 'LAB_RESOURCE_GROUP', value: resourceGroup().name }
          { name: 'LAB_WEB_APP_NAME', value: webAppName }
          { name: 'LAB_CUSTOMER_WEB_APP_NAME', value: customerWebAppName }
          { name: 'LAB_RUNNER_MODE', value: 'ContainerAppsJob' }
          { name: 'AZURE_CLIENT_ID', value: runnerClientId }
        ]
      }
    ]
    tags: union(existingResourceTags[?name] ?? {}, tags, { 'amlab-component': 'console-job' })
    roleAssignments: [
      {
        roleDefinitionIdOrName: launcherRole.id
        principalId: site.identity.principalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

output jobId string = job.outputs.resourceId
