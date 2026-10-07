// =====================================================================================
// Azure Monitor Lab - main template (Resource Group scope)
// Deploys: 2x Log Analytics workspaces, App Insights, VNet, Linux+Windows VMs with VM
// Insights, AKS with Container Insights + Managed Prometheus + Managed Grafana,
// App Service with .NET sample app + auto-instrumented App Insights, Action Group,
// Metric Alerts, Service/Resource Health alerts, custom diagnostics policy,
// saved KQL queries, traffic-lights Workbook.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names. Lowercase, 3-8 chars.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Email address that receives Action Group notifications.')
param alertEmail string

@description('Admin username for the demo VMs.')
param vmAdminUsername string = 'azureuser'

@description('Admin password for the demo VMs. Must meet Azure complexity rules.')
@secure()
param vmAdminPassword string

@description('Deploy the Windows Server 2022 demo VM.')
param deployWindowsVm bool = true

@description('Deploy the Ubuntu 22.04 demo VM.')
param deployLinuxVm bool = true

@description('Collect default OpenTelemetry guest metrics in the Azure Monitor workspace for the demo VMs, alongside classic VM Insights. Does not apply to VM Scale Sets.')
param enableVmOtelMetrics bool = true

@description('Daily ingestion cap (GB) on the central Log Analytics workspace. Set to -1 to disable.')
param dailyCapGb int = 1

@description('VM size (kept small for a demo lab).')
param vmSize string = 'Standard_B2s'

@description('AKS node VM size.')
param aksNodeVmSize string = 'Standard_B2s'

@description('AKS node count.')
param aksNodeCount int = 1

@description('Optional Microsoft Entra object ID of the Grafana lab operator or group. Empty grants Grafana Admin to the deployment identity; set explicitly for CI deployments.')
param grafanaAdminObjectId string = ''

@description('Public GitHub repo deployed to the App Service (Microsoft .NET hello world sample).')
param appServiceRepoUrl string = 'https://github.com/Azure-Samples/dotnetcore-docs-hello-world-linux'

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Enable LAW cross-region replication (doubles ingestion cost). Default off.')
param enableLawReplication bool = false

@description('Secondary region for LAW replication (must be a paired region of the primary). Required when enableLawReplication = true.')
param lawReplicationLocation string = ''

@description('Optional secondary SIEM/Teams webhook URL added to the Action Group. Empty = skip.')
@secure()
param siemWebhookUrl string = ''

@description('Enable Microsoft Sentinel on the central workspace. Default true.')
param enableSentinel bool = true

@description('Enable the platform-logs DCR (scenario 51, public preview). Off by default — the DCR and central LAW must be in a region that supports the preview.')
param enablePlatformLogsDcr bool = false

@description('Enable the metrics-export DCR (scenario 52, GA). Off by default — the DCR and central LAW must be in the same region.')
param enableMetricsExportDcr bool = false

@description('Enable the optional AI stage — Microsoft Foundry workload (account, project, chat/embed/optimize/model-router deployments) + App Insights connection + token alerts + query pack/workbook/health model. Off by default (billable models, region-limited).')
param enableAi bool = false

@description('Deploy Azure SRE Agent in Sweden Central with Azure Monitor, Application Insights, and Log Analytics connectors. Off by default (billable usage).')
param enableSreAgent bool = false

@description('Deploy Azure Copilot Observability Agent with autonomous alert correlation. Off by default (preview and billable agent operations).')
param enableObservabilityAgent bool = false

@description('Supported region for Azure Copilot Observability Agent and its dedicated Azure Monitor workspace.')
@allowed([
  'australiaeast'
  'canadacentral'
  'centralus'
  'eastasia'
  'eastus'
  'southcentralus'
  'uksouth'
  'westcentralus'
  'westeurope'
])
param observabilityAgentLocation string = 'westeurope'

@description('Run billable deep investigations automatically for Observability Agent-created issues.')
param enableObservabilityAgentAutomaticInvestigation bool = false

@description('Natural-language guidance for Observability Agent alert correlation and issue creation.')
@maxLength(8192)
param observabilityAgentInstructions string = 'Act as the trace specialist for the lab application. Correlate alerts only when they describe the same customer impact and keep unrelated infrastructure alerts separate. Always create an issue for severity 1 or severity 2 agent task or efficiency failures and add [OPS-REVIEW] to the title. Reconstruct the Application Insights request, agent, model, handoff, and tool hierarchy; report technical, task, performance, and trace health separately. Produce an SRE handoff packet with customer impact, likely fault domain and confidence, three timestamped evidence points with sources, the smallest safe correction, rollback conditions, missing evidence, and fixed-run verification criteria. Do not claim remediation or incident closure.'

@description('Model Router deployment version for the AI feature. VERIFY for your region with "az cognitiveservices account list-models".')
param routerModelVersion string = '2025-08-07'

// ---------------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------------
var suffix              = uniqueString(resourceGroup().id)
var lawCentralName      = 'law-${namePrefix}-central-${take(suffix, 5)}'
var lawAppInsightsName  = 'law-${namePrefix}-appinsights-${take(suffix, 5)}'
var appInsightsName     = 'appi-${namePrefix}-${take(suffix, 5)}'
var amwName             = 'amw-${namePrefix}'
var grafanaName         = 'amg-${namePrefix}-${take(suffix, 4)}'
var vnetName            = 'vnet-${namePrefix}'
var nsgName             = 'nsg-${namePrefix}'
var linuxVmName         = 'vm-${namePrefix}-lin'
var windowsVmName       = 'vmwin${take(suffix, 4)}'
var aksName             = 'aks-${namePrefix}'
var aksDnsPrefix        = '${namePrefix}-${take(suffix, 6)}'
var appPlanName         = 'plan-${namePrefix}'
var webAppName          = 'app-${namePrefix}-${take(suffix, 5)}'
var actionGroupName     = 'ag-${namePrefix}-email'
var workbookName        = 'wb-${namePrefix}-trafficlights'
var dcrVmInsightsName   = 'dcr-${namePrefix}-vminsights'
var deployVmOtelMetrics = enableVmOtelMetrics && (deployLinuxVm || deployWindowsVm)
var dcrPrometheusName   = 'dcr-${namePrefix}-prometheus'
var dceName             = 'dce-${namePrefix}'
var vmssName            = 'vmss-${namePrefix}'
var storageAccountName  = 'st${namePrefix}${take(suffix, 8)}'
// Dedicated storage co-located with the App Service (westeurope) for its archive diag
// setting — storage diag destinations must match the source region.
var appDiagStorageName  = 'stapp${namePrefix}${take(suffix, 8)}'
var eventHubNsName      = 'evhns-${namePrefix}-${take(suffix, 5)}'
var keyVaultName        = 'kv-${namePrefix}-${take(suffix, 5)}'
var costWorkbookName    = 'wb-${namePrefix}-cost'
var sliUamiName         = 'id-sli-${namePrefix}'
var platformLogsDcrName = 'dcr-${namePrefix}-platformlogs'
var metricsExportDcrName = 'dcr-${namePrefix}-metricsexport'
var sreAgentName         = 'sre-${namePrefix}-${take(suffix, 5)}'
var observabilityAgentName = 'obs-${namePrefix}-${take(suffix, 5)}'
var observabilityAgentMonitoringAccountName = 'amw-${namePrefix}-obs'

// AI feature (Foundry) is pinned to swedencentral, independent of the lab region —
// the gpt-5-* / model-router SKUs + Foundry portal + CloudHealth preview are region-limited.
var aiLocation = 'swedencentral'

// App Service is pinned to westeurope, independent of the lab region — the sponsored
// lab subscriptions have no Basic (B1) App Service quota in northeurope, so the plan
// would fail ARM preflight there. westeurope has unlimited Basic quota.
var appServiceLocation = 'westeurope'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// ---------------------------------------------------------------------------------
// Log Analytics workspaces
// ---------------------------------------------------------------------------------
module lawCentral 'modules/law.bicep' = {
  name: 'law-central'
  params: {
    name: lawCentralName
    location: location
    dailyQuotaGb: dailyCapGb
    tags: commonTags
    solutions: [ 'VMInsights', 'ContainerInsights' ]
    enableReplication: enableLawReplication
    replicationLocation: lawReplicationLocation
  }
}

module lawAppInsights 'modules/law.bicep' = {
  name: 'law-appinsights'
  params: {
    name: lawAppInsightsName
    location: location
    dailyQuotaGb: dailyCapGb
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Application Insights (workspace-based, points to dedicated LAW)
// ---------------------------------------------------------------------------------
module appInsights 'modules/appinsights.bicep' = {
  name: 'appi'
  params: {
    name: appInsightsName
    location: location
    workspaceId: lawAppInsights.outputs.id
    tags: commonTags
  }
}

module appInsightsObservability 'modules/appinsights-observability.bicep' = {
  name: 'appinsights-observability'
  params: {
    location: location
    namePrefix: namePrefix
    appInsightsId: appInsights.outputs.id
    tags: commonTags
  }
}

module observabilityAgent 'modules/observability-agent.bicep' = if (enableObservabilityAgent) {
  name: 'observability-agent'
  params: {
    name: observabilityAgentName
    monitoringAccountName: observabilityAgentMonitoringAccountName
    location: observabilityAgentLocation
    appInsightsId: appInsights.outputs.id
    issueCreationInstructions: observabilityAgentInstructions
    enableAutomaticInvestigation: enableObservabilityAgentAutomaticInvestigation
    tags: commonTags
  }
}

module observabilityAgentSubscriptionRbac 'modules/observability-agent-subscription-rbac.bicep' = if (enableObservabilityAgent) {
  name: 'observability-agent-subscription-rbac'
  scope: subscription()
  params: {
    principalId: observabilityAgent!.outputs.principalId
  }
}

module sreAgent 'modules/sre-agent.bicep' = if (enableSreAgent) {
  name: 'sre-agent'
  params: {
    name: sreAgentName
    appInsightsId: appInsights.outputs.id
    appInsightsAppId: appInsights.outputs.appId
    appInsightsConnectionString: appInsights.outputs.connectionString
    logAnalyticsId: lawCentral.outputs.id
    managedResourceGroupId: resourceGroup().id
    tags: commonTags
  }
}

module sreAgentSubscriptionRbac 'modules/sre-agent-subscription-rbac.bicep' = if (enableSreAgent) {
  name: 'sre-agent-subscription-rbac'
  scope: subscription()
  params: {
    principalId: sreAgent!.outputs.systemPrincipalId
  }
}

// ---------------------------------------------------------------------------------
// Azure Monitor Workspace (Managed Prometheus) + Data Collection Endpoint
// ---------------------------------------------------------------------------------
module amw 'modules/azure-monitor-workspace.bicep' = {
  name: 'amw'
  params: {
    name: amwName
    location: location
    tags: commonTags
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: commonTags
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    vnetName: vnetName
    nsgName: nsgName
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE — Shared multi-purpose Storage Account (diag archive + flow logs +
// data export target + Storage Insights demo subject).
// ---------------------------------------------------------------------------------
module storageAccount 'modules/storage-account.bicep' = {
  name: 'storage-account'
  params: {
    name: storageAccountName
    location: location
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

// Dedicated storage for the App Service archive-to-blob diag setting, co-located with
// the App Service in westeurope (storage diag destinations must match the source region).
module appDiagStorage 'modules/storage-account.bicep' = {
  name: 'app-diag-storage'
  params: {
    name: appDiagStorageName
    location: appServiceLocation
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE — Event Hub Namespace (diag fan-out destination + data-export option).
// Pinned to the App Service region (westeurope): its only consumer is the App Service
// 'stream-to-eventhub' diag setting, and Event Hub diag destinations MUST be in the
// same region as the monitored resource.
// ---------------------------------------------------------------------------------
module eventHub 'modules/eventhub.bicep' = {
  name: 'eventhub'
  params: {
    namespaceName: eventHubNsName
    location: appServiceLocation
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE — Key Vault (Key Vault Insights demo subject).
// ---------------------------------------------------------------------------------
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    centralLawId: lawCentral.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Data Collection Rule for VM Insights (Performance + Map data) -> central LAW
// Depends on the VMInsights solution being installed on the LAW first.
// ---------------------------------------------------------------------------------
resource dcrVmInsights 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrVmInsightsName
  location: location
  tags: commonTags
  kind: 'Linux'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'VMInsightsPerfCounters'
          streams: [ 'Microsoft-InsightsMetrics' ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [ '\\VmInsights\\DetailedMetrics' ]
        }
      ]
      extensions: [
        {
          name: 'DependencyAgentDataSource'
          streams: [ 'Microsoft-ServiceMap' ]
          extensionName: 'DependencyAgent'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: lawCentral.outputs.id
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-InsightsMetrics' ]
        destinations: [ 'centralLaw' ]
      }
      {
        streams: [ 'Microsoft-ServiceMap' ]
        destinations: [ 'centralLaw' ]
      }
    ]
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 1 — Workspace Transformation DCR on AzureActivity (cost-control demo).
// Uses real activity-log data already flowing to the central LAW. Filters out
// noisy "/read" operations + enriches the Properties dynamic column.
// ---------------------------------------------------------------------------------
module workspaceTransforms 'modules/dcr-workspace-transforms.bicep' = {
  name: 'workspace-transforms'
  params: {
    name: 'dcr-${namePrefix}-workspace-transforms'
    location: location
    centralLawId: lawCentral.outputs.id
    centralLawName: lawCentral.outputs.name
    tags: commonTags
  }
}

module vmOtelMetrics 'modules/vm-otel-metrics.bicep' = if (deployVmOtelMetrics) {
  name: 'vm-otel-metrics'
  params: {
    name: 'dcr-${namePrefix}-vm-otel'
    location: location
    monitoringAccountId: amw.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Linux VM (Ubuntu 22.04) with AMA + DCR associations
// ---------------------------------------------------------------------------------
module vmLinux 'modules/vm-linux.bicep' = if (deployLinuxVm) {
  name: 'vm-linux'
  params: {
    vmName: linuxVmName
    location: location
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: network.outputs.workloadSubnetId
    dcrId: dcrVmInsights.id
    otelDcrId: deployVmOtelMetrics ? vmOtelMetrics!.outputs.id : ''
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Windows VM (Windows Server 2022) with AMA + Dependency Agent + DCR association
// ---------------------------------------------------------------------------------
module vmWindows 'modules/vm-windows.bicep' = if (deployWindowsVm) {
  name: 'vm-windows'
  params: {
    vmName: windowsVmName
    location: location
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: network.outputs.workloadSubnetId
    dcrId: dcrVmInsights.id
    otelDcrId: deployVmOtelMetrics ? vmOtelMetrics!.outputs.id : ''
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// AKS with Container Insights + Managed Prometheus + diag settings -> central LAW
// ---------------------------------------------------------------------------------
module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    name: aksName
    dnsPrefix: aksDnsPrefix
    location: location
    nodeVmSize: aksNodeVmSize
    nodeCount: aksNodeCount
    centralLawId: lawCentral.outputs.id
    azureMonitorWorkspaceId: amw.outputs.id
    dataCollectionEndpointId: dce.id
    dcrPrometheusName: dcrPrometheusName
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Azure Managed Grafana, linked to the Azure Monitor Workspace + LAW
// ---------------------------------------------------------------------------------
module grafana 'modules/grafana.bicep' = {
  name: 'grafana'
  params: {
    name: grafanaName
    adminObjectId: grafanaAdminObjectId
    location: location
    azureMonitorWorkspaceId: amw.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// App Service (Linux .NET 8) + auto-instrumented App Insights + sample app
// ---------------------------------------------------------------------------------
module appService 'modules/appservice.bicep' = {
  name: 'appservice'
  params: {
    planName: appPlanName
    webAppName: webAppName
    location: appServiceLocation
    appInsightsConnectionString: appInsights.outputs.connectionString
    appInsightsInstrumentationKey: appInsights.outputs.instrumentationKey
    centralLawId: lawCentral.outputs.id
    // FEATURE — multi-destination diagnostic settings fan-out
    diagStorageAccountId: appDiagStorage.outputs.id
    diagEventHubAuthRuleId: eventHub.outputs.sendRuleId
    diagEventHubName: eventHub.outputs.hubName
    tags: commonTags
  }
}

module consolePlatform 'modules/lab-console-platform.bicep' = {
  name: 'lab-console-platform'
  params: {
    webAppName: appService.outputs.webAppName
    centralLawId: lawCentral.outputs.id
    location: appServiceLocation
    tags: commonTags
    cpuVmNames: deployLinuxVm && deployWindowsVm ? [vmLinux!.outputs.vmName, vmWindows!.outputs.vmName] : []
  }
}

// ---------------------------------------------------------------------------------
// Action Group + Alerts (CPU, failed requests, pod restarts, service health)
// ---------------------------------------------------------------------------------
// ---------------------------------------------------------------------------------
// FEATURE 5 — Auto-mitigation Logic App (must exist before Action Group so we can
// pass its callback URL as the webhook receiver).
// ---------------------------------------------------------------------------------
module automitigation 'modules/automitigation-logicapp.bicep' = {
  name: 'automitigation'
  params: {
    name: 'la-${namePrefix}-automitigation'
    location: location
    tags: commonTags
  }
}

module actionGroup 'modules/actiongroup.bicep' = {
  name: 'actiongroup'
  params: {
    name: actionGroupName
    email: alertEmail
    webhookUrl: automitigation.outputs.callbackUrl
    siemWebhookUrl: siemWebhookUrl
    tags: commonTags
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    location: location
    actionGroupId: actionGroup.outputs.id
    aksId: aks.outputs.id
    webAppId: appService.outputs.webAppId
    webAppRegion: appServiceLocation
    appInsightsId: appInsights.outputs.id
    linuxVmId: deployLinuxVm ? vmLinux!.outputs.vmId : ''
    windowsVmId: deployWindowsVm ? vmWindows!.outputs.vmId : ''
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 2 — AMBA-aligned baseline alerts (VM, App Service, AKS).
// ---------------------------------------------------------------------------------
module amba 'modules/amba.bicep' = {
  name: 'amba'
  params: {
    location: location
    actionGroupId: actionGroup.outputs.id
    vmIds: filter([
      deployLinuxVm ? vmLinux!.outputs.vmId : ''
      deployWindowsVm ? vmWindows!.outputs.vmId : ''
    ], id => !empty(id))
    webAppId: appService.outputs.webAppId
    aksId: aks.outputs.id
    appPlanId: appService.outputs.planId
    webAppRegion: appServiceLocation
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Service Health + Resource Health alerts (subscription / RG scope)
// ---------------------------------------------------------------------------------
module healthAlerts 'modules/health-alerts.bicep' = {
  name: 'health-alerts'
  params: {
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Custom Azure Policy: DeployIfNotExists diag settings for App Services -> central LAW
// (Showcases the pattern from
//  https://learn.microsoft.com/en-us/azure/azure-monitor/platform/diagnostic-settings-policy)
// ---------------------------------------------------------------------------------
module diagPolicy 'modules/policy-diagnostics.bicep' = {
  name: 'policy-diagnostics'
  params: {
    centralLawId: lawCentral.outputs.id
  }
}

// ---------------------------------------------------------------------------------
// Saved KQL queries in central LAW (single & cross-workspace) for the demo
// ---------------------------------------------------------------------------------
module savedQueries 'modules/saved-queries.bicep' = {
  name: 'saved-queries'
  params: {
    centralLawName: lawCentral.outputs.name
    appInsightsLawName: lawAppInsights.outputs.name
  }
}

// ---------------------------------------------------------------------------------
// Traffic-Lights Workbook
// ---------------------------------------------------------------------------------
module workbook 'modules/workbook.bicep' = {
  name: 'workbook'
  params: {
    name: guid(resourceGroup().id, workbookName)
    location: location
    centralLawId: lawCentral.outputs.id
    appInsightsLawName: lawAppInsights.outputs.name
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// VMSS with predictive autoscale (scenario 19 — AI-powered pre-scaling demo)
// ---------------------------------------------------------------------------------
module vmss 'modules/vmss.bicep' = {
  name: 'vmss'
  params: {
    name: vmssName
    location: location
    vmSize: 'Standard_B1s'
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: network.outputs.workloadSubnetId
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Dynamic threshold alert on VM CPU (scenario 17 — ML-learned baselines demo)
// ---------------------------------------------------------------------------------
// Condition must use the plain params (not vmLinux/vmWindows outputs) — a resource
// `if` can't depend on another conditional resource's output (BCP177).
resource alertVmCpuDynamic 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployLinuxVm || deployWindowsVm) {
  name: 'alert-vm-cpu-dynamic'
  location: 'global'
  tags: commonTags
  properties: {
    description: 'Lab VM CPU above its ML-learned baseline (medium sensitivity)'
    severity: 3
    enabled: true
    scopes: filter([
      deployLinuxVm ? vmLinux!.outputs.vmId : ''
      deployWindowsVm ? vmWindows!.outputs.vmId : ''
    ], id => !empty(id))
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CpuDynamic'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          timeAggregation: 'Average'
          criterionType: 'DynamicThresholdCriterion'
          alertSensitivity: 'Medium'
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.outputs.id }
    ]
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 6 — Availability Test (standard URL ping from 5 global locations)
// ---------------------------------------------------------------------------------
module availabilityTest 'modules/availability-test.bicep' = {
  name: 'availability-test'
  params: {
    name: 'avail-${namePrefix}-appservice'
    location: location
    appInsightsId: appInsights.outputs.id
    testUrl: 'https://${appService.outputs.defaultHost}/'
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

module agentTaskAvailabilityTest 'modules/availability-test.bicep' = {
  name: 'agent-task-availability-test'
  params: {
    name: 'avail-${namePrefix}-agent-task'
    location: location
    appInsightsId: appInsights.outputs.id
    testUrl: 'https://${appService.outputs.defaultHost}/api/agent-task-availability'
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 7 — Alert Processing Rules (maintenance window + severity suppression)
// ---------------------------------------------------------------------------------
module alertProcessingRules 'modules/alert-processing-rules.bicep' = {
  name: 'alert-processing-rules'
  params: {
    namePrefix: namePrefix
    primaryActionGroupId: actionGroup.outputs.id
    vmIds: filter([
      deployLinuxVm ? vmLinux!.outputs.vmId : ''
      deployWindowsVm ? vmWindows!.outputs.vmId : ''
    ], id => !empty(id))
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 8 — Custom Logs via Logs Ingestion API (DCE + DCR + SecurityAudit_CL)
// ---------------------------------------------------------------------------------
module customLogs 'modules/custom-logs.bicep' = {
  name: 'custom-logs'
  params: {
    namePrefix: namePrefix
    location: location
    centralLawId: lawCentral.outputs.id
    centralLawName: lawCentral.outputs.name
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 9 — KQL Functions (reusable saved functions: vmHealth, aksHealth, envHealth)
// ---------------------------------------------------------------------------------
module kqlFunctions 'modules/kql-functions.bicep' = {
  name: 'kql-functions'
  params: {
    centralLawName: lawCentral.outputs.name
    appInsightsLawName: lawAppInsights.outputs.name
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 10 — Summary Rules (hourly Perf aggregation into Perf_Hourly_CL)
// ---------------------------------------------------------------------------------
module summaryRules 'modules/summary-rules.bicep' = {
  name: 'summary-rules'
  params: {
    centralLawName: lawCentral.outputs.name
    centralLawId: lawCentral.outputs.id
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 11 — Log Analytics RBAC (workspace-level, table-level, row-level)
// ---------------------------------------------------------------------------------
module lawRbac 'modules/law-rbac.bicep' = {
  name: 'law-rbac'
  params: {
    centralLawId: lawCentral.outputs.id
    centralLawName: lawCentral.outputs.name
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// FEATURE 12 — Security posture alerts (control-plane drift, privilege, exfiltration)
// ---------------------------------------------------------------------------------
module securityPostureAlerts 'modules/security-posture-alerts.bicep' = {
  name: 'security-posture-alerts'
  params: {
    location: location
    workspaceId: lawCentral.outputs.id
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

// =================================================================================
// NEW FEATURES — Network observability, Sentinel, Prom rules, Cost workbook, etc.
// =================================================================================

// ---------------------------------------------------------------------------------
// Network Watcher + Connection Monitor (VMs -> App Service HTTPS)
// Deployed at NetworkWatcherRG scope to live alongside the singleton NW that
// Azure auto-creates per region per subscription.
// ---------------------------------------------------------------------------------
module connectionMonitor 'modules/connection-monitor.bicep' = {
  name: 'connection-monitor'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    centralLawId: lawCentral.outputs.id
    linuxVmId:   deployLinuxVm   ? vmLinux!.outputs.vmId   : ''
    windowsVmId: deployWindowsVm ? vmWindows!.outputs.vmId : ''
    appServiceHost: appService.outputs.defaultHost
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// VNet Flow Logs + Traffic Analytics (raw to storage, enriched to central LAW)
// Flow logs are children of the Network Watcher, so this also deploys to NetworkWatcherRG.
// ---------------------------------------------------------------------------------
module flowLogs 'modules/flow-logs.bicep' = {
  name: 'flow-logs'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    name: 'fl-${namePrefix}-vnet'
    location: location
    targetVnetId: network.outputs.vnetId
    networkWatcherId: connectionMonitor.outputs.networkWatcherId
    storageAccountId: storageAccount.outputs.id
    centralLawId: lawCentral.outputs.id
    centralLawRegion: location
    // Read customerId via the module output (not a separate `existing` reference) so the
    // cross-RG flow-logs deployment has a hard dependency on the LAW being fully created —
    // the `existing` reference was intermittently ResourceNotFound at preflight.
    centralLawCustomerId: lawCentral.outputs.customerId
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// LAW continuous Data Export rule (Heartbeat -> storage account "law-export" container)
// ---------------------------------------------------------------------------------
module dataExport 'modules/data-export.bicep' = {
  name: 'data-export'
  params: {
    name: 'dx-${namePrefix}-heartbeat'
    workspaceName: lawCentral.outputs.name
    storageAccountId: storageAccount.outputs.id
    tables: [ 'Heartbeat' ]
  }
}

// ---------------------------------------------------------------------------------
// Scenario 51 — Platform logs at scale with DCRs (public preview).
//   One PlatformTelemetry DCR + association on Azure Managed Grafana, replacing the
//   per-resource diagnostic-setting model with a single, scale-out rule.
//   Off by default (enablePlatformLogsDcr=false) — preview + region-limited.
// ---------------------------------------------------------------------------------
module platformLogsDcr 'modules/platform-logs-dcr.bicep' = if (enablePlatformLogsDcr) {
  name: 'platform-logs-dcr'
  params: {
    name: platformLogsDcrName
    location: location
    centralLawId: lawCentral.outputs.id
    grafanaName: grafana.outputs.name
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Scenario 52 — Azure Monitor Metrics Export via DCRs (GA).
//   One PlatformTelemetry DCR + association on the Key Vault, exporting
//   dimensional platform metrics to the central LAW (AzureMetricsV2 table).
//   Off by default (enableMetricsExportDcr=false) — DCR + LAW must share a region.
// ---------------------------------------------------------------------------------
module metricsExportDcr 'modules/metrics-export-dcr.bicep' = if (enableMetricsExportDcr) {
  name: 'metrics-export-dcr'
  params: {
    name: metricsExportDcrName
    location: location
    centralLawId: lawCentral.outputs.id
    keyVaultName: keyVaultName
    tags: commonTags
  }
  dependsOn: [ keyVault ]
}

// ---------------------------------------------------------------------------------
// Microsoft Sentinel — onboard the central LAW + 1 analytics rule
// ---------------------------------------------------------------------------------
module sentinel 'modules/sentinel.bicep' = if (enableSentinel) {
  name: 'sentinel'
  params: {
    workspaceName: lawCentral.outputs.name
    workspaceId: lawCentral.outputs.id
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Managed Prometheus Rule Group (recording + alerting rules on AMW)
// ---------------------------------------------------------------------------------
module promRules 'modules/prometheus-rules.bicep' = {
  name: 'prom-rules'
  params: {
    name: 'amlab-prom-rules'
    location: location
    azureMonitorWorkspaceId: amw.outputs.id
    aksClusterId: aks.outputs.id
    actionGroupId: actionGroup.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Cost-of-monitoring Workbook
// ---------------------------------------------------------------------------------
module costWorkbook 'modules/cost-workbook.bicep' = {
  name: 'cost-workbook'
  params: {
    name: guid(resourceGroup().id, costWorkbookName)
    location: location
    centralLawId: lawCentral.outputs.id
    dailyCapGb: dailyCapGb
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Azure Monitor Health Model (preview) -- scenario 45
//
// Builds a 3-tier model rolling up to a single root: frontend (webapp +
// App Insights), compute (VMs + VMSS + AKS), platform (KV + Storage), each
// with realistic demo-friendly signal thresholds. See scenario 45 in
// DEMO-SCENARIOS.md for the click-through.
// ---------------------------------------------------------------------------------
module healthModel 'modules/health-model.bicep' = {
  name: 'health-model'
  params: {
    healthModelName: 'hm-${namePrefix}-workload'
    // Health Model (preview) is only available in a limited set of regions
    // (UK South, Canada Central, Central US, Sweden Central, Southeast Asia),
    // so its region is pinned to swedencentral independent of the lab location.
    location: 'swedencentral'
    tags: commonTags
    webAppId: appService.outputs.webAppId
    appInsightsId: appInsights.outputs.id
    aksId: aks.outputs.id
    linuxVmId: deployLinuxVm ? vmLinux.outputs.vmId : ''
    windowsVmId: deployWindowsVm ? vmWindows.outputs.vmId : ''
    vmssId: vmss.outputs.vmssId
    keyVaultId: keyVault.outputs.id
    storageAccountId: storageAccount.outputs.id
    actionGroupId: actionGroup.outputs.id
    // Fold the AI (Foundry) workload into this model as a fourth tier when enabled.
    enableAi: enableAi
    foundryAccountId: enableAi ? foundry!.outputs.accountId : ''
    appInsightsLawId: lawAppInsights.outputs.id
  }
}

// ---------------------------------------------------------------------------------
// SLI prerequisites (preview) -- scenario 46
//
// Provisions the User-Assigned MI + RBAC required by Microsoft.Monitor/slis. The
// SLI resources themselves are extensions on a tenant-scoped service group and
// are PUT by scripts/setup-slis.ps1 (the service group itself is created by
// scripts/setup-health-model.ps1, both called from deploy.ps1).
// ---------------------------------------------------------------------------------
module sliIdentity 'modules/sli-identity.bicep' = {
  name: 'sli-identity'
  params: {
    uamiName: sliUamiName
    location: location
    tags: commonTags
    azureMonitorWorkspaceId: amw.outputs.id
  }
}

// ---------------------------------------------------------------------------------
// Optional AI feature — Microsoft Foundry GenAI workload (account, project,
// chat/embed/optimize/model-router deployments) + App Insights connection + token
// metric alerts, plus the AI FinOps query pack/workbook and health model. Pinned to
// swedencentral (aiLocation), independent of the lab region. Off by default.
// After deploy, run scripts/setup-ai.ps1 to create the agents and simulate traffic.
// ---------------------------------------------------------------------------------
module foundry 'modules/foundry.bicep' = if (enableAi) {
  name: 'foundry'
  params: {
    location: aiLocation
    namePrefix: namePrefix
    appInsightsId: appInsights.outputs.id
    appInsightsConnectionString: appInsights.outputs.connectionString
    routerModelVersion: routerModelVersion
    alertEmail: alertEmail
    tags: commonTags
  }
}

module aiObservability 'modules/ai-observability.bicep' = if (enableAi) {
  name: 'ai-observability'
  params: {
    location: aiLocation
    appInsightsId: appInsights.outputs.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Outputs (consumed by post-deploy scripts)
// ---------------------------------------------------------------------------------
output centralLawId string         = lawCentral.outputs.id
output centralLawName string       = lawCentral.outputs.name
output appInsightsLawName string   = lawAppInsights.outputs.name
output appInsightsName string      = appInsightsName
output appInsightsConnString string = appInsights.outputs.connectionString
output aksName string              = aks.outputs.name
output webAppName string           = webAppName
output webAppDefaultHost string    = appService.outputs.defaultHost
output grafanaEndpoint string      = grafana.outputs.endpoint
output workbookId string           = workbook.outputs.id
output appInsightsInvestigationWorkbookId string = appInsightsObservability.outputs.workbookId
output appInsightsUsageWorkbookId string = appInsightsObservability.outputs.usageWorkbookId
output appInsightsQueryPackName string = appInsightsObservability.outputs.queryPackName
output linuxVmNameOut string       = deployLinuxVm ? linuxVmName : ''
output windowsVmNameOut string     = deployWindowsVm ? windowsVmName : ''
output autoMitigationLogicAppName string = automitigation.outputs.name

// FEATURE 1 — Workspace Transformation DCR
output workspaceTransformDcrName string = workspaceTransforms.outputs.dcrName
output appServiceRepoUrl string    = appServiceRepoUrl
output vmssName string             = vmss.outputs.vmssName
output vmssAutoscaleName string    = vmss.outputs.autoscaleSettingName

// FEATURE 6 — Availability Test
output availabilityTestName string = availabilityTest.outputs.testName
output agentTaskAvailabilityTestName string = agentTaskAvailabilityTest.outputs.testName

// FEATURE 7 — Alert Processing Rules
output maintenanceRuleName string  = alertProcessingRules.outputs.maintenanceRuleName

// FEATURE 8 — Custom Logs
output customLogsDceEndpoint string = customLogs.outputs.dceEndpoint
output customLogsDcrImmutableId string = customLogs.outputs.dcrImmutableId

// FEATURE 10 — Summary Rules
output summaryTableName string     = summaryRules.outputs.tableName

// FEATURE 11 — RBAC
output rbacSummary string          = lawRbac.outputs.rbacSummary

// NEW — Network observability
output networkWatcherId string         = connectionMonitor.outputs.networkWatcherId
output connectionMonitorName string    = connectionMonitor.outputs.connectionMonitorName
output flowLogName string              = flowLogs.outputs.name

// NEW — Shared infra
output storageAccountName string       = storageAccount.outputs.name
output eventHubNamespaceName string    = eventHub.outputs.namespaceName
output keyVaultName string             = keyVault.outputs.name

// NEW — Data Export / Sentinel / Prom / Cost
output dataExportRuleName string       = dataExport.outputs.name
output sentinelEnabled bool            = enableSentinel
output prometheusRuleGroupName string  = promRules.outputs.name
output costWorkbookId string           = costWorkbook.outputs.id
// NEW — Health Model (scenario 45)
output healthModelName string          = healthModel.outputs.healthModelName
output healthModelId string            = healthModel.outputs.healthModelId
output healthModelPrincipalId string   = healthModel.outputs.healthModelPrincipalId

// Optional AI feature (empty unless enableAi = true)
output aiEnabled bool                  = enableAi
output aiFoundryAccountName string     = enableAi ? foundry!.outputs.accountName : ''
output aiProjectEndpoint string        = enableAi ? foundry!.outputs.projectEndpoint : ''
output aiChatDeployment string         = enableAi ? foundry!.outputs.chatDeployment : ''
output aiRouterDeployment string       = enableAi ? foundry!.outputs.routerDeployment : ''

// Optional SRE Agent stage (empty unless enableSreAgent = true)
output sreAgentEnabled bool            = enableSreAgent
output sreAgentName string             = enableSreAgent ? sreAgent!.outputs.name : ''
output sreAgentEndpoint string         = enableSreAgent ? sreAgent!.outputs.endpoint : ''
output sreAgentPortalUrl string        = enableSreAgent ? sreAgent!.outputs.portalUrl : ''

// Optional Azure Copilot Observability Agent stage (empty unless enabled)
output observabilityAgentEnabled bool = enableObservabilityAgent
output observabilityAgentName string = enableObservabilityAgent ? observabilityAgent!.outputs.name : ''
output observabilityAgentId string = enableObservabilityAgent ? observabilityAgent!.outputs.id : ''
output observabilityAgentPortalUrl string = enableObservabilityAgent ? observabilityAgent!.outputs.portalUrl : ''
output observabilityAgentMonitoringAccountName string = enableObservabilityAgent ? observabilityAgent!.outputs.monitoringAccountName : ''
output observabilityAgentAutomaticInvestigationEnabled bool = enableObservabilityAgent && enableObservabilityAgentAutomaticInvestigation

// NEW — Alert Processing Rules nightly window
output nightlyMaintenanceRuleName string = alertProcessingRules.outputs.nightlyMaintenanceRuleName

// NEW — SLI prerequisites (scenario 46)
output sliUamiName string        = sliIdentity.outputs.uamiName
output sliUamiId string          = sliIdentity.outputs.uamiId
output sliUamiPrincipalId string = sliIdentity.outputs.uamiPrincipalId
output sliUamiClientId string    = sliIdentity.outputs.uamiClientId
output amwId string              = amw.outputs.id
output amwName string            = amw.outputs.name
