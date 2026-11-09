$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$setup = Join-Path $source 'scripts/setup-fabric-auto-suspend.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$resourceGroup = 'rg-fabric-test'
$workflowId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/testcapacity-auto-suspend"
$fixture = @{}

function Reset-Fixture {
  $fixture.Subscription = $subscription
  $fixture.Calls = [Collections.Generic.List[object]]::new()
  $fixture.ExistingWorkflow = $false
  $fixture.Capacities = @(@{ name = 'testcapacity'; location = 'swedencentral'; sku = @{ name = 'F2' } })
  $fixture.DeploymentExitCode = 0
}

function az {
  $call = @($args)
  $fixture.Calls.Add($call)
  $global:LASTEXITCODE = 0
  switch ($call[0..1] -join ' ') {
    'account set' { return }
    'account show' { return $fixture.Subscription }
    'resource list' {
      if ($call -contains 'Microsoft.Fabric/capacities') { return ConvertTo-Json -InputObject $fixture.Capacities -Depth 5 }
      if ($call -contains 'Microsoft.Logic/workflows') {
        return ConvertTo-Json -InputObject @($(if ($fixture.ExistingWorkflow) { @{ id = $workflowId } }))
      }
    }
    'resource update' {
      if ($call -notcontains $workflowId -or $call -notcontains 'properties.state=Disabled') { throw 'Unexpected resource update.' }
      return
    }
    'deployment group' {
      if ($call[2] -ne 'create') { throw 'Unexpected deployment command.' }
      $global:LASTEXITCODE = $fixture.DeploymentExitCode
      return
    }
  }
  throw "Unexpected az command: $($call -join ' ')"
}

function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}

Reset-Fixture
& $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup
if (@($fixture.Calls | Where-Object { $_[0] -eq 'deployment' -or ($_[0] -eq 'resource' -and $_[1] -eq 'update') }).Count) {
  throw 'Default-off must not create resources or change the capacity.'
}
Reset-Fixture
$fixture.ExistingWorkflow = $true
& $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup -Enabled:$false
if (@($fixture.Calls | Where-Object { $_[0] -eq 'resource' -and $_[1] -eq 'update' }).Count -ne 1) {
  throw 'Disabling must stop an existing schedule.'
}
Reset-Fixture
& $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup -Enabled:$true -HourUtc 23 -MinuteUtc 45
$deployment = @($fixture.Calls | Where-Object { $_[0] -eq 'deployment' })[0]
if ($deployment -notcontains 'hourUtc=23' -or $deployment -notcontains 'minuteUtc=45') { throw 'The UTC schedule was not forwarded.' }
$firstRun = [DateTime]::Parse((@($deployment | Where-Object { $_ -like 'firstRunUtc=*' })[0] -split '=', 2)[1]).ToUniversalTime()
if ($firstRun -le [DateTime]::UtcNow.AddMinutes(14) -or $firstRun.Hour -ne 23 -or $firstRun.Minute -ne 45) {
  throw 'First run must be the configured future UTC time, never an immediate suspension.'
}
Reset-Fixture
$fixture.Subscription = 'wrong-subscription'
Assert-Failure { & $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup -Enabled:$true } '*guardrail failed*'
Reset-Fixture
$fixture.Capacities[0].sku.name = 'F4'
Assert-Failure { & $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup -Enabled:$true } '*exactly one F2*'
Reset-Fixture
$fixture.DeploymentExitCode = 1
Assert-Failure { & $setup -SubscriptionId $subscription -ResourceGroup $resourceGroup -Enabled:$true } '*deployment failed*'

$template = Get-Content -LiteralPath (Join-Path $source 'infra/modules/fabric-auto-suspend.json') -Raw | ConvertFrom-Json
$role = @($template.resources | Where-Object type -eq 'Microsoft.Authorization/roleDefinitions')[0]
$assignment = @($template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0]
$workflow = @($template.resources | Where-Object type -eq 'Microsoft.Logic/workflows')[0]
$actions = @($role.properties.permissions.actions)
if ($actions.Count -ne 2 -or $actions -notcontains 'Microsoft.Fabric/capacities/read' -or
    $actions -notcontains 'Microsoft.Fabric/capacities/suspend/action' -or
    $assignment.scope -notmatch 'Microsoft.Fabric/capacities' -or
    $workflow.properties.definition.actions.Suspend_if_active.actions.Await_suspension.type -ne 'Until' -or
    $workflow.properties.definition.triggers.Daily_UTC.recurrence.timeZone -ne 'UTC' -or
    $workflow.properties.definition.triggers.Daily_UTC.recurrence.startTime -ne "[parameters('firstRunUtc')]") {
  throw 'Scheduled suspension must use UTC, a future start and only capacity-scoped read/suspend permissions.'
}
Write-Output 'PASS: default-off, disabling, future UTC schedule, subscription/SKU guards, failure propagation and least privilege. No Azure writes.'
