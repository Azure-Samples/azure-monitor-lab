// =============================================================================
// Azure Monitor Health Model -- AMLAB demo workload
//
// Builds a 3-tier health model on top of the lab resources, ready to demo
// out of the box:
//
//   Root  (auto-created entity, name == healthModelName)
//   |
//   +-- frontend  (generic entity)
//   |     +-- webapp        -> failed request rate, HttpResponseTime, CpuTime, memory
//   |     '-- appinsights   -> request duration, unexpected exceptions (Suppressed impact)
//   |
//   +-- compute   (generic entity)
//   |     +-- linuxvm       -> Percentage CPU
//   |     +-- winserver    -> Percentage CPU
//   |     +-- vmss          -> Percentage CPU
//   |     '-- aks           -> node CPU usage percentage
//   |
//   '-- platform (generic entity)
//         +-- keyvault      -> Availability  (Limited impact)
//         '-- storage       -> Availability  (Limited impact)
//
// Trip-the-demo cheat sheet:
//   * ./scripts/break-the-lab.ps1     -> /api/explode flood -> webapp failed request rate Unhealthy
//                                        (the lab's background load already fails about 7% on purpose)
//                                        -> frontend Unhealthy -> Root Unhealthy
//   * ./scripts/start-ramp.ps1        -> drives VMSS CPU      -> compute Unhealthy
//                                        -> Root Unhealthy (worst-of rollup)
//   * ./scripts/restore-the-lab.ps1   -> metrics drop          -> Healthy
//
// Impact knobs:
//   * appinsights -> Suppressed  (telemetry failure doesn't take the workload down)
//   * keyvault/storage -> Limited (Unhealthy -> propagates as Degraded only)
//   * everything else -> Standard
//
// API version:    2026-11-01
// Regions:        az provider show -n Microsoft.CloudHealth lists them.
// =============================================================================

import { layoutHealthModel } from './health-model-layout.bicep'

@description('Name of the Health Model resource. Also becomes the root-entity name.')
@minLength(3)
@maxLength(44)
param healthModelName string = 'hm-amlab-workload'

@description('Region for the Health Model. Must be a region where Microsoft.CloudHealth is available.')
@allowed([
  'uksouth'
  'canadacentral'
  'centralus'
  'swedencentral'
  'southeastasia'
])
param location string = 'swedencentral'

@description('Tags applied to the Health Model resource.')
param tags object = {}

@description('Resource ID of the App Service (web app).')
param webAppId string

@description('Resource ID of the Application Insights component.')
param appInsightsId string

@description('Resource ID of the AKS cluster.')
param aksId string

@description('Resource ID of the Linux VM. Empty string if not deployed.')
param linuxVmId string = ''

@description('Resource ID of the Windows VM. Empty string if not deployed.')
param windowsVmId string = ''

@description('Resource ID of the VMSS.')
param vmssId string

@description('Resource ID of the Key Vault.')
param keyVaultId string

@description('Resource ID of the Storage Account.')
param storageAccountId string

@description('Resource ID of the Action Group to notify on entity degraded/unhealthy. Optional.')
param actionGroupId string = ''

@description('Fold the AI (Foundry) workload into this model as a fourth "AI" tier. Off by default.')
param enableAi bool = false

@description('Resource ID of the Foundry (AI Services) account. Required when enableAi = true.')
param foundryAccountId string = ''

@description('Resource ID of the App Insights backing Log Analytics workspace (failed request rate, unexpected exceptions and per-agent AI signals).')
param appInsightsLawId string

@description('Fold Microsoft Fabric Real-Time Intelligence into this model as an optional workload tier.')
param enableFabric bool = false

@description('Resource ID of the Microsoft Fabric F2 capacity. Required when enableFabric = true.')
param fabricCapacityId string = ''

// -----------------------------------------------------------------------------
// Parent resource: Health Model + authentication setting
// -----------------------------------------------------------------------------
resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-11-01' = {
  name: healthModelName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {}
}

// Required by the portal designer before entities can be added.
resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-11-01' = {
  parent: healthModel
  name: 'systemAssigned'
  properties: {
    displayName: 'System-assigned managed identity'
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
}

// -----------------------------------------------------------------------------
// RBAC: grant the HM's system-assigned MI Monitoring Reader on the RG so its
// signals can read Azure Monitor metrics for every member resource. Without
// this, every entity sits in 'Unknown' state because metric reads return 403.
// (The portal Designer's discovery rule does this automatically; we author
// entities directly in Bicep, so we must grant it ourselves.)
// -----------------------------------------------------------------------------
// Monitoring Reader = 43d0d8ad-25c7-4714-9337-8ba259a9fe05
resource monitoringReaderOnRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Log Analytics Reader (73c42c96-874c-492b-b04d-ab87d138a893) so the model's identity
// can run the Log Analytics query signals (web app failure rate, exceptions, AI agents).
resource logAnalyticsReaderOnRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: healthModel.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Helper vars
// -----------------------------------------------------------------------------
var rootName = healthModelName
var authName = 'systemAssigned'
var actionGroupIds = empty(actionGroupId) ? [] : [ actionGroupId ]

// Demo agent personas (gen_ai.agent.name from workloads/ai) modelled as AI-tier entities.
var aiAgents = [
  { key: 'support-triage', display: 'Support Triage' }
  { key: 'finops-qa', display: 'FinOps Q&A' }
  { key: 'doc-summarizer', display: 'Doc Summarizer' }
  { key: 'context-rich-assistant', display: 'Context-Rich Assistant' }
]

// -----------------------------------------------------------------------------
// Tier-1 generic entities (frontend / compute / platform)
// -----------------------------------------------------------------------------
resource entFrontend 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'frontend'
  properties: {
    displayName: 'Frontend'
    impact: 'Standard'
    canvasPosition: layout.frontend
    icon: { iconName: 'EarthGlobe' }
    signalGroups: {
      dependencies: {
        aggregationType: 'WorstOf'
        ignoreUnknown: true
      }
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev1'
        description: 'AMLAB frontend tier unhealthy (webapp + App Insights rollup)'
        actionGroupIds: actionGroupIds
      }
    }
  }
}

resource entCompute 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'compute'
  properties: {
    displayName: 'Compute fleet'
    impact: 'Standard'
    canvasPosition: layout.compute
    icon: { iconName: 'Server' }
    signalGroups: {
      dependencies: {
        aggregationType: 'MaxNotHealthy'
        unhealthyThreshold: 50
        degradedThreshold: 25
        unit: 'Percentage'
        ignoreUnknown: true
      }
    }
    alerts: empty(actionGroupId) ? null : {
      degraded: {
        severity: 'Sev3'
        description: 'AMLAB compute fleet: 25%+ of nodes/VMs not healthy.'
        actionGroupIds: actionGroupIds
      }
      unhealthy: {
        severity: 'Sev1'
        description: 'AMLAB compute fleet: 50%+ of nodes/VMs not healthy.'
        actionGroupIds: actionGroupIds
      }
    }
  }
}

resource entPlatform 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'platform'
  properties: {
    displayName: 'Shared platform services'
    impact: 'Standard'
    canvasPosition: layout.platform
    icon: { iconName: 'Storage' }
    signalGroups: {
      dependencies: {
        aggregationType: 'WorstOf'
        ignoreUnknown: true
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Tier-2 Azure resource entities -- frontend branch
// -----------------------------------------------------------------------------
resource entWebApp 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'webapp'
  properties: {
    displayName: 'App Service (webapp)'
    impact: 'Standard'
    canvasPosition: layout.webapp
    icon: { iconName: 'AppService' }
    healthObjective: 99
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: webAppId
        azureResourceKind: 'app'
        signals: [
          {
            // Seconds, not milliseconds: HttpResponseTime reports 0.03 for a 30 ms average.
            name: 'responseTime'
            signalKind: 'AzureResourceMetric'
            displayName: 'Avg response time (s)'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'HttpResponseTime'
            aggregationType: 'Average'
            dataUnit: 'Seconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT1M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 1 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 3 }
            }
          }
          {
            name: 'cpu'
            signalKind: 'AzureResourceMetric'
            displayName: 'CPU time (s)'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'CpuTime'
            aggregationType: 'Total'
            dataUnit: 'Seconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 60 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 180 }
            }
          }
          {
            // App Service plan memory pressure (B1/S1 = ~1.75 GiB)
            name: 'memory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Memory working set'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'MemoryWorkingSet'
            aggregationType: 'Average'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 1073741824 }   // > 1 GiB
              unhealthyRule: { operator: 'GreaterThan', threshold: 1610612736 }   // > 1.5 GiB
            }
          }
        ]
      }
      azureLogAnalytics: {
        authenticationSetting: authName
        logAnalyticsWorkspaceResourceId: appInsightsLawId
        signals: [
          {
            // The Http5xx platform metric counts the lab's own /api/explode background load (7% of requests,
            // never above 10% in 24 hours), so a rate with thresholds above that baseline is what only a real
            // surge trips, like break-the-lab (its load generator sends 80% /api/explode). Fewer than 10
            // requests reads Unknown, not Unhealthy.
            name: 'failed-request-rate'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Failed requests (% with 5xx, 5 min)'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT1M'
            valueColumnName: 'value'
            queryText: '''
AppRequests
| summarize total = count(), failed = countif(ResultCode startswith "5")
| where total >= 10
| project value = round(100.0 * failed / total, 1)
'''
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 25 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 50 }
            }
          }
        ]
      }
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev2'
        description: 'AMLAB webapp unhealthy (failed request rate / latency / CPU / memory exceed thresholds).'
        actionGroupIds: actionGroupIds
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entAppInsights 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'appinsights'
  properties: {
    displayName: 'Application Insights (telemetry)'
    impact: 'Suppressed'   // telemetry outage shouldn't take the workload down
    canvasPosition: layout.appinsights
    icon: { iconName: 'ApplicationInsights' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: appInsightsId
        azureResourceKind: 'web'
        signals: [
          {
            // server-side request latency (avg) – proxy for user-experienced slow-down
            name: 'requestDuration'
            signalKind: 'AzureResourceMetric'
            displayName: 'Request duration (avg)'
            metricNamespace: 'microsoft.insights/components'
            metricName: 'requests/duration'
            aggregationType: 'Average'
            dataUnit: 'MilliSeconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 1500 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 3000 }
            }
          }
        ]
      }
      azureLogAnalytics: {
        authenticationSetting: authName
        logAnalyticsWorkspaceResourceId: appInsightsLawId
        signals: [
          {
            // The requests/failed and exceptions/count metrics count the 404s and /api/explode failures the lab
            // generates on purpose (hundreds per 5 minutes), so only exceptions from other routes count here.
            name: 'unexpected-exceptions'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Exceptions outside the demo failure route (15 min)'
            dataUnit: 'Count'
            timeGrain: 'PT15M'
            refreshInterval: 'PT5M'
            valueColumnName: 'value'
            queryText: '''
AppExceptions
| where OperationName != "GET /api/explode"
| summarize value = count()
'''
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 2 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 10 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

// -----------------------------------------------------------------------------
// Tier-2 Azure resource entities -- compute branch
// -----------------------------------------------------------------------------
resource entLinuxVm 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (!empty(linuxVmId)) {
  parent: healthModel
  name: 'linuxvm'
  properties: {
    displayName: 'Linux VM'
    impact: 'Standard'
    canvasPosition: layout.linuxvm
    icon: { iconName: 'VirtualMachineLinux' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: linuxVmId
        azureResourceKind: 'linux'
        signals: [
          {
            name: 'cpu'
            signalKind: 'AzureResourceMetric'
            displayName: 'CPU %'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Percentage CPU'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 60 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 85 }
            }
          }
          {
            // lower-is-worse: dipping below thresholds = memory pressure (percent, so it fits any VM size)
            name: 'availableMemory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Available memory %'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Available Memory Percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 20 }
              unhealthyRule: { operator: 'LessThan', threshold: 10 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entWindowsVm 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (!empty(windowsVmId)) {
  parent: healthModel
  name: 'winserver'
  properties: {
    displayName: 'Windows VM'
    impact: 'Standard'
    canvasPosition: layout.winserver
    icon: { iconName: 'VirtualMachineWindows' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: windowsVmId
        azureResourceKind: 'windows'
        signals: [
          {
            name: 'cpu'
            signalKind: 'AzureResourceMetric'
            displayName: 'CPU %'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Percentage CPU'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 60 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 85 }
            }
          }
          {
            name: 'availableMemory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Available memory %'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Available Memory Percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 20 }
              unhealthyRule: { operator: 'LessThan', threshold: 10 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entVmss 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'vmss'
  properties: {
    displayName: 'VMSS (predictive autoscale)'
    impact: 'Standard'
    canvasPosition: layout.vmss
    icon: { iconName: 'VirtualMachineScaleSet' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: vmssId
        azureResourceKind: 'vmss'
        signals: [
          {
            name: 'cpu'
            signalKind: 'AzureResourceMetric'
            displayName: 'CPU % (avg)'
            metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
            metricName: 'Percentage CPU'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 60 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 85 }
            }
          }
          {
            name: 'availableMemory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Available memory % (avg per instance)'
            metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
            metricName: 'Available Memory Percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 20 }
              unhealthyRule: { operator: 'LessThan', threshold: 10 }
            }
          }
        ]
      }
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev2'
        description: 'AMLAB VMSS CPU sustained above 85%.'
        actionGroupIds: actionGroupIds
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entAks 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'aks'
  properties: {
    displayName: 'AKS cluster'
    impact: 'Standard'
    canvasPosition: layout.aks
    icon: { iconName: 'Kubernetes' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: aksId
        azureResourceKind: 'k8s'
        signals: [
          {
            name: 'nodeCpu'
            signalKind: 'AzureResourceMetric'
            displayName: 'Node CPU % (avg)'
            metricNamespace: 'Microsoft.ContainerService/managedClusters'
            metricName: 'node_cpu_usage_percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 60 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 85 }
            }
          }
          {
            name: 'nodeMemory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Node memory working set %'
            metricNamespace: 'Microsoft.ContainerService/managedClusters'
            metricName: 'node_memory_working_set_percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 70 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 90 }
            }
          }
          {
            name: 'nodeDisk'
            signalKind: 'AzureResourceMetric'
            displayName: 'Node disk usage %'
            metricNamespace: 'Microsoft.ContainerService/managedClusters'
            metricName: 'node_disk_usage_percentage'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 75 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 90 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

// -----------------------------------------------------------------------------
// Tier-2 Azure resource entities -- platform branch
// -----------------------------------------------------------------------------
resource entKeyVault 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'keyvault'
  properties: {
    displayName: 'Key Vault'
    impact: 'Limited'
    canvasPosition: layout.keyvault
    icon: { iconName: 'KeyVault' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: keyVaultId
        azureResourceKind: 'vault'
        signals: [
          {
            name: 'availability'
            signalKind: 'AzureResourceMetric'
            displayName: 'Availability %'
            metricNamespace: 'Microsoft.KeyVault/vaults'
            metricName: 'Availability'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 100 }
              unhealthyRule: { operator: 'LessThan', threshold: 99 }
            }
          }
          {
            // ServiceApiLatency only has a datapoint when something calls the vault (1 in 24 hours here),
            // so the signal was Unknown nearly always. Saturation reports every hour.
            name: 'saturation'
            signalKind: 'AzureResourceMetric'
            displayName: 'Vault saturation %'
            metricNamespace: 'Microsoft.KeyVault/vaults'
            metricName: 'SaturationShoebox'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 75 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 90 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entStorage 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: 'storage'
  properties: {
    displayName: 'Storage Account'
    impact: 'Limited'
    canvasPosition: layout.storage
    icon: { iconName: 'StorageAccount' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: storageAccountId
        azureResourceKind: 'storage'
        signals: [
          {
            name: 'e2eLatency'
            signalKind: 'AzureResourceMetric'
            displayName: 'End-to-end latency (avg)'
            metricNamespace: 'Microsoft.Storage/storageAccounts'
            metricName: 'SuccessE2ELatency'
            aggregationType: 'Average'
            dataUnit: 'MilliSeconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 100 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 500 }
            }
          }
          {
            name: 'availability'
            signalKind: 'AzureResourceMetric'
            displayName: 'Availability %'
            metricNamespace: 'Microsoft.Storage/storageAccounts'
            metricName: 'Availability'
            aggregationType: 'Average'
            dataUnit: 'Percent'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 100 }
              unhealthyRule: { operator: 'LessThan', threshold: 99 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

// -----------------------------------------------------------------------------
// Tier-1 Real-Time Intelligence entity + tier-2 Fabric capacity (enableFabric)
// -----------------------------------------------------------------------------
// The capacity uses the resourceHealth signal, which the 2026-11-01 entity schema includes.
resource entRealTimeIntelligence 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (enableFabric) {
  parent: healthModel
  name: 'realtimeintelligence'
  properties: {
    displayName: 'Real-Time Intelligence'
    impact: 'Standard'
    canvasPosition: layout.realtimeintelligence
    icon: { iconName: 'Analytics' }
    signalGroups: {
      dependencies: {
        aggregationType: 'WorstOf'
        ignoreUnknown: true
      }
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev2'
        description: 'AMLAB Real-Time Intelligence workload unhealthy (Fabric capacity rollup).'
        actionGroupIds: actionGroupIds
      }
    }
  }
}

resource entFabricCapacity 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (enableFabric) {
  parent: healthModel
  name: 'fabriccapacity'
  properties: {
    displayName: 'Microsoft Fabric F2 capacity'
    impact: 'Standard'
    canvasPosition: layout.fabriccapacity
    icon: { iconName: 'Analytics' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: fabricCapacityId
        azureResourceKind: 'capacity'
        resourceHealth: {
          enabled: 'Enabled'
        }
      }
    }
  }
  dependsOn: [ authSetting ]
}

// -----------------------------------------------------------------------------
// Tier-1 AI entity + tier-2 Foundry account and per-agent entities (enableAi)
// -----------------------------------------------------------------------------
resource entAi 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (enableAi) {
  parent: healthModel
  name: 'aiworkload'
  properties: {
    displayName: 'AI workload (Foundry)'
    impact: 'Standard'
    canvasPosition: layout.aiworkload
    icon: { iconName: 'ApplicationInsights' }
    signalGroups: {
      dependencies: {
        aggregationType: 'WorstOf'
        ignoreUnknown: true
      }
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev2'
        description: 'AMLAB AI workload unhealthy (Foundry account + agents rollup).'
        actionGroupIds: actionGroupIds
      }
    }
  }
}

resource entFoundry 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = if (enableAi) {
  parent: healthModel
  name: 'foundry'
  properties: {
    displayName: 'Foundry account'
    impact: 'Standard'
    canvasPosition: layout.foundry
    icon: { iconName: 'ApplicationInsights' }
    healthObjective: 99
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: foundryAccountId
        azureResourceKind: 'aiservices'
        signals: [
          {
            name: 'latency'
            signalKind: 'AzureResourceMetric'
            displayName: 'Latency (avg)'
            metricNamespace: 'Microsoft.CognitiveServices/accounts'
            metricName: 'Latency'
            aggregationType: 'Average'
            dataUnit: 'MilliSeconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 2000 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 5000 }
            }
          }
          {
            name: 'totalErrors'
            signalKind: 'AzureResourceMetric'
            displayName: 'Total errors (5 min)'
            metricNamespace: 'Microsoft.CognitiveServices/accounts'
            metricName: 'TotalErrors'
            aggregationType: 'Total'
            dataUnit: 'Count'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 10 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 50 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

// One entity per agent persona, carrying an error-rate signal queried from the
// workspace-based App Insights AppDependencies table. Token volume is cost, not health
// (the token alerts in the AI stage watch it), so no signal counts it.
resource entAgents 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [for a in aiAgents: if (enableAi) {
  parent: healthModel
  name: 'agent-${a.key}'
  properties: {
    displayName: a.display
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: layout['agent-${a.key}']
    icon: { iconName: 'ApplicationInsights' }
    signalGroups: {
      azureLogAnalytics: {
        authenticationSetting: authName
        logAnalyticsWorkspaceResourceId: appInsightsLawId
        signals: [
          {
            name: 'error-rate'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Error rate (%, 1h)'
            dataUnit: 'Percent'
            refreshInterval: 'PT5M'
            valueColumnName: 'ErrorPct'
            queryText: 'AppDependencies | where TimeGenerated > ago(1h) | where tostring(Properties[\'gen_ai.agent.name\']) == \'${a.display}\' | summarize total=count(), failures=countif(Success==false) | project ErrorPct=iff(total==0, 0.0, round(100.0*failures/total, 1))'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: 5 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 20 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}]

// -----------------------------------------------------------------------------
// Relationships  (parent <- child)
//
// Root (= healthModelName) is auto-created. Tier-1 entities roll up to it.
// Tier-2 Azure resource entities roll up to their tier-1 parent.
//
// This list is the single source of the topology: it creates the relationships
// and, through the layout engine, every canvas position. A new entity needs its
// resource above, one edge here and a dependsOn entry on the relationships below.
// Siblings are drawn left to right in the order listed.
// -----------------------------------------------------------------------------
var edges = concat(
  [
    { name: 'frontend-to-root', parent: rootName, child: 'frontend', displayName: 'Frontend' }
    { name: 'compute-to-root', parent: rootName, child: 'compute', displayName: 'Compute fleet' }
    { name: 'platform-to-root', parent: rootName, child: 'platform', displayName: 'Shared platform' }
    { name: 'webapp-to-frontend', parent: 'frontend', child: 'webapp' }
    { name: 'appinsights-to-frontend', parent: 'frontend', child: 'appinsights' }
  ],
  empty(linuxVmId) ? [] : [{ name: 'linuxvm-to-compute', parent: 'compute', child: 'linuxvm' }],
  empty(windowsVmId) ? [] : [{ name: 'winserver-to-compute', parent: 'compute', child: 'winserver' }],
  [
    { name: 'vmss-to-compute', parent: 'compute', child: 'vmss' }
    { name: 'aks-to-compute', parent: 'compute', child: 'aks' }
    { name: 'keyvault-to-platform', parent: 'platform', child: 'keyvault' }
    { name: 'storage-to-platform', parent: 'platform', child: 'storage' }
  ],
  // Real-Time Intelligence tier (enableFabric): fabriccapacity -> realtimeintelligence -> root.
  enableFabric ? [
    { name: 'realtimeintelligence-to-root', parent: rootName, child: 'realtimeintelligence', displayName: 'Real-Time Intelligence' }
    { name: 'fabriccapacity-to-realtimeintelligence', parent: 'realtimeintelligence', child: 'fabriccapacity' }
  ] : [],
  // AI tier (enableAi): foundry + agents -> aiworkload -> root.
  enableAi ? concat(
    [
      { name: 'ai-to-root', parent: rootName, child: 'aiworkload', displayName: 'AI workload' }
      { name: 'foundry-to-ai', parent: 'aiworkload', child: 'foundry' }
    ],
    map(aiAgents, a => { name: 'agent-${a.key}-to-ai', parent: 'aiworkload', child: 'agent-${a.key}' })
  ) : []
)

// Canvas positions by entity name, including the root.
var layout = layoutHealthModel(rootName, [], edges)

// Update the service-created root at its existing ID to place it over its children.
resource root 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: healthModel
  name: rootName
  properties: {
    canvasPosition: layout[rootName]
  }
}

resource relationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-11-01' = [for edge in edges: {
  parent: healthModel
  name: edge.name
  properties: {
    parentEntityName: edge.parent
    childEntityName: edge.child
    displayName: edge.?displayName
  }
  dependsOn: [
    root
    entFrontend
    entCompute
    entPlatform
    entWebApp
    entAppInsights
    entLinuxVm
    entWindowsVm
    entVmss
    entAks
    entKeyVault
    entStorage
    entRealTimeIntelligence
    entFabricCapacity
    entAi
    entFoundry
    entAgents
  ]
}]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output healthModelId string = healthModel.id
output healthModelName string = healthModel.name
output healthModelPrincipalId string = healthModel.identity.principalId
