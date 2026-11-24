targetScope = 'resourceGroup'

@description('Must match the Stage A central workspace region.')
param location string = resourceGroup().location
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'
@description('Explicit opt-in to a separate Auxiliary table and tiered DCR. Verify plan availability in the chosen region before deployment.')
param enableAuxiliary bool = false
@description('Experimental native OTLP logs direct ingestion DCR; does not deploy a Collector.')
param enableNativeOtlp bool = false
@description('Optional managed identity/service principal object ID granted Monitoring Metrics Publisher on scenario DCRs. Empty: assign manually.')
param senderPrincipalId string = ''
param centralWorkspaceId string = resourceId('Microsoft.OperationalInsights/workspaces', 'law-${namePrefix}-central-${take(uniqueString(resourceGroup().id), 5)}')
param centralWorkspaceName string = 'law-${namePrefix}-central-${take(uniqueString(resourceGroup().id), 5)}'
param tags object = {}

module ingestion '../modules/telemetry-ingestion.bicep' = {
  name: 'telemetry-ingestion'
  params: {
    namePrefix: namePrefix
    location: location
    centralLawId: centralWorkspaceId
    centralLawName: centralWorkspaceName
    enableAuxiliary: enableAuxiliary
    enableNativeOtlp: enableNativeOtlp
    senderPrincipalId: senderPrincipalId
    tags: tags
  }
}

output dceId string = ingestion.outputs.dceId
output dceEndpoint string = ingestion.outputs.dceEndpoint
output inputStream string = ingestion.outputs.inputStream
output baselineDcrId string = ingestion.outputs.baselineDcrId
output baselineDcrImmutableId string = ingestion.outputs.baselineDcrImmutableId
output transformedDcrId string = ingestion.outputs.transformedDcrId
output transformedDcrImmutableId string = ingestion.outputs.transformedDcrImmutableId
output tieredDcrId string = ingestion.outputs.tieredDcrId
output tieredDcrImmutableId string = ingestion.outputs.tieredDcrImmutableId
output nativeOtlpDcrId string = ingestion.outputs.nativeOtlpDcrId
output nativeOtlpDcrImmutableId string = ingestion.outputs.nativeOtlpDcrImmutableId
output nativeDcrId string = enableNativeOtlp ? ingestion.outputs.nativeOtlpDcrId : ''
output nativeDcrImmutableId string = enableNativeOtlp ? ingestion.outputs.nativeOtlpDcrImmutableId : ''
output nativeDceEndpoint string = enableNativeOtlp ? ingestion.outputs.dceEndpoint : ''
output nativeOtlpLogsEndpoint string = ingestion.outputs.nativeOtlpLogsEndpoint
output nativeOtlpReadiness string = ingestion.outputs.nativeOtlpReadiness
output operationalTable string = ingestion.outputs.operationalTable
output operationalTableId string = ingestion.outputs.operationalTableId
output operationalTablePlan string = ingestion.outputs.operationalTablePlan
output diagnosticTable string = ingestion.outputs.diagnosticTable
output diagnosticTableId string = ingestion.outputs.diagnosticTableId
output diagnosticTablePlan string = ingestion.outputs.diagnosticTablePlan
output verboseTable string = ingestion.outputs.verboseTable
output verboseTableId string = ingestion.outputs.verboseTableId
output verboseTablePlan string = ingestion.outputs.verboseTablePlan
