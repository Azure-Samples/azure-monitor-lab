@description('Region for alert rules (must be a region that supports metric/scheduled query alerts).')
param location string

@description('Action group resource ID.')
param actionGroupId string

@description('AKS resource ID.')
param aksId string

@description('Web App resource ID.')
param webAppId string

@description('Region of the Web App / App Service Plan (metric alert targetResourceRegion must match the target).')
param webAppRegion string = location

@description('App Insights resource ID.')
param appInsightsId string

@description('Linux VM resource ID (empty if not deployed).')
param linuxVmId string = ''

@description('Windows VM resource ID (empty if not deployed).')
param windowsVmId string = ''

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------
// CPU > 80% for any of the lab VMs (multi-resource metric alert)
// ---------------------------------------------------------------------------
var vmIds = filter([linuxVmId, windowsVmId], id => !empty(id))

resource alertVmCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(vmIds)) {
  name: 'alert-vm-cpu-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'Lab VM CPU > 80% for 5 minutes'
    severity: 2
    enabled: true
    scopes: vmIds
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CpuPercentage'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroupId }
    ]
  }
}

// ---------------------------------------------------------------------------
// Web App: HTTP 5xx > 5 in 5 min
// ---------------------------------------------------------------------------
resource alertWebApp5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-webapp-5xx'
  location: 'global'
  tags: tags
  properties: {
    description: 'Web App returned more than 5 HTTP 5xx in last 5 minutes'
    severity: 2
    enabled: true
    scopes: [ webAppId ]
    targetResourceType: 'Microsoft.Web/sites'
    targetResourceRegion: webAppRegion
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Http5xx'
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'Http5xx'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroupId }
    ]
  }
}

// ---------------------------------------------------------------------------
// AKS: Container CPU > 80% (multi-dimensional metric, Container Insights namespace)
// ---------------------------------------------------------------------------
resource alertAksCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-aks-node-cpu-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'AKS node CPU usage > 80% for 5 minutes'
    severity: 3
    enabled: true
    scopes: [ aksId ]
    targetResourceType: 'Microsoft.ContainerService/managedClusters'
    targetResourceRegion: location
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'NodeCpu'
          metricNamespace: 'Microsoft.ContainerService/managedClusters'
          metricName: 'node_cpu_usage_percentage'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroupId }
    ]
  }
}

// ---------------------------------------------------------------------------
// App Insights log alert: failed requests > 10 in 5 min
// ---------------------------------------------------------------------------
resource alertAppInsightsFailures 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-appinsights-failed-requests'
  location: location
  tags: tags
  properties: {
    description: 'App Insights: more than 10 failed requests in 5 minutes'
    enabled: true
    severity: 2
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where success == false | summarize Failed = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 10
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}

resource alertAgentTaskFailures 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-agent-task-failures'
  location: location
  tags: tags
  properties: {
    description: 'Agent tasks are technically available but fail semantic task completion.'
    enabled: true
    severity: 2
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'dependencies | where type == "GenAI" | extend TaskSuccess = tostring(customDimensions["task.success"]) | where TaskSuccess == "false" | summarize FailedTasks = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 2
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}

resource alertAgentEfficiencyRegression 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-agent-efficiency-regression'
  location: location
  tags: tags
  properties: {
    description: 'Agent tasks exceed performance budgets or amplify work through retries.'
    enabled: true
    severity: 3
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'dependencies | where type == "GenAI" | extend PerformanceSuccess = tostring(customDimensions["performance.success"]), RetryCount = toint(customDimensions["retry.count"]) | where PerformanceSuccess == "false" or RetryCount > 1 | summarize DegradedTasks = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}

// ---------------------------------------------------------------------------
// AKS: pod restart spike (log alert against ContainerInsights KubePodInventory)
// ---------------------------------------------------------------------------
resource alertAksPodRestarts 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-aks-pod-restart-spike'
  location: location
  tags: tags
  properties: {
    description: 'AKS pod restart count > 5 in any pod over 15 minutes'
    enabled: true
    severity: 2
    scopes: [ aksId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'KubePodInventory | where TimeGenerated > ago(15m) | summarize Restarts = sum(toint(ContainerRestartCount)) by Name | where Restarts > 5'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}
