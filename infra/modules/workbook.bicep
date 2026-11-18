// =====================================================================================
// Traffic-Lights Workbook for the Azure Monitor Lab.
// One grid row per logical resource (VMs, AKS, App Service, App Insights) with a
// 🟢/🟠/🔴 emoji status column based on heartbeat / failure thresholds.
// =====================================================================================

@description('Workbook resource name (a GUID-like string).')
param name string

@description('Region.')
param location string

@description('Central LAW resource ID (workbook primary scope).')
param centralLawId string

@description('Name of the App Insights LAW (used for cross-workspace queries).')
param appInsightsLawName string = 'law-amlab-appinsights'

@description('Resource tags.')
param tags object = {}

// Traffic-lights KQL — uses an __APPI_LAW__ placeholder so the workbook is portable
// across labs; the actual name is injected just below.
var trafficLightsQuery = '''let lookback = 15m;
let nowT = now();
let vm = Heartbeat
  | where TimeGenerated > ago(1h)
  | summarize LastBeat = max(TimeGenerated) by Computer, OSType
  | extend SecondsSince = datetime_diff("second", nowT, LastBeat)
  | extend Status = case(SecondsSince <= 300, "🟢", SecondsSince <= 900, "🟠", "🔴")
  | project ResourceType = strcat("VM (", OSType, ")"), Resource = Computer, Status,
            Detail = strcat("Last heartbeat ", SecondsSince, "s ago");
let aksNodes = Perf
  | where TimeGenerated > ago(15m)
  | where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores"
  | summarize LastSample = max(TimeGenerated) by Computer
  | summarize Total = count();
let aksRestarts = toscalar(KubePodInventory
  | where TimeGenerated > ago(15m)
  | summarize MaxRestarts = max(toint(ContainerRestartCount)) by Namespace, Name
  | summarize Restarts = sum(MaxRestarts)
  | project Restarts);
let aks = aksNodes
  | extend Restarts = aksRestarts
  | extend Status = case(Total == 0, "🔴", Restarts > 5, "🟠", "🟢")
  | extend Detail = strcat(Total, " nodes reporting · ", Restarts, " restarts (15m)")
  | project ResourceType = "AKS Cluster", Resource = "aks", Status, Detail;
let app = AppServiceHTTPLogs
  | where TimeGenerated > ago(15m)
  | summarize FiveXX = countif(ScStatus >= 500), Total = count() by _ResourceId
  | extend Status = case(FiveXX >= 5, "🔴", FiveXX > 0, "🟠", "🟢")
  | extend ResourceType = "App Service", Resource = tostring(split(_ResourceId, "/")[8])
  | project ResourceType, Resource, Status, Detail = strcat(Total, " req · ", FiveXX, " 5xx (15m)");
let appi = workspace("__APPI_LAW__").AppRequests
  | where TimeGenerated > ago(15m)
  | summarize Total = count(), Failed = countif(Success == false)
  | extend Status = case(Failed >= 10, "🔴", Failed > 0, "🟠", "🟢")
  | project ResourceType = "App Insights", Resource = "appi", Status,
            Detail = strcat(Total, " requests · ", Failed, " failed (15m)");
union isfuzzy=true vm, aks, app, appi
| extend SortKey = case(Status == "🔴", 0, Status == "🟠", 1, 2)
| order by SortKey asc, ResourceType asc
| project-away SortKey
'''

var queryFinal = replace(trafficLightsQuery, '__APPI_LAW__', appInsightsLawName)


// ---------------------------------------------------------------
// KQL queries for the extended health dashboard
// ---------------------------------------------------------------

var summaryTilesQuery = replace('''let vmsOnline = toscalar(Heartbeat | where TimeGenerated > ago(5m) | summarize dcount(Computer));
let aksReady = toscalar(Perf | where TimeGenerated > ago(15m) | where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores" | summarize dcount(Computer));
let totalReqs = toscalar(workspace("__APPI_LAW__").AppRequests | where TimeGenerated > ago(1h) | summarize count());
let failedReqs = toscalar(workspace("__APPI_LAW__").AppRequests | where TimeGenerated > ago(1h) | where Success == false | summarize count());
let avgLatency = toscalar(workspace("__APPI_LAW__").AppRequests | where TimeGenerated > ago(1h) | summarize round(avg(DurationMs), 0));
let ingestMB = toscalar(Usage | where TimeGenerated > startofday(now()) | summarize round(sum(Quantity), 1));
print a=1
| project Metric  = pack_array("💻 VMs Online", "☸️ AKS Nodes", "🌐 Requests (1h)", "❌ Failed (1h)", "⏱️ Avg Latency", "📦 Ingest Today"),
          Value   = pack_array(toreal(vmsOnline), toreal(aksReady), toreal(totalReqs), toreal(failedReqs), toreal(avgLatency), toreal(ingestMB)),
          Suffix  = pack_array("", "", "", "", "ms", "MB")
| mv-expand Metric to typeof(string), Value to typeof(real), Suffix to typeof(string)
''', '__APPI_LAW__', appInsightsLawName)

var vmCpuQuery = '''InsightsMetrics
| where Namespace == "Processor" and Name == "UtilizationPercentage"
| summarize AvgCPU = round(avg(Val), 1) by bin(TimeGenerated, 5m), Computer
| render timechart
'''

var vmMemoryQuery = '''InsightsMetrics
| where Namespace == "Memory" and Name == "AvailableMB"
| summarize AvailMB = round(avg(Val), 0) by bin(TimeGenerated, 5m), Computer
| render timechart
'''

var aksNodeCpuQuery = '''Perf
| where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores"
| summarize CPU_millicores = round(avg(CounterValue / 1000000.0), 0) by bin(TimeGenerated, 5m), Computer
| render timechart
'''

var aksPodRestartsQuery = '''KubePodInventory
| summarize MaxRestarts = max(toint(ContainerRestartCount)) by Name, bin(TimeGenerated, 5m)
| summarize TotalRestarts = sum(MaxRestarts) by bin(TimeGenerated, 5m)
| render areachart
'''

var responseTimeQuery = replace('''workspace("__APPI_LAW__").AppRequests
| summarize P50 = percentile(DurationMs, 50), P95 = percentile(DurationMs, 95), P99 = percentile(DurationMs, 99) by bin(TimeGenerated, 5m)
| render timechart
''', '__APPI_LAW__', appInsightsLawName)

var slowestOpsQuery = replace('''workspace("__APPI_LAW__").AppRequests
| summarize AvgDuration = round(avg(DurationMs), 1), Requests = count() by OperationName
| top 10 by AvgDuration desc
''', '__APPI_LAW__', appInsightsLawName)

var appiDetailQuery = replace('''workspace("__APPI_LAW__").AppRequests
| summarize Failed = countif(Success == false), OK = countif(Success == true) by bin(TimeGenerated, 5m)
| render timechart
''', '__APPI_LAW__', appInsightsLawName)

var alertActivityQuery = '''AzureActivity
| where CategoryValue == "Alert"
| project TimeGenerated, Operation = OperationNameValue, Status = ActivityStatusValue, Caller
| order by TimeGenerated desc
| take 25
'''

var fabricCapacityHealthQuery = replace('''resources
| where type =~ "microsoft.fabric/capacities"
| where resourceGroup =~ "__RESOURCE_GROUP__"
| extend CapacityState = tostring(properties.state), ProvisioningState = tostring(properties.provisioningState)
| extend Status = case(
  ProvisioningState !~ "Succeeded", "🔴",
  CapacityState =~ "Active", "🟢",
  CapacityState in~ ("Paused", "Suspended"), "🟠",
  "⚪")
| project Status,
      ResourceType = "Microsoft Fabric F2",
      Capacity = name,
      State = CapacityState,
      Provisioning = ProvisioningState,
      Region = location,
          SKU = tostring(sku.name)
''', '__RESOURCE_GROUP__', resourceGroup().name)

var dataIngestionQuery = '''Usage
| summarize IngestedMB = round(sum(Quantity), 2) by DataType
| where IngestedMB > 0.01
| top 15 by IngestedMB desc
| render barchart
'''

// ---------------------------------------------------------------
// Workbook layout
// ---------------------------------------------------------------
var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    // ── Header ──────────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '## 🚦 Azure Monitor Lab — Health Dashboard\n\nOne-glance overview of every resource in the demo lab.\n\n🟢 Healthy — 🟠 Warning — 🔴 Critical'
      }
      name: 'header'
    }
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          {
            id: 'p_timeRange'
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            type: 4
            isRequired: true
            value: { durationMs: 3600000 }
            typeSettings: {
              selectableValues: [
                { durationMs: 900000 }
                { durationMs: 1800000 }
                { durationMs: 3600000 }
                { durationMs: 14400000 }
                { durationMs: 86400000 }
              ]
            }
          }
        ]
        style: 'pills'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'parameters'
    }
    // ── Summary tiles ───────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: summaryTilesQuery
        size: 4
        title: 'Environment at a Glance'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'tiles'
        tileSettings: {
          titleContent: {
            columnMatch: 'Metric'
            formatter: 1
          }
          leftContent: {
            columnMatch: 'Value'
            formatter: 12
            formatOptions: {
              palette: 'auto'
            }
            numberFormat: {
              unit: 0
              options: {
                style: 'decimal'
                maximumFractionDigits: 0
              }
            }
          }
          secondaryContent: {
            columnMatch: 'Suffix'
            formatter: 1
          }
          showBorder: true
        }
      }
      name: 'summaryTiles'
    }
    // ── Traffic lights grid ─────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: queryFinal
        size: 1
        title: 'Resource Health — Traffic Lights'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
        gridSettings: {
          rowLimit: 200
          filter: true
        }
      }
      name: 'trafficLights'
    }
    // ── Infrastructure Trends ───────────────────────────────────
    {
      type: 1
      content: {
        json: '---\n## 📈 Infrastructure Trends'
      }
      name: 'infraHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: vmCpuQuery
        size: 0
        title: 'VM CPU Utilization (%)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'vmCpu'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: vmMemoryQuery
        size: 0
        title: 'VM Available Memory (MB)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'vmMemory'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: aksNodeCpuQuery
        size: 0
        title: 'AKS Node CPU (millicores)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'aksNodeCpu'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: aksPodRestartsQuery
        size: 0
        title: 'AKS Pod Restarts'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'aksPodRestarts'
    }
    // ── Application Performance ─────────────────────────────────
    {
      type: 1
      content: {
        json: '---\n## 🌐 Application Performance'
      }
      name: 'appHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: responseTimeQuery
        size: 0
        title: 'Response Time — P50 / P95 / P99 (ms)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'responseTime'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: slowestOpsQuery
        size: 0
        title: 'Slowest Operations (avg ms)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
      }
      customWidth: '50'
      name: 'slowestOps'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'AppServiceHTTPLogs\n| summarize Hits = count() by tostring(ScStatus), bin(TimeGenerated, 5m)\n| render columnchart'
        size: 0
        title: 'App Service HTTP Status Codes'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'appServiceStatus'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: appiDetailQuery
        size: 0
        title: 'App Insights — Requests OK vs Failed'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'appiRequests'
    }
    // ── Platform Health ─────────────────────────────────────────
    {
      type: 1
      content: {
        json: '---\n## ⚡ Platform Health'
      }
      name: 'platformHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: alertActivityQuery
        size: 0
        title: 'Recent Alert Activity'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
      }
      customWidth: '50'
      name: 'alertActivity'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: dataIngestionQuery
        size: 0
        title: 'Data Ingestion (MB by table)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      customWidth: '50'
      name: 'dataIngestion'
    }
    // ── Fabric Real-Time Intelligence Health ───────────────────
    {
      type: 1
      content: {
        json: '---\n## Microsoft Fabric Real-Time Intelligence Health\n\nThe capacity is discovered dynamically. This section is empty when Stage Fabric is disabled. Eventstream item and data-flow health remain available in the Fabric workspace.'
      }
      name: 'fabricHealthHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: fabricCapacityHealthQuery
        size: 1
        title: 'Fabric F2 Capacity Health'
        queryType: 1
        resourceType: 'microsoft.resourcegraph/resources'
        visualization: 'table'
        gridSettings: {
          rowLimit: 10
          filter: true
        }
      }
      name: 'fabricCapacityHealth'
    }
    // ── Detail Panels ───────────────────────────────────────────
    {
      type: 1
      content: {
        json: '---\n## 🔎 Detail Panels\n\nDrill-down views that explain *why* a row is 🔴 or 🟠.'
      }
      name: 'detailHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'Heartbeat\n| where TimeGenerated > ago(1h)\n| summarize LastBeat = max(TimeGenerated) by Computer, OSType\n| extend SecondsSince = datetime_diff("second", now(), LastBeat)\n| order by SecondsSince desc'
        size: 0
        title: 'VM Heartbeat Detail'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
      }
      customWidth: '50'
      name: 'vmDetail'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'KubePodInventory\n| where TimeGenerated > ago(15m)\n| summarize arg_max(TimeGenerated, *) by Name\n| project Namespace, Name, PodStatus, ContainerRestartCount, ContainerStatus, Computer\n| order by toint(ContainerRestartCount) desc'
        size: 0
        title: 'AKS Pod State Detail'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
      }
      customWidth: '50'
      name: 'aksDetail'
    }
  ]
  fallbackResourceIds: [
    centralLawId
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Azure Monitor Lab — Health Dashboard'
    description: 'Comprehensive health dashboard with traffic lights, infrastructure trends, application performance, and platform monitoring.'
    serializedData: string(workbookContent)
    category: 'workbook'
    sourceId: centralLawId
    version: '2.0'
  }
}

output id string = workbook.id
output name string = workbook.name
