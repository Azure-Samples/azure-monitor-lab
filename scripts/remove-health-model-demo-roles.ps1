[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup
)
$ErrorActionPreference = 'Stop'
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$legacyName = "Health Model Reporter $ResourceGroup $($SubscriptionId.ToString().Substring(0, 8))"
$allowedActions = @(
  'Microsoft.CloudHealth/healthmodels/read'
  'Microsoft.CloudHealth/healthmodels/entities/read'
  'Microsoft.CloudHealth/healthmodels/relationships/read'
  'Microsoft.CloudHealth/healthmodels/signaldefinitions/read'
  'Microsoft.CloudHealth/healthmodels/entities/ingestHealthReport/action'
)
$roles = @(az role definition list --subscription $SubscriptionId --custom-role-only true --scope $scope -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect lab Health Model reporter roles.' }
foreach ($role in $roles) {
  if ($role.roleType -ine 'CustomRole' -or
      ($role.roleName -notmatch '^Health Model Reporter [a-z0-9]{8}$' -and $role.roleName -ine $legacyName) -or
      @($role.assignableScopes).Count -ne 1 -or $role.assignableScopes[0] -ine $scope) { continue }
  $actions = @($role.permissions.actions)
  if ('Microsoft.CloudHealth/healthmodels/entities/ingestHealthReport/action' -notin $actions -or
      @($actions | Where-Object { $_ -notin $allowedActions }).Count -gt 0 -or
      @($role.permissions | ForEach-Object { $_.notActions }).Count -gt 0 -or
      @($role.permissions | ForEach-Object { $_.dataActions }).Count -gt 0 -or
      @($role.permissions | ForEach-Object { $_.notDataActions }).Count -gt 0) { continue }
  $roleGuid = [guid]::Empty
  if (-not [guid]::TryParse($role.name, [ref]$roleGuid) -or $roleGuid -eq [guid]::Empty -or
      $role.id -ine "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$roleGuid") {
    throw "Invalid resource ID on lab reporter role '$($role.roleName)'."
  }
  $assignments = @(az role assignment list --subscription $SubscriptionId --all --role $role.name -o json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect assignments for '$($role.roleName)'." }
  foreach ($assignment in $assignments) {
    if (($assignment.scope -ine $scope -and -not $assignment.scope.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)) -or
        $assignment.roleDefinitionId -ine $role.id -or
        $assignment.id -notmatch ('^' + [regex]::Escape("/subscriptions/$SubscriptionId/") + '(?:.*?/)?providers/Microsoft.Authorization/roleAssignments/[0-9a-f-]{36}$')) {
      throw "Refusing reporter-role cleanup with unexpected assignment '$($assignment.id)' or scope '$($assignment.scope)'."
    }
  }
  if ($PSCmdlet.ShouldProcess($role.roleName, 'Remove lab-scoped reporter assignments and custom role')) {
    foreach ($assignment in $assignments) {
      az role assignment delete --subscription $SubscriptionId --ids $assignment.id -o none
      if ($LASTEXITCODE -ne 0) { throw "Could not delete reporter assignment '$($assignment.id)'." }
    }
    az role definition delete --subscription $SubscriptionId --name $role.name -o none
    if ($LASTEXITCODE -ne 0) { throw "Could not delete reporter role '$($role.roleName)'." }
  }
}
