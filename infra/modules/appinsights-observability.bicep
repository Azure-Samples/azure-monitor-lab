@description('Location for the query pack and workbook.')
param location string

@description('Short lab name prefix.')
param namePrefix string

@description('Application Insights component resource ID.')
param appInsightsId string

@description('Resource tags.')
param tags object = {}

var queries = [
  { key: 'agent-task-health', display: 'Agent task health', body: loadTextContent('appinsights-kql/agent-task-health.kql') }
  { key: 'trace-timeline', display: 'End-to-end trace timeline', body: loadTextContent('appinsights-kql/trace-timeline.kql') }
  { key: 'broken-fixed-comparison', display: 'Broken versus fixed comparison', body: loadTextContent('appinsights-kql/broken-fixed-comparison.kql') }
  { key: 'retry-token-efficiency', display: 'Retry and token efficiency', body: loadTextContent('appinsights-kql/retry-token-efficiency.kql') }
  { key: 'trace-quality', display: 'Agent trace quality', body: loadTextContent('appinsights-kql/trace-quality.kql') }
  { key: 'version-cohort-impact', display: 'Version and cohort impact', body: loadTextContent('appinsights-kql/version-cohort-impact.kql') }
  { key: 'browser-to-agent', display: 'Browser-to-agent correlation', body: loadTextContent('appinsights-kql/browser-to-agent.kql') }
]

resource pack 'Microsoft.OperationalInsights/queryPacks@2019-09-01' = {
  name: 'qp-${namePrefix}-appinsights'
  location: location
  tags: tags
  properties: {}
}

resource packQueries 'Microsoft.OperationalInsights/queryPacks/queries@2019-09-01' = [for query in queries: {
  parent: pack
  name: guid(pack.id, query.key)
  properties: {
    displayName: query.display
    body: query.body
    related: {
      categories: [ 'applications' ]
      resourceTypes: [ 'microsoft.insights/components' ]
    }
  }
}]

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'appinsights-investigation-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'Application Insights — End-to-End Agent Investigation'
    serializedData: replace(loadTextContent('appinsights-investigation-workbook.json'), '__APPINSIGHTS_ID__', appInsightsId)
    category: 'workbook'
    sourceId: toLower(appInsightsId)
    version: '1.0'
  }
}

output queryPackName string = pack.name
output workbookId string = workbook.id
