[CmdletBinding()]
param([string] $RepoRoot = (Join-Path $PSScriptRoot '../..'))

$ErrorActionPreference = 'Stop'
$adminRoleId = '22926164-76b3-42b3-bc55-97df8dab3e41'
$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
$grafanaScope = "[resourceId('Microsoft.Dashboard/grafana', parameters('name'))]"
$relativeGrafanaScope = "[format('Microsoft.Dashboard/grafana/{0}', parameters('name'))]"

foreach ($path in @('infra/main.json', 'infra/stages/10-workloads.json')) {
  $template = Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw | ConvertFrom-Json -AsHashtable
  if (-not $template.parameters.ContainsKey('grafanaAdminObjectId') -or $template.parameters.grafanaAdminObjectId.defaultValue -cne '') {
    throw "$path must keep Grafana administrator selection optional."
  }
  $modules = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'grafana' })
  if ($modules.Count -ne 1) { throw "$path must contain exactly one Grafana module." }
  $module = $modules[0]
  if ($module.properties.parameters.adminObjectId.value -cne "[parameters('grafanaAdminObjectId')]") { throw "$path lost the operator override." }
  $nested = $module.properties.template
  if ($nested.parameters.adminObjectId.defaultValue -cne '' -or $nested.variables.adminPrincipalId -cne "[if(empty(parameters('adminObjectId')), deployer().objectId, parameters('adminObjectId'))]") {
    throw "$path must resolve an empty operator ID to the deployment identity."
  }
  $admins = @($nested.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.roleDefinitionId -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$adminRoleId')]" })
  if ($admins.Count -ne 1) { throw "$path is missing the Grafana Admin role assignment or contains duplicates." }
  $assignment = $admins[0]
  if ($assignment.scope -cnotin @($grafanaScope, $relativeGrafanaScope)) { throw "$path must scope Grafana Admin to the Grafana instance, not the resource group or subscription." }
  if ($assignment.properties.principalId -cne "[variables('adminPrincipalId')]") { throw "$path assigns Grafana Admin to the wrong identity." }
  if ($assignment.name -cne "[guid(resourceId('Microsoft.Dashboard/grafana', parameters('name')), variables('adminPrincipalId'), '$adminRoleId')]") { throw "$path must use a deterministic assignment name scoped to the resource, principal and role." }
  if ($assignment.dependsOn -notcontains $grafanaScope) { throw "$path does not wait for Grafana before assigning access." }
  $readers = @($nested.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.roleDefinitionId -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$monitoringReaderRoleId')]" })
  if ($readers.Count -ne 1 -or $readers[0].properties.principalId -notmatch "\.identity\.principalId\]$" -or $readers[0].properties.principalType -ne 'ServicePrincipal') { throw "$path lost Grafana managed-identity telemetry access." }
  Write-Host "PASS: $path grants scoped Grafana Admin to deployer/operator and preserves managed-identity telemetry access."
}

$ui = Get-Content -LiteralPath (Join-Path $RepoRoot 'infra/createUiDefinition.json') -Raw | ConvertFrom-Json
$field = @($ui.parameters.steps | Where-Object name -eq 'advanced' | ForEach-Object elements | Where-Object name -eq 'grafanaAdminObjectId')
if ($field.Count -ne 1 -or $field[0].defaultValue -cne '' -or $field[0].constraints.required -ne $false) { throw 'Portal Grafana operator field must be optional and default empty.' }
if ($ui.parameters.outputs.grafanaAdminObjectId -cne "[steps('advanced').grafanaAdminObjectId]") { throw 'Portal form does not pass the Grafana operator ID.' }
if ('' -notmatch $field[0].constraints.regex -or [guid]::NewGuid().ToString() -notmatch $field[0].constraints.regex -or 'invalid-id' -match $field[0].constraints.regex -or [guid]::Empty.ToString() -match $field[0].constraints.regex) { throw 'Portal Grafana object ID validation is incorrect.' }
$terraform = Get-Content -LiteralPath (Join-Path $RepoRoot 'terraform/main.tf') -Raw
if ($terraform -notmatch 'grafanaAdminObjectId\s*=\s*\{\s*value\s*=\s*var\.grafana_admin_object_id\s*\}' -or $terraform -notmatch 'infra/stages/10-workloads\.json') { throw 'Terraform Stage B must forward the operator ID to the tested shared ARM template.' }
$readme = Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw
$currentBranch = if ($env:GITHUB_BASE_REF) {
  $env:GITHUB_BASE_REF
} elseif ($env:GITHUB_REF_NAME) {
  $env:GITHUB_REF_NAME
} else {
  (& git -C $RepoRoot branch --show-current).Trim()
}
$allowedDeploymentBranches = if ($currentBranch -eq 'integration') { @('integration', 'main') } else { @('main') }
$deploymentBranches = @($allowedDeploymentBranches | Where-Object { [regex]::Matches($readme, "%2F$_%2Finfra%2F").Count -eq 2 })
if ($deploymentBranches.Count -ne 1 -or $readme -match '%2Fdev%2F|git (?:clone --branch|switch) dev|git pull --ff-only origin dev') { throw "Published deployment links must select an allowed branch on ${currentBranch}: $($allowedDeploymentBranches -join ', ')." }
$deploymentBranch = $deploymentBranches[0]
$cloneBranches = @([regex]::Matches($readme, 'git clone --branch (?<branch>\S+) https://github\.com/Azure-Samples/azure-monitor-lab\.git') | ForEach-Object { $_.Groups['branch'].Value })
$expectedDeploymentClones = if ($deploymentBranch -eq 'main') { 2 } else { 1 }
if ($cloneBranches.Count -ne 2 -or @($cloneBranches | Where-Object { $_ -eq $deploymentBranch }).Count -ne $expectedDeploymentClones -or @($cloneBranches | Where-Object { $_ -notin @('main', $deploymentBranch) }).Count -ne 0) { throw "Documented clone paths must use $deploymentBranch for portal completion and main for the stable scripted option." }
Write-Host "PASS: portal/terraform operator wiring and $deploymentBranch deployment links."