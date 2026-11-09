<#
.SYNOPSIS
  Stop an exact SRE Agent, verify it is stopped, delete it and verify absence.
.DESCRIPTION
  Used by teardown after confirmation. Action requests are submitted once, with
  bounded state checks. Service conflicts and failed cleanup remain fatal; this
  helper never deletes a resource group or changes identities/permissions.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [string] $ResourceId,
  [ValidateRange(1, 1800)] [int] $VerificationTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($ResourceId -notmatch '^/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.App/agents/[a-zA-Z0-9-]+$' -or
    $Matches.subscription -ine $SubscriptionId.ToString()) {
  throw 'SRE Agent resource ID must identify exactly one agent in the explicit subscription.'
}
$account = az account show --subscription $SubscriptionId --query '{id:id,tenantId:tenantId}' -o json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ine $SubscriptionId.ToString() -or $account.tenantId -ine $TenantId.ToString()) {
  throw 'SRE Agent cleanup subscription or tenant mismatch. No changes were made.'
}
$apiVersion = '2025-05-01-preview'
$encodedPath = ($ResourceId.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

function Get-SreCleanupState {
  $output = az resource show --subscription $SubscriptionId --ids $ResourceId --api-version $apiVersion `
    --query '{id:id,provisioningState:properties.provisioningState,powerState:properties.powerState,runningState:properties.runningState}' `
    -o json --only-show-errors 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    if ($output -match '(?m)^\s*ERROR:\s*\((ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound)\)') {
      return $null
    }
    throw "Could not verify SRE Agent '$ResourceId'. No absence was assumed. Azure details:`n$output"
  }
  $state = $output | ConvertFrom-Json
  if ($state.id -ine $ResourceId) { throw 'SRE Agent state lookup returned an unexpected or missing resource ID.' }
  if ($state.powerState -and $state.runningState -and $state.powerState -ne $state.runningState) {
    throw "SRE Agent returned conflicting powerState '$($state.powerState)' and runningState '$($state.runningState)'."
  }
  return [pscustomobject]@{
    Provisioning = $state.provisioningState
    Power = $(if ($state.powerState) { $state.powerState } else { $state.runningState })
  }
}

function Wait-SreCleanupState {
  param([switch] $Absent)
  $deadline = [DateTime]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
  $attempts = [Math]::Max(1, [Math]::Ceiling($VerificationTimeoutSeconds / 10))
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $state = Get-SreCleanupState
    if (-not $state -or (-not $Absent -and $state.Power -eq 'Stopped')) { return $state }
    if (-not $Absent -and $state.Power -notin @('Running', 'Starting', 'Stopping')) {
      throw "Cannot verify stopped SRE Agent '$ResourceId': unknown power state '$($state.Power)'. No deletion was submitted."
    }
    if ($attempt -eq $attempts - 1 -or [DateTime]::UtcNow.AddSeconds(10) -ge $deadline) { break }
    Start-Sleep -Seconds 10
  }
  $expected = if ($Absent) { 'absent' } else { 'Stopped' }
  $activity = az monitor activity-log list --subscription $SubscriptionId --resource-id $ResourceId --offset 1h --max-events 10 `
    --query "[?status.value=='Failed'].{time:eventTimestamp,operation:operationName.value,correlationId:correlationId,details:properties.statusMessage}" `
    -o json --only-show-errors 2>&1 | Out-String
  $activityStatus = if ($LASTEXITCODE -eq 0) { 'Recent failed Activity Log events' } else { 'Activity Log lookup also failed' }
  throw "SRE Agent '$ResourceId' was not verified $expected within ${VerificationTimeoutSeconds}s. Last provisioning='$($state.Provisioning)', power='$($state.Power)'. No further actions were submitted; do not continue resource-group cleanup. $activityStatus`:`n$activity"
}

$state = Get-SreCleanupState
if (-not $state) {
  Write-Host "SRE Agent is already absent: $ResourceId" -ForegroundColor DarkGray
  return $false
}
if (-not $PSCmdlet.ShouldProcess($ResourceId, 'Stop, verify stopped, permanently delete and verify absence')) { return }
if ($state.Power -notin @('Running', 'Starting', 'Stopping', 'Stopped')) {
  throw "SRE Agent '$ResourceId' has unknown power state '$($state.Power)'. No changes were made."
}
if ($state.Power -ne 'Stopped') {
  if ($state.Power -ne 'Stopping') {
    Write-Host "Stopping SRE Agent before deletion: $ResourceId" -ForegroundColor Yellow
    $stopOutput = az rest --subscription $SubscriptionId --method post `
      --url "https://management.azure.com${encodedPath}/stop?api-version=$apiVersion" --only-show-errors 2>&1 | Out-String
    $stopExitCode = $LASTEXITCODE
    if ($stopExitCode -ne 0) {
      $state = Get-SreCleanupState
      if (-not $state) {
        Write-Host 'SRE Agent absence verified after the stop request.' -ForegroundColor Green
        return $true
      }
      throw "SRE Agent stop failed for '$ResourceId' (Azure CLI exit $stopExitCode). Last provisioning='$($state.Provisioning)', power='$($state.Power)'. No delete was submitted. A 'currently being processed' conflict requires the existing service operation to finish or Azure Support to unblock it; repeated delete requests are not a fix. Azure details:`n$stopOutput"
    }
  }
  $state = Wait-SreCleanupState
  if (-not $state) {
    Write-Host 'SRE Agent absence verified while waiting for stop.' -ForegroundColor Green
    return $true
  }
}

Write-Host "SRE Agent is stopped. Submitting one deletion: $ResourceId" -ForegroundColor Yellow
$deleteOutput = az resource delete --subscription $SubscriptionId --ids $ResourceId --api-version $apiVersion `
  --no-wait --only-show-errors 2>&1 | Out-String
$deleteExitCode = $LASTEXITCODE
if ($deleteExitCode -ne 0) {
  $state = Get-SreCleanupState
  if ($state) {
    throw "SRE Agent deletion failed for '$ResourceId' (Azure CLI exit $deleteExitCode). Last provisioning='$($state.Provisioning)', power='$($state.Power)'. Do not continue resource-group cleanup. Azure details:`n$deleteOutput"
  }
} else {
  Wait-SreCleanupState -Absent | Out-Null
}
Write-Host "SRE Agent deletion verified (ResourceNotFound): $ResourceId" -ForegroundColor Green
return $true
