@description('Region of the monitored VMs.')
param location string

@minLength(1)
param vmIds array

param actionGroupId string
param tags object = {}

resource alert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-vm-cpu-dynamic'
  location: 'global'
  tags: tags
  properties: {
    description: 'Lab VM CPU above its ML-learned baseline (medium sensitivity)'
    severity: 3
    enabled: true
    scopes: vmIds
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
      { actionGroupId: actionGroupId }
    ]
  }
}
