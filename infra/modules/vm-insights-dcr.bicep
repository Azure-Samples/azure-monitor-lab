@description('Classic VM Insights data collection rule name.')
param name string

@description('Region.')
param location string

@description('Destination Log Analytics workspace resource ID.')
param centralLawId string

@description('Resource tags.')
param tags object = {}

// The DCR API wraps transient InvalidOutputTable readiness errors in InvalidPayload.
// Retry that outer code only for this fixed payload; permanent errors still fail.
@retryOn(['InvalidPayload'], 30)
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: name
  location: location
  tags: tags
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
          workspaceResourceId: centralLawId
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

output id string = dcr.id
