$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$deployText = Get-Content -LiteralPath (Join-Path $source 'scripts\deploy.ps1') -Raw
if ($deployText -notmatch '(?s)if \(\$null -ne \$labCfg -and \$labCfg\.enableNativeOtlp -eq \$true\).*?deploy-native-otlp\.ps1.*?-Enable') {
  throw 'One-shot native OTLP opt-in must invoke the guarded Collector installer.'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('native-otlp-test-' + [guid]::NewGuid().ToString('N'))
$scriptDir = Join-Path $root 'scripts'
$assetDir = Join-Path $root 'workloads\telemetry-ingestion\otel'
$null = New-Item -ItemType Directory -Path $scriptDir, $assetDir -Force
foreach ($file in @('deploy-native-otlp.ps1', 'telemetry-ingestion-helpers.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source "scripts\$file") -Destination $scriptDir
}
foreach ($file in @('install-collector.sh', 'collector.yaml')) {
  Copy-Item -LiteralPath (Join-Path $source "workloads\telemetry-ingestion\otel\$file") -Destination $assetDir
}
$sub = [guid]::NewGuid().ToString('D')
$tenant = [guid]::NewGuid().ToString('D')
$vmPrincipal = [guid]::NewGuid().ToString('D')
$rg = 'rg-offline'
$vmName = 'linux-offline'
$scope = "/subscriptions/$sub/resourceGroups/$rg"
$vmId = "$scope/providers/Microsoft.Compute/virtualMachines/$vmName"
$dceId = "$scope/providers/Microsoft.Insights/dataCollectionEndpoints/dce-offline"
$dcrId = "$scope/providers/Microsoft.Insights/dataCollectionRules/dcr-offline-native"
$immutable = 'dcr-offline'
$dceEndpoint = 'https://dce-offline.northeurope-1.ingest.monitor.azure.com'
$role = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"
@{ expectedSubscriptionId=$sub; expectedTenantId=$tenant; forbiddenSubscriptionIds=@() } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')
$parameters = @{ SubscriptionId=$sub; TenantId=$tenant; ResourceGroup=$rg; VmName=$vmName
  DcrId=$dcrId; DcrImmutableId=$immutable; DceEndpoint=$dceEndpoint }
$global:otlpCalls = [Collections.Generic.List[string]]::new()
$global:otlpGrant = $false
$global:otlpFailure = ''
function global:az {
  $parts = @($args | ForEach-Object { [string]$_ })
  $key = $parts -join ' '
  $global:otlpCalls.Add($key)
  $global:LASTEXITCODE = 0
  $response = switch -Regex ($key) {
    '^account show ' { @{id=$sub;tenantId=$tenant}; break }
    '^vm show ' { @{id=$vmId;location='northeurope';storageProfile=@{osDisk=@{osType='Linux'};imageReference=@{
      publisher='Canonical';offer='0001-com-ubuntu-server-jammy';sku='22_04-lts-gen2'}}
      identity=@{type='SystemAssigned';principalId=$vmPrincipal}}; break }
    '^vm get-instance-view ' { @{instanceView=@{statuses=@(@{code='PowerState/running'});
      vmAgent=@{statuses=$(if ($global:otlpFailure -eq 'agent') { @(@{code='ProvisioningState/unavailable'}) } else {
        @(@{code='ProvisioningState/succeeded'})
      })}}}; break }
    '^resource show .*dataCollectionRules/' {
      @{id=$dcrId;location='northeurope';properties=@{immutableId=$(if ($global:otlpFailure -eq 'dcr') {'other'} else {$immutable})
        provisioningState='Succeeded';dataCollectionEndpointId=$dceId
        directDataSources=@{otelLogs=@(@{streams=@('Microsoft-OTel-Logs')})}
        dataFlows=@(@{streams=@('Microsoft-OTel-Logs');destinations=@('nativeLogs')})}}; break
    }
    '^resource show .*dataCollectionEndpoints/' { @{id=$dceId;location='northeurope';properties=@{logsIngestion=@{endpoint=$dceEndpoint}}}; break }
    '^role assignment list ' {
      if ($global:otlpGrant) { @(@{scope=$dcrId;roleDefinitionId=$role;principalId=$vmPrincipal}) } else { @() }
      break
    }
    '^role assignment create ' {
      if ($parts[[array]::IndexOf($parts,'--scope')+1] -ne $dcrId -or
          $parts[[array]::IndexOf($parts,'--assignee-object-id')+1] -ne $vmPrincipal -or
          $parts[[array]::IndexOf($parts,'--role')+1] -ne $role) { throw 'Native collector was granted access outside its DCR.' }
      $global:otlpGrant = $true
      return
    }
    '^vm run-command invoke ' {
      $start = [array]::IndexOf($parts,'--parameters')
      $mode = $parts[$start+1]
      if ($parts[$start+2] -ne $vmId -or
          $parts[$start+3] -ne "$dceEndpoint/datacollectionRules/$immutable/streams/Microsoft-OTLP-Logs/otlp/v1/logs" -or
          $parts[$start+4] -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Collector VM command lost its exact target or endpoint.' }
      $marker = if ($global:otlpFailure -eq $mode) { 'OTLP_COLLECTOR_DENIED' } elseif ($mode -eq 'preflight') {
        'OTLP_COLLECTOR_PREFLIGHT_OK'
      } else { 'OTLP_COLLECTOR_INSTALL_OK' }
      @{value=@(@{code='ComponentStatus/StdOut/succeeded';message="[stdout]`n$marker`n"})}; break
    }
    default { throw "Unexpected native OTLP Azure command: $key" }
  }
  ConvertTo-Json -InputObject $response -Depth 12 -Compress
}
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
    return
  }
  throw "Expected failure matching $Pattern"
}
try {
  $script = Join-Path $scriptDir 'deploy-native-otlp.ps1'
  Assert-Fails { & $script @parameters } 'default-off'
  if ($global:otlpCalls.Count) { throw 'Default-off native OTLP called Azure.' }
  $global:otlpFailure = 'agent'
  Assert-Fails { & $script @parameters -Enable } 'VM agent is not ready'
  if (@($global:otlpCalls | Where-Object { $_ -match '^vm run-command|^role assignment create' }).Count) {
    throw 'Unready native OTLP VM agent entered a mutable stage.'
  }
  $global:otlpFailure = 'dcr'
  Assert-Fails { & $script @parameters -Enable } 'not ready'
  if (@($global:otlpCalls | Where-Object { $_ -match '^vm run-command|^role assignment create' }).Count) {
    throw 'Invalid native DCR entered a mutable stage.'
  }
  $global:otlpFailure = 'preflight'
  Assert-Fails { & $script @parameters -Enable } 'success marker'
  if (@($global:otlpCalls | Where-Object { $_ -match '^role assignment create|--parameters install' }).Count) {
    throw 'Failed VM preflight granted access or installed Collector.'
  }
  $global:otlpFailure = ''
  $global:otlpCalls.Clear()
  $result = & $script @parameters -Enable
  if ($result.LiveIngestion -notmatch 'NOT VERIFIED' -or
      @($global:otlpCalls | Where-Object { $_ -match '^vm run-command invoke ' }).Count -ne 2 -or
      @($global:otlpCalls | Where-Object { $_ -match '^role assignment create ' }).Count -ne 1) {
    throw 'Collector installation did not take the expected scoped and explicit path.'
  }
  $global:otlpCalls.Clear()
  $null = & $script @parameters -Enable
  if (@($global:otlpCalls | Where-Object { $_ -match '^role assignment create ' }).Count) {
    throw 'A rerun duplicated the publisher role.'
  }
  Write-Output 'PASS: native OTLP default-off, DCR guard, VM preflight, scoped identity role, install and idempotent rerun.'
} finally {
  Remove-Item function:\az -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $root -Recurse -Force
}
