$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('healthmodel-deployment-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts')
$configPath = Join-Path $fixture 'lab.config.json'
$deploy = Join-Path $fixture 'scripts\deploy-lab-healthmodel.ps1'
$state = @{
  Group = 'rg-flow-fixture'; Prefix = 'fixture'; Location = 'swedencentral'
  Apps = @('app-fixture-abcde', 'app-fixture-abcde-customer')
  Subscription = [guid]::NewGuid().ToString(); Tenant = [guid]::NewGuid().ToString()
  FailList = $false; FailDeployment = $false; WrongAccount = $false
  Deployments = 0; Lists = 0; RegionReads = 0; Parameters = $null; File = $null; Verb = $null
}

function New-FixtureResourceId($Type, $Name) {
  "/subscriptions/$($state.Subscription)/resourceGroups/$($state.Group)/providers/$Type/$Name"
}
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' { return }
    'account show' {
      return @{
        id = if ($state.WrongAccount) { [guid]::NewGuid().ToString() } else { $state.Subscription }
        tenantId = $state.Tenant
      } | ConvertTo-Json
    }
    'group show' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -cne $state.Group) { throw 'Wrong resource group selected.' }
      $state.RegionReads++
      return $state.Location
    }
    'resource list' {
      $state.Lists++
      if ($args[[Array]::IndexOf($args, '-g') + 1] -cne $state.Group) { throw 'Resource discovery ignored the selected group.' }
      $type = $args[[Array]::IndexOf($args, '--resource-type') + 1]
      $query = $args[[Array]::IndexOf($args, '--query') + 1]
      if ($state.FailList) { $global:LASTEXITCODE = 1; return }
      if ($type -eq 'Microsoft.Web/sites') {
        if ($query -cne "[?starts_with(name, 'app-$($state.Prefix)-') && !ends_with(name, '-customer')].id") {
          throw 'Control Center discovery must use the configured prefix and exclude the customer app.'
        }
        return @($state.Apps | Where-Object {
          $_.StartsWith("app-$($state.Prefix)-") -and -not $_.EndsWith('-customer')
        } | ForEach-Object { New-FixtureResourceId $type $_ })
      }
      $name = switch ($type) {
        'Microsoft.OperationalInsights/workspaces' {
          if ($query -like '*appinsights*') { "law-$($state.Prefix)-appinsights" } else { "law-$($state.Prefix)-central" }
        }
        'Microsoft.Monitor/accounts' { "amw-$($state.Prefix)" }
        'Microsoft.ContainerService/managedClusters' { "aks-$($state.Prefix)" }
        'Microsoft.Compute/virtualMachineScaleSets' { "vmss-$($state.Prefix)" }
        'Microsoft.Insights/webtests' { "avail-$($state.Prefix)-appservice" }
        default { throw "Unexpected resource type: $type" }
      }
      return New-FixtureResourceId $type $name
    }
    'monitor action-group' { return New-FixtureResourceId 'Microsoft.Insights/actionGroups' "ag-$($state.Prefix)-email" }
    'vm list' { return New-FixtureResourceId 'Microsoft.Compute/virtualMachines' "vm-$($state.Prefix)" }
    'deployment group' {
      if ($args[[Array]::IndexOf($args, '-g') + 1] -cne $state.Group) { throw 'Deployment ignored the selected group.' }
      $state.Deployments++
      $state.Verb = $args[2]
      $state.File = $args[[Array]::IndexOf($args, '--parameters') + 1].Substring(1)
      $state.Parameters = (Get-Content -LiteralPath $state.File -Raw | ConvertFrom-Json).parameters
      if ($state.FailDeployment) { $global:LASTEXITCODE = 2 }
      return
    }
    default { throw "Unexpected Azure command: $($args -join ' ')" }
  }
}
function Assert-FixtureFailure([scriptblock] $Run, [string] $Pattern) {
  $failure = $null
  try { & $Run | Out-Null } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -notlike $Pattern) {
    throw "Expected '$Pattern', received '$failure'."
  }
}

try {
  foreach ($name in @('deploy-lab-healthmodel.ps1', 'lab-config.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "scripts\$name") -Destination (Join-Path $fixture 'scripts')
  }
  @{
    basicConfiguration = @{ resourceGroup = $state.Group }
    advancedConfiguration = @{ naming = @{ namePrefix = $state.Prefix } }
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
  & $deploy -WhatIf
  if ($state.Parameters.webAppId.value -cne (New-FixtureResourceId 'Microsoft.Web/sites' 'app-fixture-abcde') -or
      $state.Parameters.location.value -cne $state.Location -or $state.Verb -cne 'what-if' -or
      (Test-Path -LiteralPath $state.File)) {
    throw 'Grouped configuration, customer-app exclusion, preview or parameter-file cleanup failed.'
  }
  @{ resourceGroup = $state.Group; namePrefix = $state.Prefix } | ConvertTo-Json | Set-Content -LiteralPath $configPath
  & $deploy -WhatIf
  if ($state.Parameters.webAppId.value -cne (New-FixtureResourceId 'Microsoft.Web/sites' 'app-fixture-abcde')) {
    throw 'Legacy configuration changed resource selection.'
  }
  $state.Group = 'rg-explicit-fixture'
  $regionReads = $state.RegionReads
  & $deploy -ResourceGroup $state.Group -Location 'northeurope' -WhatIf
  if ($state.Parameters.location.value -cne 'northeurope' -or $state.RegionReads -ne $regionReads) {
    throw 'Explicit group/location must override configured/default values.'
  }

  Remove-Item -LiteralPath $configPath
  $state.Group = 'rg-azure-monitor-lab'
  $state.Prefix = 'amlab'
  $state.Apps = @('app-amlab-abcde', 'app-amlab-abcde-customer')
  & $deploy -Location 'swedencentral'
  if ($state.Verb -cne 'create' -or $state.Parameters.webAppId.value -cne (New-FixtureResourceId 'Microsoft.Web/sites' 'app-amlab-abcde')) {
    throw 'Missing config must retain default group/prefix and the create deployment path.'
  }

  $deployments = $state.Deployments
  $state.Apps = @('app-amlab-abcde-customer')
  Assert-FixtureFailure { & $deploy -WhatIf } '*Expected one Microsoft.Web/sites*found 0*'
  $state.Apps = @('app-amlab-abcde', 'app-amlab-second', 'app-amlab-abcde-customer')
  Assert-FixtureFailure { & $deploy -WhatIf } '*Expected one Microsoft.Web/sites*found 2*'
  $state.Apps = @('app-amlab-abcde', 'app-amlab-abcde-customer')
  $state.FailList = $true
  Assert-FixtureFailure { & $deploy -WhatIf } '*Listing Microsoft.Web/sites failed with exit code 1*'
  $state.FailList = $false
  if ($state.Deployments -ne $deployments) { throw 'Failed discovery must not start a deployment.' }

  $state.FailDeployment = $true
  Assert-FixtureFailure { & $deploy -WhatIf } '*Deployment what-if failed with exit code 2*'
  $state.FailDeployment = $false
  if (Test-Path -LiteralPath $state.File) { throw 'Failed deployment leaked its parameter file.' }

  @{
    expectedSubscriptionId = $state.Subscription; expectedTenantId = $state.Tenant
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture '.azure-target.json')
  $state.WrongAccount = $true
  $lists = $state.Lists
  Assert-FixtureFailure { & $deploy -WhatIf } 'BLOCKED: not on allowed lab subscription*'
  if ($state.Lists -ne $lists) { throw 'An account mismatch must block discovery.' }
  $state.WrongAccount = $false
  & $deploy -WhatIf
  Write-Output 'PASS: grouped/legacy/default config, explicit overrides, exact Control Center discovery, account guards, preview/create paths, failure propagation and cleanup. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
