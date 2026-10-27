@description('Sentinel-enabled Log Analytics workspace name.')
param workspaceName string

resource lawRef 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource ruleDelete 'Microsoft.SecurityInsights/alertRules@2024-09-01' = {
  scope: lawRef
  name: '0a1b2c3d-amlab-rg-delete-alert'
  kind: 'Scheduled'
  properties: {
    displayName: 'amlab — Resource deletion in lab RG'
    description: 'Demo Sentinel rule: any successful delete operation in the lab RG over the last 1h.'
    severity: 'Medium'
    enabled: true
    query: 'AzureActivity\n| where TimeGenerated > ago(1h)\n| where ActivityStatusValue == "Success"\n| where OperationNameValue endswith "/delete"\n| project TimeGenerated, Caller, OperationNameValue, _ResourceId'
    queryFrequency: 'PT15M'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [ 'Impact' ]
    techniques: [ 'T1485' ]
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          { identifier: 'FullName', columnName: 'Caller' }
        ]
      }
      {
        entityType: 'AzureResource'
        fieldMappings: [
          { identifier: 'ResourceId', columnName: '_ResourceId' }
        ]
      }
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'AnyAlert'
      }
    }
  }
}

output ruleName string = ruleDelete.name
