# Shared by the one-shot and staged Bicep entrypoints. Loading this file makes no Azure calls.
function Invoke-LabDeployment {
  param(
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][string] $ResourceGroup,
    [Parameter(Mandatory)][string] $DeploymentName
  )

  $PSNativeCommandUseErrorActionPreference = $false
  foreach ($entry in @{ '--subscription' = $SubscriptionId; '--resource-group' = $ResourceGroup;
      '--name' = $DeploymentName; '--mode' = 'Incremental' }.GetEnumerator()) {
    $index = [Array]::IndexOf($Arguments, $entry.Key)
    if ($index -lt 0 -or $Arguments[$index + 1] -ine $entry.Value) {
      throw 'Slot recovery requires explicit, consistent subscription, resource group, deployment name and Incremental mode.'
    }
  }
  # A failed ARM parent cannot be resumed. Keep its original local inputs unchanged
  # for the guarded incremental reconciliation after repairing the isolated leaf.
  $inputHashes = @{}
  foreach ($argument in $Arguments) {
    $path = if ($argument.StartsWith('@')) { $argument.Substring(1) } else { $argument }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $inputHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
    }
  }
  az deployment group create @Arguments --output none
  if ($LASTEXITCODE -eq 0) { return }

  $scope = @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroup)
  $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/"
  function Read-RecoveryJson([string[]] $Command, [switch] $ExpectArray) {
    $raw = az @Command --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Slot recovery read failed; outcome unknown. No further writes were submitted.' }
    try {
      $parsed = $raw | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
      if ($null -eq $parsed -or ($ExpectArray -and $parsed -isnot [array])) { throw 'Invalid response shape.' }
      return $parsed
    }
    catch { throw 'Slot recovery received an unreadable response; no further writes were submitted.' }
  }
  function Read-TerminalDeployment([string] $Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    for ($poll = 0; $poll -lt 13; $poll++) {
      $deployment = Read-RecoveryJson (@('deployment', 'group', 'show') + $scope +
        @('--name', $Name, '--query', '{id:id,state:properties.provisioningState}'))
      if ($deployment.id -ine "${prefix}Microsoft.Resources/deployments/$Name") {
        throw 'Slot recovery deployment scope mismatch; stopped.'
      }
      if ($deployment.state -in @('Succeeded', 'Failed', 'Canceled')) { return $deployment }
      if ([DateTime]::UtcNow -ge $deadline -or $poll -eq 12) { break }
      Start-Sleep -Seconds 5
    }
    throw 'Slot recovery deployment is still in progress or unknown after the bounded read deadline; stopped without retry.'
  }
  function Read-Operations([string] $Name) {
    $operations = @(Read-RecoveryJson -ExpectArray -Command (@('deployment', 'operation', 'group', 'list') + $scope +
      @('--name', $Name, '--query', '[].properties.{state:provisioningState,operation:provisioningOperation,target:targetResource,message:statusMessage}')))
    foreach ($operation in $operations) {
      $message = $operation.message
      if ($message -is [string]) {
        try { $message = $message | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { $message = @{} }
      }
      $operation.error = $message.error
    }
    return $operations
  }
  function Test-SlotProviderError($ErrorDetail) {
    if (-not $ErrorDetail -or $ErrorDetail.code -ne 'InternalServerError') { return $false }
    foreach ($detail in @($ErrorDetail.details)) {
      if ($detail -and -not (Test-SlotProviderError $detail)) { return $false }
    }
    if ($ErrorDetail.innererror -and -not (Test-SlotProviderError $ErrorDetail.innererror)) { return $false }
    return $true
  }
  function Get-IsolatedFailure([string] $Name, [string] $TargetId) {
    $operations = @(Read-Operations $Name)
    if (@($operations | Where-Object { $_.state -notin @('Succeeded', 'Failed') }).Count) { return $null }
    $failed = @($operations | Where-Object state -eq 'Failed')
    if ($failed.Count -ne 1 -or $failed[0].target.id -ine $TargetId) { return $null }
    return $failed[0]
  }

  $root = Read-TerminalDeployment $DeploymentName
  if ($root.state -ne 'Failed') { throw 'Failed CLI submission has no terminal failed parent; reconcile manually before any retry.' }
  $customerId = "${prefix}Microsoft.Resources/deployments/customer-webapp"
  if (-not (Get-IsolatedFailure $DeploymentName $customerId)) { $global:LASTEXITCODE = 1; return }
  if ((Read-TerminalDeployment 'customer-webapp').state -ne 'Failed') { throw 'Customer deployment outcome changed; stopped.' }
  $leafId = "${prefix}Microsoft.Resources/deployments/customer-broken-slot"
  if (-not (Get-IsolatedFailure 'customer-webapp' $leafId)) { $global:LASTEXITCODE = 1; return }
  if ((Read-TerminalDeployment 'customer-broken-slot').state -ne 'Failed') { throw 'Slot deployment outcome changed; stopped.' }
  $operations = @(Read-Operations 'customer-broken-slot')
  $failed = @($operations | Where-Object state -eq 'Failed')
  if ($failed.Count -ne 1 -or
      @($operations | Where-Object { $_.state -notin @('Succeeded', 'Failed') }).Count -or
      $failed[0].target.resourceType -ine 'Microsoft.Web/sites/slots' -or
      $failed[0].operation -ne 'Create' -or -not (Test-SlotProviderError $failed[0].error)) {
    $global:LASTEXITCODE = 1
    return
  }

  $allowed = @('appName', 'name', 'kind', 'location', 'serverFarmResourceId', 'enabled', 'httpsOnly',
    'managedIdentities', 'virtualNetworkSubnetResourceId', 'siteConfig', 'enableTelemetry', 'tags')
  $template = Read-RecoveryJson (@('deployment', 'group', 'export') + $scope + @('--name', 'customer-broken-slot'))
  if (@($template.parameters.Values | Where-Object { $_.type -like 'secure*' }).Count) {
    throw 'Slot recovery does not support templates with secure parameters.'
  }
  $parameterNames = @(Read-RecoveryJson -ExpectArray -Command (@('deployment', 'group', 'show') + $scope +
    @('--name', 'customer-broken-slot', '--query', 'keys(properties.parameters)')))
  $defaults = @{}
  $checks = @()
  foreach ($key in $parameterNames) {
    if ($key -in $allowed) { continue }
    $definition = $template.parameters[$key]
    if (-not $definition -or $key -notmatch '^[a-zA-Z][a-zA-Z0-9]*$' -or
        (-not $definition.ContainsKey('defaultValue') -and -not $definition.nullable)) {
      throw 'Slot recovery found unsupported additional parameters; stopped without reading their values.'
    }
    $value = $definition.defaultValue
    if ($value -is [string] -and $value.StartsWith('[')) { throw 'Slot recovery cannot verify an additional expression default.' }
    $defaults[$key] = @{ value = $value }
    $literal = ConvertTo-Json -InputObject $value -Depth 30 -Compress
    $checks += "properties.parameters.$key.value == ``$literal``"
  }
  if ($checks.Count -and (Read-RecoveryJson (@('deployment', 'group', 'show') + $scope +
      @('--name', 'customer-broken-slot', '--query', ($checks -join ' && ')))) -ne $true) {
    throw 'Slot recovery found nondefault additional parameters; stopped without reading their values.'
  }
  $runtimeKeys = @(Read-RecoveryJson -ExpectArray -Command (@('deployment', 'group', 'show') + $scope +
    @('--name', 'customer-broken-slot', '--query', 'keys(properties.parameters.siteConfig.value)')))
  if (@($runtimeKeys | Where-Object { $_ -notin @('linuxFxVersion', 'alwaysOn', 'ftpsState', 'minTlsVersion', 'http20Enabled', 'healthCheckPath') }).Count) {
    throw 'Slot recovery will not read additional site configuration inputs.'
  }
  # Project only the known nonsecret inputs, never optional configs/app-settings values.
  $projection = 'properties.parameters.{' + (($parameterNames | Where-Object { $_ -in $allowed } |
    ForEach-Object { "${_}:$_" }) -join ',') + '}'
  $leaf = Read-RecoveryJson (@('deployment', 'group', 'show') + $scope +
    @('--name', 'customer-broken-slot', '--query', $projection))
  if (@($leaf.Keys | Where-Object { $_ -notin $allowed }).Count -or
      $leaf.name.value -ne 'broken' -or -not $leaf.appName.value -or
      $leaf.kind.value -ne 'app,linux' -or $leaf.enableTelemetry.value -ne $false) {
    throw 'Slot recovery inputs are not the supported nonsecret customer-slot parameters; stopped.'
  }
  $slotId = "${prefix}Microsoft.Web/sites/$($leaf.appName.value)/slots/broken"
  if ($failed[0].target.id -ine $slotId) { throw 'Slot recovery resource target mismatch; stopped.' }
  foreach ($key in $leaf.Keys) {
    if ($template.parameters[$key].type -like 'secure*' -or -not $leaf[$key].ContainsKey('value')) {
      throw 'Slot recovery will not retrieve or replay secure parameters or unresolved references.'
    }
  }
  foreach ($key in $defaults.Keys) { $leaf[$key] = $defaults[$key] }
  function Read-SlotState {
    # Listing siblings distinguishes a confirmed absence from a failed GET/auth/network read.
    $slots = @(Read-RecoveryJson -ExpectArray -Command (@('webapp', 'deployment', 'slot', 'list', '--subscription', $SubscriptionId,
      '--resource-group', $ResourceGroup, '--name', $leaf.appName.value, '--query',
      '[].{id:id,state:state,provisioningState:provisioningState,kind:kind,location:location,serverFarmId:serverFarmId,httpsOnly:httpsOnly,enabled:enabled,virtualNetworkSubnetId:virtualNetworkSubnetId,identity:identity,tags:tags}')))
    if (@($slots | Where-Object { -not $_.id -or $_.id -notlike "${prefix}Microsoft.Web/sites/$($leaf.appName.value)/slots/*" }).Count) {
      throw 'Slot inventory has an unexpected shape or scope; stopped.'
    }
    $slot = @($slots | Where-Object { $_.id -ieq $slotId })
    if ($slot.Count -eq 0) { return 'Missing' }
    if ($slot.Count -ne 1) { throw 'Ambiguous slot inventory; stopped.' }
    $slot = $slot[0]
    if ($slot.provisioningState -eq 'Failed') { return 'Failed' }
    if ($slot.provisioningState -and $slot.provisioningState -ne 'Succeeded') { return 'Pending' }
    if ($slot.state -ne 'Running') { return 'Pending' }
    $actualLocation = $slot.location -replace '\s', ''
    $expectedLocation = $leaf.location.value -replace '\s', ''
    foreach ($pair in @(
        @($slot.kind, $leaf.kind.value), @($actualLocation, $expectedLocation),
        @($slot.serverFarmId, $leaf.serverFarmResourceId.value), @($slot.httpsOnly, $leaf.httpsOnly.value),
        @($slot.enabled, $leaf.enabled.value),
        @([string]$slot.virtualNetworkSubnetId, [string]$leaf.virtualNetworkSubnetResourceId.value))) {
      if ($pair[0] -ine $pair[1]) { throw 'Existing slot metadata does not match the submitted deployment; stopped.' }
    }
    foreach ($tag in $leaf.tags.value.Keys) {
      if ($slot.tags[$tag] -ne $leaf.tags.value[$tag]) { throw 'Existing slot tags differ from the submitted deployment; stopped.' }
    }
    if ($leaf.managedIdentities.value.systemAssigned -and $slot.identity.type -notmatch 'SystemAssigned') {
      throw 'Existing slot system identity differs from the submitted deployment; stopped.'
    }
    $expectedIds = @($leaf.managedIdentities.value.userAssignedResourceIds | Sort-Object)
    $actualIds = @($slot.identity.userAssignedIdentities.Keys | Sort-Object)
    if (($expectedIds -join ',') -ine ($actualIds -join ',')) { throw 'Existing slot user identities differ; stopped.' }
    $config = Read-RecoveryJson (@('webapp', 'config', 'show', '--subscription', $SubscriptionId,
      '--resource-group', $ResourceGroup, '--name', $leaf.appName.value, '--slot', 'broken', '--query',
      '{linuxFxVersion:linuxFxVersion,alwaysOn:alwaysOn,ftpsState:ftpsState,minTlsVersion:minTlsVersion,http20Enabled:http20Enabled,healthCheckPath:healthCheckPath}'))
    foreach ($key in $leaf.siteConfig.value.Keys) {
      if ($config[$key] -ine $leaf.siteConfig.value[$key]) { throw 'Existing slot runtime metadata differs; stopped.' }
    }
    return 'Expected'
  }
  function Wait-SlotState {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    for ($poll = 0; $poll -lt 13; $poll++) {
      $state = Read-SlotState
      if ($state -ne 'Pending') { return $state }
      if ([DateTime]::UtcNow -ge $deadline -or $poll -eq 12) { break }
      Start-Sleep -Seconds 5
    }
    throw 'Slot state is in progress or unknown after the bounded read deadline; stopped without retry.'
  }

  $directory = Join-Path $PSScriptRoot '..\.artifacts'
  $null = New-Item -ItemType Directory -Path $directory -Force
  $templateFile = Join-Path $directory ("slot-recovery-{0}.json" -f [guid]::NewGuid().ToString('N'))
  $parentTemplateFile = Join-Path $directory ("parent-recovery-{0}.json" -f [guid]::NewGuid().ToString('N'))
  try {
    $parentTemplate = Read-RecoveryJson (@('deployment', 'group', 'export') + $scope + @('--name', $DeploymentName))
    $parentTemplate | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parentTemplateFile
    $template | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $templateFile
    $state = Wait-SlotState
    for ($retry = 0; $state -ne 'Expected' -and $retry -lt 2; $retry++) {
      $delay = @(30, 90)[$retry] + (Get-Random -Minimum 0 -Maximum 11)
      Write-Host "Customer slot provider InternalServerError: reconciling isolated leaf, retry $($retry + 1)/2 in $delay seconds."
      Start-Sleep -Seconds $delay
      # Recheck all writers immediately before each retry; never overlap ARM deployments.
      foreach ($name in @($DeploymentName, 'customer-webapp', 'customer-broken-slot')) {
        if ((Read-TerminalDeployment $name).state -ne 'Failed') { throw 'Original deployment state changed before slot retry; stopped.' }
      }
      $state = Wait-SlotState
      if ($state -eq 'Expected') { break }
      $null = az deployment group create @scope --name customer-broken-slot --mode Incremental `
        --template-file $templateFile --parameters ($leaf | ConvertTo-Json -Depth 30 -Compress) --output none --only-show-errors 2>$null
      $exitCode = $LASTEXITCODE
      $terminal = Read-TerminalDeployment 'customer-broken-slot'
      if ($terminal.state -eq 'Succeeded') {
        $state = Wait-SlotState
        if ($state -ne 'Expected') { throw 'Slot deployment succeeded but expected metadata was not reconciled; stopped.' }
        break
      }
      $failure = Get-IsolatedFailure 'customer-broken-slot' $slotId
      if ($exitCode -eq 0 -or $terminal.state -ne 'Failed' -or -not $failure -or
          $failure.operation -ne 'Create' -or -not (Test-SlotProviderError $failure.error)) {
        throw 'Slot retry failed with a different or uncertain outcome; stopped.'
      }
      $state = Wait-SlotState
    }
    if ($state -ne 'Expected') { throw 'Customer slot InternalServerError persisted after two additional attempts; stopped.' }
    foreach ($name in @($DeploymentName, 'customer-webapp')) {
      if ((Read-TerminalDeployment $name).state -ne 'Failed') { throw 'Original parent state changed before reconciliation; stopped.' }
    }
    $null = Read-TerminalDeployment 'customer-broken-slot'
    foreach ($path in $inputHashes.Keys) {
      if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $inputHashes[$path]) {
        throw 'Original deployment inputs changed during recovery; parent reconciliation refused.'
      }
    }
    Write-Host 'Slot reconciled. Re-running the original incremental parent to reconcile outputs and remaining dependencies.'
    $resumeArguments = $Arguments.Clone()
    $templateIndex = [Array]::IndexOf($resumeArguments, '--template-file')
    if ($templateIndex -lt 0 -or $Arguments -contains 'Complete') { throw 'Parent reconciliation requires an incremental template-file deployment.' }
    $resumeArguments[$templateIndex + 1] = $parentTemplateFile
    az deployment group create @resumeArguments --output none
    $exitCode = $LASTEXITCODE
    if ((Read-TerminalDeployment $DeploymentName).state -ne 'Succeeded' -or $exitCode -ne 0) {
      throw 'Parent reconciliation did not succeed; stopped. Slot presence alone is not deployment success.'
    }
    $global:LASTEXITCODE = 0
  } finally {
    Remove-Item -LiteralPath $templateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $parentTemplateFile -Force -ErrorAction SilentlyContinue
  }
}
