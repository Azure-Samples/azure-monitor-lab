// =====================================================================================
// FEATURE 2 — AMBA-aligned baseline alerts
//
// A curated set of best-practice metric alerts that mirror what the official
// Azure Monitor Baseline Alerts (https://aka.ms/amba) initiative would deploy for
// this RG. Kept as raw Bicep (not policy initiative) so it's transparent for the demo.
//
// All alerts are wired to the existing Action Group.
// =====================================================================================

@description('Action Group resource ID to notify.')
param actionGroupId string

@description('Resource IDs of VMs to monitor (multi-resource alerts).')
param vmIds array = []

@description('Web App resource ID.')
param webAppId string

@description('AKS cluster resource ID.')
param aksId string

@description('App Service Plan resource ID.')
param appPlanId string

@description('Region of the Web App / App Service Plan (metric alert targetResourceRegion must match the target).')
param webAppRegion string = location

@description('Region (for log-query / multi-resource metric alerts).')
param location string

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// VM baseline (memory, disk, network)
// ---------------------------------------------------------------------------------
resource amba_vm_memory 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(vmIds)) {
  name: 'amba-vm-available-memory-low'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: VM available memory < 10% of total for 5 min'
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
          name: 'AvailableMem'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Available Memory Bytes'
          operator: 'LessThan'
          threshold: 200000000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_vm_net_in 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (vmId, i) in vmIds: {
  name: 'amba-vm-network-in-spike-${i}'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: VM Network In > 200 MB in 5 min (per-VM; this metric does not support multi-resource scope)'
    severity: 3
    enabled: true
    scopes: [ vmId ]
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'NetIn'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Network In Total'
          operator: 'GreaterThan'
          threshold: 209715200
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}]

// ---------------------------------------------------------------------------------
// App Service baseline (response time, requests, memory)
// ---------------------------------------------------------------------------------
resource amba_app_resptime 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-webapp-response-time'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: App Service average response time > 5 s for 5 min'
    severity: 3
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
          name: 'AvgResponseTime'
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'HttpResponseTime'
          operator: 'GreaterThan'
          threshold: 5000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_app_4xx 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-webapp-4xx-rate'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: App Service > 100 HTTP 4xx in 5 min (excluding intentional load gen 404 noise will still trip; tune as needed)'
    severity: 3
    enabled: true
    scopes: [ webAppId ]
    targetResourceType: 'Microsoft.Web/sites'
    targetResourceRegion: webAppRegion
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Http4xx'
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'Http4xx'
          operator: 'GreaterThan'
          threshold: 100
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          skipMetricValidation: true
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_plan_cpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-appplan-cpu-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: App Service Plan CPU > 80% for 10 min'
    severity: 2
    enabled: true
    scopes: [ appPlanId ]
    targetResourceType: 'Microsoft.Web/serverfarms'
    targetResourceRegion: webAppRegion
    evaluationFrequency: 'PT1M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'PlanCpu'
          metricNamespace: 'Microsoft.Web/serverfarms'
          metricName: 'CpuPercentage'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_plan_mem 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-appplan-memory-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: App Service Plan memory > 85% for 10 min'
    severity: 2
    enabled: true
    scopes: [ appPlanId ]
    targetResourceType: 'Microsoft.Web/serverfarms'
    targetResourceRegion: webAppRegion
    evaluationFrequency: 'PT1M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'PlanMem'
          metricNamespace: 'Microsoft.Web/serverfarms'
          metricName: 'MemoryPercentage'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

// ---------------------------------------------------------------------------------
// AKS baseline (memory, disk, pod ready %)
// ---------------------------------------------------------------------------------
resource amba_aks_memory 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-aks-memory-working-set-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: AKS node memory working set > 85% for 10 min'
    severity: 2
    enabled: true
    scopes: [ aksId ]
    targetResourceType: 'Microsoft.ContainerService/managedClusters'
    targetResourceRegion: location
    evaluationFrequency: 'PT1M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'MemWorkingSet'
          metricNamespace: 'Microsoft.ContainerService/managedClusters'
          metricName: 'node_memory_working_set_percentage'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_aks_disk 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-aks-disk-used-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: AKS node disk used > 80% for 10 min'
    severity: 2
    enabled: true
    scopes: [ aksId ]
    targetResourceType: 'Microsoft.ContainerService/managedClusters'
    targetResourceRegion: location
    evaluationFrequency: 'PT1M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DiskUsed'
          metricNamespace: 'Microsoft.ContainerService/managedClusters'
          metricName: 'node_disk_usage_percentage'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

resource amba_aks_pods_ready 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'amba-aks-pods-not-ready'
  location: 'global'
  tags: tags
  properties: {
    description: 'AMBA: AKS pods in Not Ready state > 0 for 5 min'
    severity: 2
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
          name: 'PodsNotReady'
          metricNamespace: 'Microsoft.ContainerService/managedClusters'
          metricName: 'kube_pod_status_ready'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: actionGroupId } ]
  }
}

output count int = 9
