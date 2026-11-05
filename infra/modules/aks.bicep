@description('AKS cluster name.')
param name string

@description('DNS prefix.')
param dnsPrefix string

@description('Region.')
param location string

@description('System node pool VM size. Workload nodes come from node auto provisioning (workloads/k8s/00-nodepools.yaml).')
param nodeVmSize string = 'Standard_B4ls_v2'

@description('System node pool node count.')
param nodeCount int = 1

@description('Central LAW for Container Insights logs.')
param centralLawId string

@description('Azure Monitor Workspace for Managed Prometheus metrics.')
param azureMonitorWorkspaceId string

@description('Data Collection Endpoint for Prometheus DCR.')
param dataCollectionEndpointId string

@description('Name for the Prometheus DCR.')
param dcrPrometheusName string

@description('Resource tags.')
param tags object = {}

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    kubernetesVersion: '1.34'
    dnsPrefix: dnsPrefix
    enableRBAC: true
    nodeProvisioningProfile: {
      mode: 'Auto'
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        maxPods: 30
        enableAutoScaling: false
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
      serviceCidr: '10.100.0.0/16'
      dnsServiceIP: '10.100.0.10'
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: centralLawId
          useAADAuth: 'true'
        }
      }
    }
    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: {
          metricLabelsAllowlist: '*'
          metricAnnotationsAllowList: '*'
        }
      }
    }
    apiServerAccessProfile: {
      enablePrivateCluster: false
    }
  }
}

// Diagnostic settings on the AKS control plane -> central LAW
resource diagAks 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aks
  name: 'send-to-central-law'
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ---------------------------------------------------------------------------------
// Container Insights DCR + association on the AKS cluster
// ---------------------------------------------------------------------------------
resource dcrContainerInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'MSCI-${replace(location, ' ', '')}-${name}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          streams: [ 'Microsoft-ContainerInsights-Group-Default' ]
          extensionName: 'ContainerInsights'
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Off'
              namespaces: []
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'ciworkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-ContainerInsights-Group-Default' ]
        destinations: [ 'ciworkspace' ]
      }
    ]
  }
}

resource dcraContainerInsights 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: aks
  name: 'ContainerInsightsExtension'
  properties: {
    dataCollectionRuleId: dcrContainerInsights.id
    description: 'Send AKS Container Insights inventory and performance data to Log Analytics'
  }
}

// ---------------------------------------------------------------------------------
// Managed Prometheus DCR + association on the AKS cluster
// ---------------------------------------------------------------------------------
resource dcrPrometheus 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrPrometheusName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpointId
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: [ 'Microsoft-PrometheusMetrics' ]
          labelIncludeFilter: {}
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: azureMonitorWorkspaceId
          name: 'amwDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-PrometheusMetrics' ]
        destinations: [ 'amwDestination' ]
      }
    ]
  }
}

resource dcraAks 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: aks
  name: 'prometheus-association'
  properties: {
    dataCollectionRuleId: dcrPrometheus.id
    description: 'Send AKS cluster Prometheus metrics to Azure Monitor Workspace'
  }
}

output id string = aks.id
output name string = aks.name
output controlPlaneFqdn string = aks.properties.fqdn
