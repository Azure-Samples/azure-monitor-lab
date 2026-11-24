targetScope = 'resourceGroup'

param connectedClusterName string

resource cluster 'Microsoft.Kubernetes/connectedClusters@2024-07-15-preview' existing = {
  name: connectedClusterName
}

resource certificates 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  scope: cluster
  name: 'azure-cert-management'
  properties: {
    extensionType: 'microsoft.certmanagement'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
  }
}

resource pipeline 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  scope: cluster
  name: 'azure-monitor-pipeline'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.monitor.pipeline'
    autoUpgradeMinorVersion: false
    releaseTrain: 'preview'
    version: '0.1.7'
    scope: {
      cluster: {
        releaseNamespace: 'default'
      }
    }
    configurationSettings: {
      'controllerManager.manager.env.pipelineReplicas': '1'
    }
  }
  dependsOn: [certificates]
}

output extensionId string = pipeline.id
output extensionPrincipalId string = pipeline.identity.principalId
