$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$subscription = [guid]::NewGuid().ToString()
$scope = "/subscriptions/$subscription/resourceGroups/rg-demo"
$roleId = [guid]::NewGuid().ToString()
$definitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$roleId"
$role = @{
  id = $definitionId; name = $roleId; roleName = 'Health Model Reporter abc12345'; roleType = 'CustomRole'
  assignableScopes = @($scope)
  permissions = @(@{
    actions = @('Microsoft.CloudHealth/healthmodels/read', 'Microsoft.CloudHealth/healthmodels/entities/ingestHealthReport/action')
    notActions = @(); dataActions = @(); notDataActions = @()
  })
}
$assignment = @{
  id = "$scope/providers/Microsoft.CloudHealth/healthmodels/hm-lab-cafe/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
  scope = "$scope/providers/Microsoft.CloudHealth/healthmodels/hm-lab-cafe"
  roleDefinitionId = $definitionId
}
$roles = @($role)
$assignments = @($assignment)
$deletes = [Collections.Generic.List[string]]::new()
function az {
  $global:LASTEXITCODE = 0
  if ($args[0..2] -join ' ' -eq 'role definition list') { ConvertTo-Json -InputObject $roles -Depth 10 }
  elseif ($args[0..2] -join ' ' -eq 'role assignment list') { ConvertTo-Json -InputObject $assignments -Depth 10 }
  elseif ($args[0..2] -join ' ' -eq 'role assignment delete') { $deletes.Add('assignment') }
  elseif ($args[0..2] -join ' ' -eq 'role definition delete') { $deletes.Add('definition') }
  else { throw "Unexpected cleanup command: $args" }
}
function Invoke-Cleanup {
  & (Join-Path $repo 'scripts\remove-health-model-demo-roles.ps1') -SubscriptionId $subscription -ResourceGroup rg-demo -Confirm:$false @args
}
Invoke-Cleanup -WhatIf
if ($deletes.Count -gt 0) { throw 'Cleanup WhatIf mutated RBAC.' }
Invoke-Cleanup
if (($deletes -join ',') -ne 'assignment,definition') { throw 'Assignments must be removed before the lab role definition.' }
$deletes.Clear()
foreach ($change in @('other-scope', 'shared-scope', 'broad-role', 'foreign-name')) {
  $candidate = $role | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  switch ($change) {
    'other-scope' { $candidate.assignableScopes = @("$scope-other") }
    'shared-scope' { $candidate.assignableScopes = @($scope, "/subscriptions/$subscription") }
    'broad-role' { $candidate.permissions[0].actions = @('*') }
    'foreign-name' { $candidate.roleName = 'Customer health reporter' }
  }
  $roles = @($candidate)
  Invoke-Cleanup
  if ($deletes.Count -gt 0) { throw "Cleanup selected unrelated role: $change." }
}
$roles = @($role)
$assignment.scope = "$scope-other"
$rejected = $false
try { Invoke-Cleanup } catch {
  if ($_.Exception.Message -notmatch 'unexpected assignment') { throw }
  $rejected = $true
}
if (-not $rejected -or $deletes.Count -gt 0) { throw 'Out-of-scope assignments must block cleanup before mutation.' }
Write-Host 'PASS: scoped role cleanup, assignment ordering, WhatIf, and preservation of foreign/shared/broad roles.'
