// =====================================================================================
// Log Analytics Data Export Rule
//
// Continuous, near-real-time export of selected tables from the workspace to a
// storage account (and/or Event Hub). Different from diagnostic settings — this is
// a workspace-level pipeline of LAW table rows.
//
// Use cases:
//   - Long-term retention beyond the workspace retention setting (8 days Basic →
//     years in cool/cold blob).
//   - Feed SIEMs / data lakes / external analytics off Log Analytics.
//
// Demo cost: minimal — exporting only `Heartbeat` (a tiny table).
// =====================================================================================

@description('Data Export rule name.')
param name string

@description('Workspace name (this is a child resource of the LAW).')
param workspaceName string

@description('Target storage account resource ID.')
param storageAccountId string

@description('Tables to export. Defaults to Heartbeat (small + always populated).')
param tables array = [ 'Heartbeat' ]

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// ARM completion of the workspace does not guarantee its export backend is active yet.
@retryOn(['ResourceNotFound'], 30)
resource exportRule 'Microsoft.OperationalInsights/workspaces/dataExports@2023-09-01' = {
  parent: law
  name: name
  properties: {
    destination: {
      resourceId: storageAccountId
    }
    tableNames: tables
    enable: true
  }
}

output id string   = exportRule.id
output name string = exportRule.name
