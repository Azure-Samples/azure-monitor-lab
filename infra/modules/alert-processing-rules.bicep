// =====================================================================================
// Alert Processing Rules — enterprise-grade alert routing & suppression.
//   1. Maintenance window suppression (scheduled, recurring).
//   2. Severity-based routing (Sev0-2 → on-call, Sev3-4 → email only).
// =====================================================================================

@description('Name prefix for the processing rules.')
param namePrefix string

@description('Resource Group ID scope for the rules.')
param resourceGroupId string = resourceGroup().id

@description('Primary Action Group ID (on-call / high severity).')
param primaryActionGroupId string

@description('Lab VM resource IDs whose alert notifications are suppressed during automatic shutdown hours.')
param vmIds array = []

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// Rule 1 — Maintenance window suppression
//   Suppresses ALL alerts in the RG every Sunday 02:00–06:00 UTC.
//   Demonstrates scheduled, recurring suppression for planned maintenance.
// ---------------------------------------------------------------------------------
resource maintenanceSuppress 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'apr-${namePrefix}-maintenance-window'
  location: 'global'
  tags: tags
  properties: {
    description: 'Suppress all alerts during weekly maintenance window (Sunday 02:00–06:00 UTC).'
    enabled: true
    scopes: [ resourceGroupId ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: {
      effectiveFrom: '2025-01-01T02:00:00'
      effectiveUntil: '2030-12-31T06:00:00'
      timeZone: 'UTC'
      recurrences: [
        {
          recurrenceType: 'Weekly'
          daysOfWeek: [ 'Sunday' ]
          startTime: '02:00:00'
          endTime: '06:00:00'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------------
// Rule 2 — Route low-severity alerts: add a description tag showing they were
//   processed. In a real environment you'd route to a different Action Group.
//   Here we suppress Sev3/4 to keep demo email clean.
// ---------------------------------------------------------------------------------
resource suppressLowSev 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: 'apr-${namePrefix}-suppress-low-sev'
  location: 'global'
  tags: tags
  properties: {
    description: 'Suppress Sev3 and Sev4 (informational) alerts — keeps on-call focused on real incidents.'
    enabled: false   // disabled by default — enable during the demo to show the effect
    scopes: [ resourceGroupId ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    conditions: [
      {
        field: 'Severity'
        operator: 'Equals'
        values: [ 'Sev3', 'Sev4' ]
      }
    ]
  }
}

// ---------------------------------------------------------------------------------
// Rule 3 — Automatic VM shutdown suppression
//   Mutes notifications for the lab VMs from 23:00 until 07:00 Central European
//   local time. Romance Standard Time applies CET/CEST daylight-saving changes.
// ---------------------------------------------------------------------------------
resource nightlyVmShutdown 'Microsoft.AlertsManagement/actionRules@2021-08-08' = if (!empty(vmIds)) {
  name: 'apr-${namePrefix}-vm-auto-shutdown'
  location: 'global'
  tags: tags
  properties: {
    description: 'Suppress alert actions for lab VMs during automatic shutdown hours (23:00–07:00 CET/CEST, daily).'
    enabled: true
    scopes: vmIds
    actions: [
      { actionType: 'RemoveAllActionGroups' }
    ]
    conditions: [
      {
        field: 'TargetResourceType'
        operator: 'Equals'
        values: [ 'Microsoft.Compute/virtualMachines' ]
      }
    ]
    schedule: {
      effectiveFrom: '2025-01-01T23:00:00'
      effectiveUntil: '2035-12-31T07:00:00'
      timeZone: 'Romance Standard Time'
      recurrences: [
        {
          recurrenceType: 'Daily'
          startTime: '23:00:00'
          endTime: '07:00:00'
        }
      ]
    }
  }
}

output maintenanceRuleName string = maintenanceSuppress.name
output suppressLowSevRuleName string = suppressLowSev.name
output nightlyMaintenanceRuleName string = !empty(vmIds) ? nightlyVmShutdown.name : ''
