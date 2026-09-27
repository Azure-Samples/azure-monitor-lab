// =============================================================================
// Azure Monitor Health Model (preview)  -- AMLAB demo workload
//
// Builds a 3-tier health model on top of the lab resources, ready to demo
// out of the box:
//
//   Root  (auto-created entity, name == healthModelName)
//   |
//   +-- frontend  (generic entity)
//   |     +-- webapp        -> Http5xx, HttpResponseTime, CpuTime
//   |     '-- appinsights   -> failed requests count (Suppressed impact)
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
//   * ./scripts/break-the-lab.ps1     -> /api/explode flood -> webapp Http5xx Unhealthy
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
// API version:    2026-01-01-preview
// Allowed regions: UK South, Canada Central, Central US, Sweden Central,
//                  Southeast Asia
// =============================================================================

@description('Name of the Health Model resource. Also becomes the root-entity name.')
@minLength(3)
@maxLength(44)
param healthModelName string = 'hm-amlab-workload'

@description('Region for the Health Model. Must be one of the supported preview regions.')
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

@description('Resource ID of the App Insights backing Log Analytics workspace (per-agent AI signals). Required when enableAi = true.')
param appInsightsLawId string = ''

// -----------------------------------------------------------------------------
// Parent resource: Health Model + authentication setting
// -----------------------------------------------------------------------------
resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-01-01-preview' = {
  name: healthModelName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {}
}

// Required by the portal designer before entities can be added.
resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-01-01-preview' = {
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

// Log Analytics Reader (73c42c96-874c-492b-b04d-ab87d138a893) — only when AI is folded in,
// so the model's identity can run the per-agent Log Analytics query signals.
resource logAnalyticsReaderOnRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableAi) {
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
  { key: 'support-triage', display: 'Support Triage', x: 500, y: 700 }
  { key: 'finops-qa', display: 'FinOps Q&A', x: 650, y: 700 }
  { key: 'doc-summarizer', display: 'Doc Summarizer', x: 800, y: 700 }
  { key: 'context-rich-assistant', display: 'Context-Rich Assistant', x: 950, y: 700 }
]

// -----------------------------------------------------------------------------
// Tier-1 generic entities (frontend / compute / platform)
// -----------------------------------------------------------------------------
resource entFrontend 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'frontend'
  properties: {
    displayName: 'Frontend'
    impact: 'Standard'
    canvasPosition: { x: -300, y: 200 }
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

resource entCompute 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'compute'
  properties: {
    displayName: 'Compute fleet'
    impact: 'Standard'
    canvasPosition: { x: 0, y: 200 }
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

resource entPlatform 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'platform'
  properties: {
    displayName: 'Shared platform services'
    impact: 'Standard'
    canvasPosition: { x: 300, y: 200 }
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
resource entWebApp 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'webapp'
  properties: {
    displayName: 'App Service (webapp)'
    impact: 'Standard'
    canvasPosition: { x: -400, y: 450 }
    icon: { iconName: 'AppService' }
    healthObjective: 99
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: webAppId
        azureResourceKind: 'app'
        signals: [
          {
            name: 'http5xx'
            signalKind: 'AzureResourceMetric'
            displayName: 'HTTP 5xx errors (5 min)'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'Http5xx'
            aggregationType: 'Total'
            dataUnit: 'Count'
            timeGrain: 'PT5M'
            refreshInterval: 'PT1M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 10 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 30 }
            }
          }
          {
            name: 'responseTime'
            signalKind: 'AzureResourceMetric'
            displayName: 'Avg response time (ms)'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'HttpResponseTime'
            aggregationType: 'Average'
            dataUnit: 'MilliSeconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT1M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 1000 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 3000 }
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
    }
    alerts: empty(actionGroupId) ? null : {
      unhealthy: {
        severity: 'Sev2'
        description: 'AMLAB webapp unhealthy (5xx / latency / CPU / memory exceed thresholds).'
        actionGroupIds: actionGroupIds
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entAppInsights 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'appinsights'
  properties: {
    displayName: 'Application Insights (telemetry)'
    impact: 'Suppressed'   // telemetry outage shouldn't take the workload down
    canvasPosition: { x: -200, y: 450 }
    icon: { iconName: 'ApplicationInsights' }
    signalGroups: {
      azureResource: {
        authenticationSetting: authName
        azureResourceId: appInsightsId
        azureResourceKind: 'web'
        signals: [
          {
            name: 'failedRequests'
            signalKind: 'AzureResourceMetric'
            displayName: 'Failed requests (5 min)'
            metricNamespace: 'microsoft.insights/components'
            metricName: 'requests/failed'
            aggregationType: 'Count'
            dataUnit: 'Count'
            timeGrain: 'PT5M'
            refreshInterval: 'PT1M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 20 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 50 }
            }
          }
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
          {
            // unhandled exception rate
            name: 'exceptions'
            signalKind: 'AzureResourceMetric'
            displayName: 'Exceptions (5 min)'
            metricNamespace: 'microsoft.insights/components'
            metricName: 'exceptions/count'
            aggregationType: 'Count'
            dataUnit: 'Count'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 5 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 20 }
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
resource entLinuxVm 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = if (!empty(linuxVmId)) {
  parent: healthModel
  name: 'linuxvm'
  properties: {
    displayName: 'Linux VM'
    impact: 'Standard'
    canvasPosition: { x: -100, y: 450 }
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
            // lower-is-worse: dipping below thresholds = memory pressure
            name: 'availableMemory'
            signalKind: 'AzureResourceMetric'
            displayName: 'Available memory'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Available Memory Bytes'
            aggregationType: 'Average'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 536870912 }   // < 512 MiB
              unhealthyRule: { operator: 'LessThan', threshold: 268435456 }   // < 256 MiB
            }
          }
          {
            // sustained disk read pressure
            name: 'diskRead'
            signalKind: 'AzureResourceMetric'
            displayName: 'Disk read bytes (5 min total)'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Disk Read Bytes'
            aggregationType: 'Total'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 15000000000 }   // > 15 GB / 5 min
              unhealthyRule: { operator: 'GreaterThan', threshold: 60000000000 }   // > 60 GB / 5 min
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entWindowsVm 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = if (!empty(windowsVmId)) {
  parent: healthModel
  name: 'winserver'
  properties: {
    displayName: 'Windows VM'
    impact: 'Standard'
    canvasPosition: { x: 0, y: 450 }
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
            displayName: 'Available memory'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Available Memory Bytes'
            aggregationType: 'Average'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 536870912 }   // < 512 MiB
              unhealthyRule: { operator: 'LessThan', threshold: 268435456 }   // < 256 MiB
            }
          }
          {
            name: 'diskWrite'
            signalKind: 'AzureResourceMetric'
            displayName: 'Disk write bytes (5 min total)'
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            metricName: 'Disk Write Bytes'
            aggregationType: 'Total'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 15000000000 }   // > 15 GB / 5 min
              unhealthyRule: { operator: 'GreaterThan', threshold: 60000000000 }   // > 60 GB / 5 min
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entVmss 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'vmss'
  properties: {
    displayName: 'VMSS (predictive autoscale)'
    impact: 'Standard'
    canvasPosition: { x: 100, y: 450 }
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
            displayName: 'Available memory (avg per instance)'
            metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
            metricName: 'Available Memory Bytes'
            aggregationType: 'Average'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'LessThan', threshold: 536870912 }
              unhealthyRule: { operator: 'LessThan', threshold: 268435456 }
            }
          }
          {
            // bursty traffic that may drive predictive autoscale
            name: 'networkIn'
            signalKind: 'AzureResourceMetric'
            displayName: 'Network in (5 min total)'
            metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
            metricName: 'Network In Total'
            aggregationType: 'Total'
            dataUnit: 'Bytes'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 524288000 }    // > 500 MB / 5 min
              unhealthyRule: { operator: 'GreaterThan', threshold: 2147483648 }   // > 2 GiB / 5 min
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

resource entAks 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'aks'
  properties: {
    displayName: 'AKS cluster'
    impact: 'Standard'
    canvasPosition: { x: 200, y: 450 }
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
resource entKeyVault 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'keyvault'
  properties: {
    displayName: 'Key Vault'
    impact: 'Limited'
    canvasPosition: { x: 250, y: 450 }
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
            name: 'apiLatency'
            signalKind: 'AzureResourceMetric'
            displayName: 'API latency (avg)'
            metricNamespace: 'Microsoft.KeyVault/vaults'
            metricName: 'ServiceApiLatency'
            aggregationType: 'Average'
            dataUnit: 'MilliSeconds'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 200 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 1000 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

resource entStorage 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = {
  parent: healthModel
  name: 'storage'
  properties: {
    displayName: 'Storage Account'
    impact: 'Limited'
    canvasPosition: { x: 400, y: 450 }
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
// Tier-1 AI entity + tier-2 Foundry account and per-agent entities (enableAi)
// -----------------------------------------------------------------------------
resource entAi 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = if (enableAi) {
  parent: healthModel
  name: 'aiworkload'
  properties: {
    displayName: 'AI workload (Foundry)'
    impact: 'Standard'
    canvasPosition: { x: 600, y: 200 }
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

resource entFoundry 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = if (enableAi) {
  parent: healthModel
  name: 'foundry'
  properties: {
    displayName: 'Foundry account'
    impact: 'Standard'
    canvasPosition: { x: 600, y: 450 }
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
          {
            // Token volume as a cost/load indicator (not an availability signal).
            name: 'totalTokens'
            signalKind: 'AzureResourceMetric'
            displayName: 'Total tokens (5 min) — cost/load'
            metricNamespace: 'Microsoft.CognitiveServices/accounts'
            metricName: 'TotalTokens'
            aggregationType: 'Total'
            dataUnit: 'Count'
            timeGrain: 'PT5M'
            refreshInterval: 'PT5M'
            evaluationRules: {
              degradedRule:  { operator: 'GreaterThan', threshold: 500000 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 2000000 }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ authSetting ]
}

// One entity per agent persona, each carrying error-rate + estimated-cost signals
// queried from the workspace-based App Insights AppDependencies table (high cost or
// error rate turns the agent unhealthy).
resource entAgents 'Microsoft.CloudHealth/healthmodels/entities@2026-01-01-preview' = [for a in aiAgents: if (enableAi) {
  parent: healthModel
  name: 'agent-${a.key}'
  properties: {
    displayName: a.display
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: { x: a.x, y: a.y }
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
          {
            name: 'token-volume'
            signalKind: 'LogAnalyticsQuery'
            displayName: 'Total tokens/hour'
            dataUnit: 'Count'
            refreshInterval: 'PT5M'
            valueColumnName: 'TotalTokens'
            queryText: 'AppDependencies | where TimeGenerated > ago(1h) | where tostring(Properties[\'gen_ai.agent.name\']) == \'${a.display}\' | extend inTok=toint(Properties[\'gen_ai.usage.input_tokens\']), outTok=toint(Properties[\'gen_ai.usage.output_tokens\']) | summarize TotalTokens=coalesce(sum(inTok), 0)+coalesce(sum(outTok), 0)'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: 100000 }
              unhealthyRule: { operator: 'GreaterThan', threshold: 200000 }
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
// -----------------------------------------------------------------------------
resource relFrontendRoot 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'frontend-to-root'
  properties: {
    parentEntityName: rootName
    childEntityName: 'frontend'
    displayName: 'Frontend'
  }
  dependsOn: [ entFrontend ]
}

resource relComputeRoot 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'compute-to-root'
  properties: {
    parentEntityName: rootName
    childEntityName: 'compute'
    displayName: 'Compute fleet'
  }
  dependsOn: [ entCompute ]
}

resource relPlatformRoot 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'platform-to-root'
  properties: {
    parentEntityName: rootName
    childEntityName: 'platform'
    displayName: 'Shared platform'
  }
  dependsOn: [ entPlatform ]
}

resource relWebappFrontend 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'webapp-to-frontend'
  properties: {
    parentEntityName: 'frontend'
    childEntityName: 'webapp'
  }
  dependsOn: [ entWebApp, entFrontend ]
}

resource relAppInsightsFrontend 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'appinsights-to-frontend'
  properties: {
    parentEntityName: 'frontend'
    childEntityName: 'appinsights'
  }
  dependsOn: [ entAppInsights, entFrontend ]
}

resource relLinuxVmCompute 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = if (!empty(linuxVmId)) {
  parent: healthModel
  name: 'linuxvm-to-compute'
  properties: {
    parentEntityName: 'compute'
    childEntityName: 'linuxvm'
  }
  dependsOn: [ entLinuxVm, entCompute ]
}

resource relWinServerCompute 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = if (!empty(windowsVmId)) {
  parent: healthModel
  name: 'winserver-to-compute'
  properties: {
    parentEntityName: 'compute'
    childEntityName: 'winserver'
  }
  dependsOn: [ entWindowsVm, entCompute ]
}

resource relVmssCompute 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'vmss-to-compute'
  properties: {
    parentEntityName: 'compute'
    childEntityName: 'vmss'
  }
  dependsOn: [ entVmss, entCompute ]
}

resource relAksCompute 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'aks-to-compute'
  properties: {
    parentEntityName: 'compute'
    childEntityName: 'aks'
  }
  dependsOn: [ entAks, entCompute ]
}

resource relKeyVaultPlatform 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'keyvault-to-platform'
  properties: {
    parentEntityName: 'platform'
    childEntityName: 'keyvault'
  }
  dependsOn: [ entKeyVault, entPlatform ]
}

resource relStoragePlatform 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = {
  parent: healthModel
  name: 'storage-to-platform'
  properties: {
    parentEntityName: 'platform'
    childEntityName: 'storage'
  }
  dependsOn: [ entStorage, entPlatform ]
}

// AI tier relationships (enableAi): ai -> root, foundry + agents -> ai.
resource relAiRoot 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = if (enableAi) {
  parent: healthModel
  name: 'ai-to-root'
  properties: {
    parentEntityName: rootName
    childEntityName: 'aiworkload'
    displayName: 'AI workload'
  }
  dependsOn: [ entAi ]
}

resource relFoundryAi 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = if (enableAi) {
  parent: healthModel
  name: 'foundry-to-ai'
  properties: {
    parentEntityName: 'aiworkload'
    childEntityName: 'foundry'
  }
  dependsOn: [ entFoundry, entAi ]
}

resource relAgentsAi 'Microsoft.CloudHealth/healthmodels/relationships@2026-01-01-preview' = [for a in aiAgents: if (enableAi) {
  parent: healthModel
  name: 'agent-${a.key}-to-ai'
  properties: {
    parentEntityName: 'aiworkload'
    childEntityName: 'agent-${a.key}'
  }
  dependsOn: [ entAgents, entAi ]
}]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output healthModelId string = healthModel.id
output healthModelName string = healthModel.name
output healthModelPrincipalId string = healthModel.identity.principalId
