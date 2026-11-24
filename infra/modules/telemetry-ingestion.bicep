// Isolated Logs Ingestion API scenario. No sender, identity, traffic or existing DCR is modified.
// The three independently addressed DCRs avoid mutable live profile switching.
@minLength(3)
@maxLength(8)
param namePrefix string
param location string
param centralLawId string
param centralLawName string
param tags object = {}
param enableAuxiliary bool = false
@description('Experimental direct OTLP logs DCR only; does not install or configure a Collector.')
param enableNativeOtlp bool = false
@description('Optional Microsoft Entra service principal/managed identity object ID. Grants Monitoring Metrics Publisher only on these scenario DCRs; empty grants no identity.')
param senderPrincipalId string = ''

var inputStream = 'Custom-TelemetryIngestion'
var inputColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'EventId', type: 'string' }
  { name: 'SampleSetId', type: 'string' }
  { name: 'Severity', type: 'string' }
  { name: 'Workload', type: 'string' }
  { name: 'Message', type: 'string' }
  { name: 'SyntheticUser', type: 'string' }
  { name: 'DebugField', type: 'string' }
]
// The table contract is identical across profiles. DebugField never reaches the table.
var outputColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'EventId', type: 'string' }
  { name: 'SampleSetId', type: 'string' }
  { name: 'Severity', type: 'string' }
  { name: 'NormalizedSeverity', type: 'string' }
  { name: 'Workload', type: 'string' }
  { name: 'Message', type: 'string' }
  { name: 'SyntheticUser', type: 'string' }
]
var projection = ' | project TimeGenerated, RunId, EventId, SampleSetId, Severity, NormalizedSeverity = tolower(Severity), Workload, Message, SyntheticUser = "[REDACTED]"'
var baselineTransform = 'source | project TimeGenerated, RunId, EventId, SampleSetId, Severity, NormalizedSeverity = Severity, Workload, Message, SyntheticUser'
var operationalTransform = 'source | where Severity in ("Error", "Warning")${projection}'
var verboseTransform = 'source | where Severity == "Debug"${projection}'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

resource operational 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'TelemetryIngestionOperational_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'TelemetryIngestionOperational_CL'
      columns: outputColumns
    }
    retentionInDays: 30
  }
}

resource diagnostic 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'TelemetryIngestionDiagnostic_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'TelemetryIngestionDiagnostic_CL'
      columns: outputColumns
    }
    retentionInDays: 30
  }
}

resource verbose 'Microsoft.OperationalInsights/workspaces/tables@2025-07-01' = if (enableAuxiliary) {
  parent: law
  name: 'TelemetryIngestionVerbose_CL'
  properties: {
    plan: 'Auxiliary'
    schema: {
      name: 'TelemetryIngestionVerbose_CL'
      columns: outputColumns
    }
    totalRetentionInDays: 30
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${namePrefix}-telemetry-ingestion'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource transformed 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${namePrefix}-telemetry-ingestion'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-TelemetryIngestion': {
        columns: inputColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: operationalTransform
        outputStream: 'Custom-TelemetryIngestionOperational_CL'
      }
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: operationalTransform
        outputStream: 'Custom-TelemetryIngestionDiagnostic_CL'
      }
    ]
  }
  dependsOn: [operational, diagnostic]
}

resource baseline 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${namePrefix}-telemetry-ingestion-baseline'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-TelemetryIngestion': {
        columns: inputColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: baselineTransform
        outputStream: 'Custom-TelemetryIngestionOperational_CL'
      }
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: baselineTransform
        outputStream: 'Custom-TelemetryIngestionDiagnostic_CL'
      }
    ]
  }
  dependsOn: [operational, diagnostic]
}

resource tiered 'Microsoft.Insights/dataCollectionRules@2023-03-11' = if (enableAuxiliary) {
  name: 'dcr-${namePrefix}-telemetry-ingestion-tiered'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-TelemetryIngestion': {
        columns: inputColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: operationalTransform
        outputStream: 'Custom-TelemetryIngestionOperational_CL'
      }
      {
        streams: [inputStream]
        destinations: ['centralLaw']
        transformKql: verboseTransform
        outputStream: 'Custom-TelemetryIngestionVerbose_CL'
      }
    ]
  }
  dependsOn: [operational, verbose]
}

// Native OTLP directDataSources cannot be used with kind 'Direct' (Log Ingestion API).
// Use the DCE-backed OTLP rule shape without a kind, as in the published OTLP template.
resource nativeOtlp 'Microsoft.Insights/dataCollectionRules@2024-03-11' = if (enableNativeOtlp) {
  name: 'dcr-${namePrefix}-telemetry-ingestion-otlp'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    directDataSources: {
      otelLogs: [
        {
          name: 'nativeOtlpLogs'
          streams: ['Microsoft-OTel-Logs']
          enrichWithResourceAttributes: ['*']
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'nativeLogs'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-OTel-Logs']
        destinations: ['nativeLogs']
      }
    ]
  }
}

var publisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
resource transformedSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(senderPrincipalId)) {
  name: guid(transformed.id, senderPrincipalId, publisherRoleId)
  scope: transformed
  properties: {
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: publisherRoleId
  }
}
resource baselineSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(senderPrincipalId)) {
  name: guid(baseline.id, senderPrincipalId, publisherRoleId)
  scope: baseline
  properties: {
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: publisherRoleId
  }
}
// An unconditional existing reference keeps ARM's role-assignment scope explicit
// even when the underlying DCR is created conditionally.
resource tieredScope 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: 'dcr-${namePrefix}-telemetry-ingestion-tiered'
}
resource tieredSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableAuxiliary && !empty(senderPrincipalId)) {
  name: guid(tieredScope.id, senderPrincipalId, publisherRoleId)
  scope: tieredScope
  properties: {
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: publisherRoleId
  }
  dependsOn: [tiered]
}
resource nativeOtlpScope 'Microsoft.Insights/dataCollectionRules@2024-03-11' existing = {
  name: 'dcr-${namePrefix}-telemetry-ingestion-otlp'
}
resource nativeOtlpSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableNativeOtlp && !empty(senderPrincipalId)) {
  name: guid(nativeOtlpScope.id, senderPrincipalId, publisherRoleId)
  scope: nativeOtlpScope
  properties: {
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: publisherRoleId
  }
  dependsOn: [nativeOtlp]
}

output dceId string = dce.id
output dceEndpoint string = dce.properties.logsIngestion.endpoint
output inputStream string = inputStream
output baselineDcrId string = baseline.id
output baselineDcrImmutableId string = baseline.properties.immutableId
output transformedDcrId string = transformed.id
output transformedDcrImmutableId string = transformed.properties.immutableId
output tieredDcrId string = enableAuxiliary ? tiered!.id : ''
output tieredDcrImmutableId string = enableAuxiliary ? tiered!.properties.immutableId : ''
output nativeOtlpDcrId string = enableNativeOtlp ? nativeOtlp!.id : ''
output nativeOtlpDcrImmutableId string = enableNativeOtlp ? nativeOtlp!.properties.immutableId : ''
// The Learn endpoint spells OTLP differently from the DCR stream. Verify live before use.
output nativeOtlpLogsEndpoint string = enableNativeOtlp ? '${dce.properties.logsIngestion.endpoint}/datacollectionRules/${nativeOtlp!.properties.immutableId}/streams/Microsoft-OTLP-Logs/otlp/v1/logs' : ''
output nativeOtlpReadiness string = enableNativeOtlp ? 'EXPERIMENTAL: no Collector is installed or configured. Deploy an OTel Collector with Azure authentication, use the native OTLP logs endpoint and DCR-scoped sender role, and verify live ingestion and the documented OTLP/OTel stream spelling before claiming readiness.' : ''
output operationalTable string = operational.name
output operationalTableId string = operational.id
output operationalTablePlan string = 'Analytics'
output diagnosticTable string = diagnostic.name
output diagnosticTableId string = diagnostic.id
output diagnosticTablePlan string = 'Analytics'
output verboseTable string = enableAuxiliary ? verbose!.name : ''
output verboseTableId string = enableAuxiliary ? verbose!.id : ''
output verboseTablePlan string = enableAuxiliary ? 'Auxiliary' : ''
