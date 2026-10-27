@description('Data collection rule name for default VM OpenTelemetry metrics.')
param name string

@description('Region of the Azure Monitor workspace.')
param location string

@description('Existing Azure Monitor workspace resource ID for guest metrics.')
param monitoringAccountId string

@description('Resource tags.')
param tags object = {}

// Keep the default metric set: additional counters can incur ingestion charges.
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: 'Default OpenTelemetry guest metrics alongside classic VM Insights.'
    dataSources: {
      performanceCountersOTel: [
        {
          name: 'vmOtelSystemMetrics'
          streams: [ 'Microsoft-OtelPerfMetrics' ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'system.cpu.time'
            'system.memory.usage'
            'system.disk.io'
            'system.disk.operations'
            'system.disk.operation_time'
            'system.filesystem.usage'
            'system.network.io'
            'system.network.dropped'
            'system.network.errors'
            'system.uptime'
          ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'vmMetricsWorkspace'
          accountResourceId: monitoringAccountId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-OtelPerfMetrics' ]
        destinations: [ 'vmMetricsWorkspace' ]
      }
    ]
  }
}

output id string = dcr.id
