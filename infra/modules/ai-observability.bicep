// =====================================================================================
// AI observability artifacts — deployed with the optional AI stage.
//   - Query Pack: the GenAI usage/health KQL queries (infra/modules/ai-kql/*.kql)
//     saved into Log Analytics (surface under the App Insights Logs > Queries hub).
//   - Workbook: the importable FinOps workbook (token/model/health, illustrative PTU inputs),
//     deployed as a shared workbook scoped to the lab Application Insights.
//
// Token-spike/anomaly alerting lives in foundry.bicep (metric alerts on the account's
// TotalTokens); this module is queries + workbook only.
// =====================================================================================

@description('Location for the query pack and workbook.')
param location string

@description('App Insights component resource id (workbook sourceId).')
param appInsightsId string

@description('Resource tags.')
param tags object = {}

// Each query is embedded at compile time from the .kql files in ai-kql/.
var queries = [
  { key: 'token-usage-by-agent-hourly', display: 'Token usage by agent (hourly)', body: loadTextContent('ai-kql/token-usage-by-agent-hourly.kql') }
  { key: 'cost-by-agent-daily', display: 'Token usage by agent (24h)', body: loadTextContent('ai-kql/cost-by-agent-daily.kql') }
  { key: 'cost-trend-daily-7d', display: 'Token usage trend (7d)', body: loadTextContent('ai-kql/cost-trend-daily-7d.kql') }
  { key: 'cost-per-successful-request', display: 'Tokens per successful request', body: loadTextContent('ai-kql/cost-per-successful-request.kql') }
  { key: 'cached-token-ratio', display: 'Cached-input token ratio', body: loadTextContent('ai-kql/cached-token-ratio.kql') }
  { key: 'model-router-distribution', display: 'Model router routed-model distribution', body: loadTextContent('ai-kql/model-router-distribution.kql') }
  { key: 'finish-reason-length-rate', display: 'Truncated-response rate', body: loadTextContent('ai-kql/finish-reason-length-rate.kql') }
  { key: 'latency-percentiles-by-agent', display: 'Latency percentiles by agent', body: loadTextContent('ai-kql/latency-percentiles-by-agent.kql') }
  { key: 'tool-error-rate', display: 'Tool error rate', body: loadTextContent('ai-kql/tool-error-rate.kql') }
  { key: 'ptu-breakeven', display: 'Illustrative PTU comparison (set rates)', body: loadTextContent('ai-kql/ptu-breakeven.kql') }
  { key: 'chart-tokens-by-agent-stacked', display: 'Chart: tokens by agent (stacked)', body: loadTextContent('ai-kql/chart-tokens-by-agent-stacked.kql') }
  { key: 'chart-cost-by-agent-bar', display: 'Chart: tokens by agent (bar)', body: loadTextContent('ai-kql/chart-cost-by-agent-bar.kql') }
  { key: 'chart-cost-share-pie', display: 'Chart: token share (pie)', body: loadTextContent('ai-kql/chart-cost-share-pie.kql') }
  { key: 'chart-tokens-trend-timechart', display: 'Chart: completion tokens per hour', body: loadTextContent('ai-kql/chart-tokens-trend-timechart.kql') }
]

resource pack 'Microsoft.OperationalInsights/queryPacks@2019-09-01' = {
  name: 'qp-ai-finops'
  location: location
  tags: tags
  properties: {}
}

resource packQueries 'Microsoft.OperationalInsights/queryPacks/queries@2019-09-01' = [for q in queries: {
  parent: pack
  name: guid(pack.id, q.key)
  properties: {
    displayName: q.display
    body: q.body
    related: {
      categories: [ 'applications' ]
      resourceTypes: [ 'microsoft.insights/components' ]
    }
  }
}]

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'ai-finops-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'AI FinOps — Foundry Agents'
    serializedData: replace(replace(loadTextContent('ai-finops-workbook.json'), '__APPINSIGHTS_ID__', appInsightsId), '__GATEWAY_APPINSIGHTS_ID__', '')
    category: 'workbook'
    sourceId: toLower(appInsightsId)
    version: '1.0'
  }
}

output queryPackName string = pack.name
output workbookId string = workbook.id
