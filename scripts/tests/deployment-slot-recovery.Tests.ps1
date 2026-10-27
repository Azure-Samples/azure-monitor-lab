$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
. (Join-Path $PSScriptRoot '..\deployment-slot-recovery.ps1')
$subscription = '00000000-0000-0000-0000-000000000001'
$prefix = "/subscriptions/$subscription/resourceGroups/test-rg/providers/"
$slotId = "${prefix}Microsoft.Web/sites/customer/slots/broken"
$leafParameters = @{
  appName = @{ value = 'customer' }; name = @{ value = 'broken' }; kind = @{ value = 'app,linux' }
  location = @{ value = 'westeurope' }; serverFarmResourceId = @{ value = "${prefix}Microsoft.Web/serverfarms/plan" }
  enabled = @{ value = $true }; httpsOnly = @{ value = $true }; enableTelemetry = @{ value = $false }
  managedIdentities = @{ value = @{ systemAssigned = $true; userAssignedResourceIds = @() } }
  virtualNetworkSubnetResourceId = @{ value = "${prefix}Microsoft.Network/virtualNetworks/vnet/subnets/web" }
  tags = @{ value = @{ 'amlab-scenario' = 'customer-app-broken-slot' } }
  siteConfig = @{ value = @{ linuxFxVersion = 'DOTNETCORE|8.0'; alwaysOn = $true; ftpsState = 'Disabled'
    minTlsVersion = '1.2'; http20Enabled = $true; healthCheckPath = '/api/slot-warmup' } }
}
$template = @{ parameters = @{}; resources = @{}; contentVersion = '1.0.0.0' }
foreach ($key in $leafParameters.Keys) { $template.parameters[$key] = @{ type = 'object' } }
$arguments = @('--subscription', $subscription, '--resource-group', 'test-rg', '--name', 'original',
  '--template-file', (Join-Path $PSScriptRoot '..\..\infra\main.bicep'), '--parameters', 'location=westeurope', '--mode', 'Incremental')

function Start-Sleep { param($Seconds) $fixture.Delays.Add([int]$Seconds) }
function az {
  $global:LASTEXITCODE = 0
  $command = $args -join ' '
  $nameIndex = [Array]::IndexOf($args, '--name')
  $name = if ($nameIndex -ge 0) { $args[$nameIndex + 1] } else { '' }
  if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $subscription) { throw 'Lost subscription pin.' }
  if ($command -match '^deployment group create') {
    $fixture.Writes.Add($name)
    if ($name -eq 'original') {
      $fixture.ParentWrites++
      if ($fixture.ParentWrites -eq 1 -or $fixture.Mode -eq 'parent-fails') { $global:LASTEXITCODE = 1; return }
      # Parent replay must retain every original argument except the exported template path.
      for ($i = 0; $i -lt $arguments.Count; $i++) {
        if ($i -eq ([Array]::IndexOf($arguments, '--template-file') + 1)) { continue }
        if ($args[$i + 3] -cne $arguments[$i]) { throw 'Parent replay changed an original argument.' }
      }
      $file = $args[[Array]::IndexOf($args, '--template-file') + 1]
      $fixture.Files.Add($file)
      if ((Get-Content $file -Raw | ConvertFrom-Json).contentVersion -ne '1.0.0.0') { throw 'Parent template not exported.' }
      $fixture.RootState = 'Succeeded'
      return
    }
    if ($name -ne 'customer-broken-slot') { throw 'Unexpected write target.' }
    $fixture.LeafWrites++
    $file = $args[[Array]::IndexOf($args, '--template-file') + 1]
    $fixture.Files.Add($file)
    $submitted = $args[[Array]::IndexOf($args, '--parameters') + 1] | ConvertFrom-Json -AsHashtable
    if ($fixture.Mode -eq 'effective-defaults') {
      if (-not $submitted.ContainsKey('configs') -or $null -ne $submitted.configs.value) { throw 'Effective nullable defaults were not preserved.' }
      $submitted.Remove('configs')
    }
    if (($submitted | ConvertTo-Json -Depth 30 -Compress) -ne ($leafParameters | ConvertTo-Json -Depth 30 -Compress)) {
      throw 'Leaf parameters changed.'
    }
    if ($fixture.Mode -eq 'exhausted' -or ($fixture.Mode -eq 'second-success' -and $fixture.LeafWrites -eq 1)) {
      $global:LASTEXITCODE = 1; return
    }
    if ($fixture.Mode -eq 'retry-permanent') { $fixture.Code = 'AuthorizationFailed'; $global:LASTEXITCODE = 1; return }
    if ($fixture.Mode -eq 'retry-unknown') { $fixture.LeafState = 'Running'; $global:LASTEXITCODE = 1; return }
    $fixture.LeafState = 'Succeeded'
    $fixture.Slot = 'expected'
    return
  }
  if ($command -match '^deployment group show') {
    $query = $args[[Array]::IndexOf($args, '--query') + 1]
    if ($query -eq 'keys(properties.parameters)') {
      if ($fixture.Mode -eq 'secure-input') { return '["unexpectedSecret"]' }
      $names = @($leafParameters.Keys)
      if ($fixture.Mode -in @('effective-defaults', 'nondefault-configs')) { $names += 'configs' }
      return (ConvertTo-Json -InputObject $names)
    }
    if ($query -eq 'keys(properties.parameters.siteConfig.value)') {
      if ($fixture.Mode -eq 'secret-config') { return '["appSettings"]' }
      return (ConvertTo-Json -InputObject @($leafParameters.siteConfig.value.Keys))
    }
    if ($query -like 'properties.parameters.configs.value*') {
      if ($fixture.Mode -eq 'nondefault-configs') { return 'false' }
      return 'true'
    }
    if ($query -like 'properties.parameters.{*') {
      return ($leafParameters | ConvertTo-Json -Depth 30)
    }
    $state = switch ($name) { 'original' { $fixture.RootState }; 'customer-broken-slot' { $fixture.LeafState }; default { 'Failed' } }
    if ($fixture.Mode -eq 'pending-leaf' -and $name -eq 'customer-broken-slot') { $state = 'Running' }
    return (@{ id = "${prefix}Microsoft.Resources/deployments/$name"; state = $state } | ConvertTo-Json)
  }
  if ($command -match '^deployment group export') {
    $export = $template.Clone()
    $export.parameters = $template.parameters.Clone()
    if ($fixture.Mode -in @('effective-defaults', 'nondefault-configs')) { $export.parameters.configs = @{ type = 'array'; nullable = $true } }
    return ($export | ConvertTo-Json -Depth 30)
  }
  if ($command -match '^deployment operation group list') {
    $target = switch ($name) {
      'original' { @{ id = "${prefix}Microsoft.Resources/deployments/customer-webapp" } }
      'customer-webapp' { @{ id = "${prefix}Microsoft.Resources/deployments/customer-broken-slot" } }
      default { @{ id = $slotId; resourceType = 'Microsoft.Web/sites/slots' } }
    }
    if ($fixture.Mode -eq 'unrelated') { $target.id = "${prefix}Microsoft.Compute/virtualMachines/other" }
    if ($fixture.Mode -eq 'wrong-type' -and $name -eq 'customer-broken-slot') { $target.resourceType = 'Microsoft.Web/sites' }
    $message = @{ error = @{ code = $fixture.Code; details = @() } }
    if ($fixture.Mode -eq 'mixed-detail') { $message.error.details = @(@{ code = 'QuotaExceeded' }) }
    if ($fixture.Mode -eq 'deep-detail') { $message.error.details = @(@{ code = 'InternalServerError'; details = @(@{ code = 'AuthorizationFailed' }) }) }
    if ($fixture.Mode -eq 'string-message') { $message = $message | ConvertTo-Json -Depth 10 -Compress }
    $operation = @{ state = 'Failed'; operation = $fixture.Operation; target = $target; message = $message; statusCode = 'BadRequest' }
    $ops = @($operation)
    if ($fixture.Mode -eq 'mixed') { $ops += @{ state = 'Failed'; target = @{ id = 'unrelated' } } }
    if ($fixture.Mode -eq 'running-sibling') { $ops += @{ state = 'Running'; target = @{ id = 'sibling' } } }
    return (ConvertTo-Json -InputObject $ops -Depth 30)
  }
  if ($command -match '^webapp deployment slot list') {
    if ($fixture.Mode -eq 'read-fails') { $global:LASTEXITCODE = 1; return }
    if ($fixture.Mode -eq 'null-inventory') { return 'null' }
    if ($fixture.Mode -eq 'malformed-inventory') { return '{}' }
    if ($fixture.Slot -eq 'missing') { return '[]' }
    $slot = @{
      id = $slotId; state = 'Running'; provisioningState = 'Succeeded'; kind = 'app,linux'; location = 'West Europe'
      serverFarmId = $leafParameters.serverFarmResourceId.value; httpsOnly = $true; enabled = $true
      virtualNetworkSubnetId = $leafParameters.virtualNetworkSubnetResourceId.value
      identity = @{ type = 'SystemAssigned'; userAssignedIdentities = @{} }; tags = $leafParameters.tags.value
    }
    if ($fixture.Slot -eq 'pending') { $slot.provisioningState = 'Creating' }
    if ($fixture.Slot -eq 'failed') { $slot.provisioningState = 'Failed' }
    if ($fixture.Slot -eq 'wrong') { $slot.serverFarmId = 'wrong-plan' }
    return (ConvertTo-Json -InputObject @($slot) -Depth 30)
  }
  if ($command -match '^webapp config show') { return ($leafParameters.siteConfig.value | ConvertTo-Json) }
  throw 'Unexpected Azure command.'
}
function Run-Case {
  param([string] $Mode, [int] $ExpectedLeafWrites, [int] $ExpectedParentWrites, [bool] $Throws,
    [string] $Slot = 'missing', [string] $RootState = 'Failed', [string] $Code = 'InternalServerError',
    [string] $Operation = 'Create')
  $script:fixture = @{
    Mode = $Mode; Slot = $Slot; RootState = $RootState; LeafState = 'Failed'; Code = $Code; Operation = $Operation
    LeafWrites = 0; ParentWrites = 0; Writes = [Collections.Generic.List[string]]::new()
    Delays = [Collections.Generic.List[int]]::new(); Files = [Collections.Generic.List[string]]::new()
  }
  $thrown = $false
  try {
    if ($Mode -eq 'main-loop') {
      $ResourceGroup = 'test-rg'
      $deploymentSubscription = $subscription
      $deploymentName = 'original'
      $mainBicep = $arguments[[Array]::IndexOf($arguments, '--template-file') + 1]
      $ParametersFile = Join-Path $PSScriptRoot '..\..\infra\main.parameters.json.template'
      $Location = 'westeurope'
      $arguments = @('--subscription', $subscription, '--resource-group', $ResourceGroup, '--name', $deploymentName,
        '--template-file', $mainBicep, '--parameters', "@$ParametersFile", '--parameters', 'location=westeurope', '--mode', 'Incremental')
      $main = Get-Content (Join-Path $PSScriptRoot '..\deploy.ps1') -Raw
      $start = $main.IndexOf('$attempt = 0')
      $end = $main.IndexOf('Write-Step "Capturing deployment outputs"')
      if ($start -lt 0 -or $end -le $start) { throw 'Main orchestration loop not found.' }
      & ([scriptblock]::Create($main.Substring($start, $end - $start)))
      if ($fixture.RootState -ne 'Succeeded') { throw 'Main orchestration continued before the parent succeeded.' }
    } else {
      Invoke-LabDeployment -Arguments $arguments -SubscriptionId $subscription -ResourceGroup test-rg -DeploymentName original
    }
  } catch {
    $thrown = $true
    if (-not $Throws) { throw }
  }
  if ($thrown -ne $Throws -or $fixture.LeafWrites -ne $ExpectedLeafWrites -or $fixture.ParentWrites -ne $ExpectedParentWrites) {
    throw "Case $Mode failed: thrown=$thrown, leaf=$($fixture.LeafWrites), parent=$($fixture.ParentWrites)."
  }
  if ($fixture.Delays.Count -gt 16) { throw "Case $Mode exceeded its bounded read/retry budget." }
  foreach ($file in $fixture.Files) { if (Test-Path $file) { throw 'Recovery left a template file behind.' } }
  if ($ExpectedParentWrites -eq 2 -and -not $Throws -and $global:LASTEXITCODE -ne 0) { throw 'Normal orchestration cannot continue.' }
  if ($ExpectedLeafWrites -gt 0 -and ($fixture.Delays[0] -lt 30 -or $fixture.Delays[0] -gt 40)) { throw 'First jitter delay outside budget.' }
  if ($ExpectedLeafWrites -eq 2 -and ($fixture.Delays[1] -lt 90 -or $fixture.Delays[1] -gt 100)) { throw 'Second jitter delay outside budget.' }
}
try {
  Run-Case success 1 2 $false
  Run-Case second-success 2 2 $false
  Run-Case string-message 1 2 $false
  Run-Case exhausted 2 1 $true
  Run-Case already-created 0 2 $false -Slot expected
  Run-Case failed-slot 1 2 $false -Slot failed
  Run-Case wrong-slot 0 1 $true -Slot wrong
  Run-Case pending-slot 0 1 $true -Slot pending
  Run-Case pending-parent 0 1 $true -RootState Running
  Run-Case unknown-parent 0 1 $true -RootState ''
  Run-Case parent-succeeded 0 1 $true -RootState Succeeded
  Run-Case unrelated 0 1 $false
  Run-Case mixed 0 1 $false
  Run-Case mixed-detail 0 1 $false
  Run-Case deep-detail 0 1 $false
  Run-Case wrong-type 0 1 $false
  Run-Case running-sibling 0 1 $false
  Run-Case pending-leaf 0 1 $true
  Run-Case secure-input 0 1 $true
  Run-Case secret-config 0 1 $true
  Run-Case nondefault-configs 0 1 $true
  Run-Case effective-defaults 1 2 $false
  Run-Case null-inventory 0 1 $true
  Run-Case malformed-inventory 0 1 $true
  Run-Case permanent 0 1 $false -Code AuthorizationFailed
  Run-Case quota 0 1 $false -Code QuotaExceeded
  Run-Case validation 0 1 $false -Code InvalidTemplate
  Run-Case badrequest 0 1 $false -Code BadRequest
  Run-Case generic 0 1 $false -Code DeploymentFailed
  Run-Case update 0 1 $false -Operation Update
  Run-Case read-fails 0 1 $true
  Run-Case retry-permanent 1 1 $true
  Run-Case retry-unknown 1 1 $true
  Run-Case parent-fails 1 2 $true
  Run-Case main-loop 1 2 $false
  Write-Host 'PASS: 35 local-only deployment recovery cases, including main orchestration continuation.'
} finally {
  $global:LASTEXITCODE = $previousExitCode
}
