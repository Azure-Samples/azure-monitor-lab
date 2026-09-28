// =====================================================================================
// Cost-of-Monitoring Workbook
//
// One-glance FinOps view of LAW ingestion: GB/day per table, top growers, daily-cap
// burn, and per-solution cost. Pulls entirely from the built-in `Usage` table.
// =====================================================================================

@description('Workbook resource name (must be GUID-like).')
param name string

@description('Region.')
param location string

@description('Central LAW resource ID (workbook scope).')
param centralLawId string

@description('Configured daily ingestion cap (GB) for the central LAW. Set to -1 when disabled.')
param dailyCapGb int = 1

@description('Resource tags.')
param tags object = {}

var ingestByTableQuery = '''Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize GB = round(sum(Quantity) / 1024.0, 3) by DataType, bin(TimeGenerated, 1d)
| order by TimeGenerated desc, GB desc
| render columnchart kind=stacked
'''

var topTablesQuery = '''Usage
| where TimeGenerated > ago(24h)
| where IsBillable == true
| summarize GB_24h = round(sum(Quantity) / 1024.0, 3) by DataType
| top 15 by GB_24h desc
| render barchart
'''

var dailyTotalQuery = '''Usage
| where IsBillable == true
| summarize GB = round(sum(Quantity) / 1024.0, 3) by bin(TimeGenerated, 1d)
| order by TimeGenerated asc
| render timechart
'''

var perSolutionQuery = '''Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize GB = round(sum(Quantity) / 1024.0, 3) by Solution
| top 10 by GB desc
| render piechart
'''

var capBurnQuery = replace('''Usage
| where IsBillable == true
| where TimeGenerated >= startofday(now())
| summarize TodayGB = round(sum(Quantity) / 1024.0, 3)
| extend CapGB = toreal(__DAILY_CAP_GB__)
| extend PercentOfCap = iff(CapGB > 0, round(100.0 * TodayGB / CapGB, 1), real(null))
| project Metric = pack_array("Today (GB)", "Daily cap (GB)", "% of cap used"),
          Value  = pack_array(TodayGB, CapGB, PercentOfCap)
| mv-expand Metric to typeof(string), Value to typeof(real)
''', '__DAILY_CAP_GB__', string(dailyCapGb))

var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      content: {
        json: '## 💰 Central LAW ingestion volume\n\nThis workbook reads only the central Log Analytics workspace `Usage` table. It does **not** include compute, App Service, Grafana, Event Hubs, ACR, disks/IPs, network monitoring, alerts, tests, other workspaces, or optional agents, and it does not reconcile the Azure bill. Use it to find candidates for **DCR transformations** and **Basic Logs**, then use [Azure Cost Management](https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis) for actual and forecast charges.'
      }
      name: 'header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: capBurnQuery
        size: 4
        title: 'Daily cap burn (today)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'tiles'
      }
      name: 'capBurn'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: dailyTotalQuery
        size: 1
        title: 'Total GB ingested per day (all tables)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'dailyTotal'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: topTablesQuery
        size: 1
        title: 'Top tables (last 24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'topTables'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: ingestByTableQuery
        size: 1
        title: 'Stacked daily ingestion by table (7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'ingestByTable'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: perSolutionQuery
        size: 1
        title: 'GB by solution (7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'perSolution'
    }
  ]
  fallbackResourceIds: [ centralLawId ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: '💰 Azure Monitor Lab — Central LAW ingestion volume'
    serializedData: string(workbookContent)
    category: 'workbook'
    sourceId: centralLawId
    version: '1.0'
  }
}

output id string = workbook.id
output name string = workbook.name
