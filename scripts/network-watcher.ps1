function Ensure-LabNetworkWatcher {
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  param(
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][guid] $TenantId,
    [Parameter(Mandatory)][ValidatePattern('(?i)^[a-z][a-z0-9]+$')][string] $Location
  )
  $ErrorActionPreference = 'Stop'
  $PSNativeCommandUseErrorActionPreference = $false
  if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty) {
    throw 'Network Watcher setup requires nonzero subscription and tenant IDs.'
  }
  $accountJson = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Could not verify the selected Network Watcher subscription and tenant.' }
  $account = $accountJson | ConvertFrom-Json
  if ($account.id -ine $SubscriptionId.ToString() -or $account.tenantId -ine $TenantId.ToString()) {
    throw 'Network Watcher setup requires the already-selected expected subscription and tenant. No account selection was changed.'
  }
  $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_$Location"
  function Read-RegionalWatcher {
    $raw = az network watcher list --subscription $SubscriptionId --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Network Watchers; stopped before deployment.' }
    $inventory = $raw | ConvertFrom-Json -NoEnumerate
    if ($inventory -isnot [array]) { throw 'Network Watcher inventory must be a JSON array; stopped before deployment.' }
    foreach ($item in $inventory) {
      if ([string]::IsNullOrWhiteSpace($item.id) -or [string]::IsNullOrWhiteSpace($item.location)) {
        throw 'Network Watcher inventory is incomplete; stopped before deployment.'
      }
    }
    $regional = @($inventory | Where-Object { $_.location -ieq $Location })
    if ($regional.Count -gt 1 -or ($regional.Count -eq 1 -and $regional[0].id -ine $expectedId)) {
      throw "An existing regional Network Watcher does not match '$expectedId'. These Bicep templates require that shared watcher; reconcile its scope manually. No existing watcher will be moved or replaced."
    }
    if ($regional.Count -eq 1) { return $regional[0] }
  }
  $watcher = Read-RegionalWatcher
  if (-not $watcher) {
    if (-not $PSCmdlet.ShouldProcess($expectedId, 'Create missing shared NetworkWatcherRG and enable the regional Network Watcher; preserve existing resources')) {
      if ($WhatIfPreference) { return }
      throw 'Network Watcher prerequisite creation was not approved; stopped before deployment.'
    }
    $groupExists = az group exists --subscription $SubscriptionId --name NetworkWatcherRG --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $groupExists -notin @('true', 'false')) {
      throw 'Could not determine whether NetworkWatcherRG exists; stopped before deployment.'
    }
    if ($groupExists -eq 'false') {
      Write-Host "Creating missing shared NetworkWatcherRG in subscription '$SubscriptionId'."
      az group create --subscription $SubscriptionId --name NetworkWatcherRG --location $Location --output none --only-show-errors
      if ($LASTEXITCODE -ne 0) { throw 'Could not create the missing NetworkWatcherRG; stopped before deployment.' }
    }
    Write-Host "Enabling the missing regional Network Watcher in '$Location'."
    az network watcher configure --subscription $SubscriptionId --resource-group NetworkWatcherRG `
      --locations $Location --enabled true --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable the regional Network Watcher; stopped before deployment.' }
    $watcher = Read-RegionalWatcher
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  for ($poll = 0; $poll -lt 13; $poll++) {
    if ($watcher -and $watcher.provisioningState -eq 'Succeeded') {
      Write-Verbose "Regional Network Watcher is ready: $expectedId"
      return
    }
    if ($watcher -and $watcher.provisioningState -in @('Failed', 'Canceled', 'Deleting')) {
      throw "Regional Network Watcher is '$($watcher.provisioningState)'; stopped before deployment."
    }
    if ($poll -eq 12 -or [DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Seconds 5
    $watcher = Read-RegionalWatcher
  }
  throw 'Regional Network Watcher was not ready within the bounded polling window; stopped before deployment.'
}
