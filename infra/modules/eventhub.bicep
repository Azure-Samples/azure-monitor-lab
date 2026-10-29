// =====================================================================================
// Event Hub Namespace + Hub — used as the second destination for diagnostic
// settings (SIEM/SOAR fan-out demo) and as a Data Export target option.
// Basic tier, single partition — cheap and demo-grade.
// =====================================================================================

@description('Event Hub Namespace name (globally unique, 6-50 chars).')
param namespaceName string

@description('Region.')
param location string

@description('Central LAW resource ID — diag settings on the namespace itself.')
param centralLawId string

@description('Resource tags.')
param tags object = {}

resource ns 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: false
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: '1.2'
  }
}

resource hub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ns
  name: 'diagnostics'
  properties: {
    messageRetentionInDays: 1
    partitionCount: 1
  }
}

// Authorisation rule used by diag-settings + data-export to send into the hub.
resource sendRule 'Microsoft.EventHub/namespaces/authorizationRules@2024-01-01' = {
  parent: ns
  name: 'diagnostics-send'
  properties: {
    rights: [ 'Send' ]
  }
}

// Least-privilege consumer rule used by the optional Fabric Eventstream source.
// The connection key is entered interactively in Fabric and is never output by IaC.
resource listenRule 'Microsoft.EventHub/namespaces/authorizationRules@2024-01-01' = {
  parent: ns
  name: 'diagnostics-listen'
  properties: {
    rights: [ 'Listen' ]
  }
}

// Diag settings on the namespace itself (operational telemetry to LAW).
resource diagNs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: ns
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

output namespaceId string   = ns.id
output namespaceName string = ns.name
output hubName string       = hub.name
output sendRuleId string    = sendRule.id
output listenRuleName string = listenRule.name
