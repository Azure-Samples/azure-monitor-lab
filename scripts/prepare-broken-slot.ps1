[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]{2,60}$')] [string] $WebAppName,
  [Parameter(Mandatory)] [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })] [string] $ArchivePath,
  [Parameter(Mandatory)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $DeploymentId
)

$ErrorActionPreference = 'Stop'
if ($ResourceGroup.EndsWith('.')) { throw 'Invalid resource group.' }
$slots = @(az webapp deployment slot list --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --output json --only-show-errors | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect App Service deployment slots.' }
$broken = @($slots | Where-Object name -eq 'broken')
if ($broken.Count -eq 0) {
  Write-Host 'Broken-slot scenario is not enabled; skipping slot publication.'
  return
}
if ($broken.Count -ne 1 -or [string]::IsNullOrWhiteSpace($broken[0].defaultHostName)) { throw "The 'broken' slot is not uniquely addressable." }
$brokenState = az webapp show --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --slot broken `
  --query '{state:state,enabled:enabled}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $brokenState.state -ne 'Running' -or $brokenState.enabled -ne $true) {
  throw "The dedicated customer 'broken' slot must be enabled and Running before publication. Observed state '$($brokenState.state)'."
}

$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$WebAppName"
$production = az rest --method post --url "$base/config/appsettings/list?api-version=2023-12-01" --output json | ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0 -or $production.properties -isnot [Collections.IDictionary]) { throw 'Could not clone production App Service settings.' }
$production.properties['LabConsole__SlotScenarioEnabled'] = 'true'
$production.properties['LabConsole__ForceOutage'] = 'true'
$production.properties['WEBSITE_SWAP_WARMUP_PING_PATH'] = '/api/slot-warmup'
$production.properties['WEBSITE_SWAP_WARMUP_PING_STATUSES'] = '200'
$production.properties['SCM_DO_BUILD_DURING_DEPLOYMENT'] = 'false'

$configurationFile = Join-Path ([IO.Path]::GetTempPath()) "amlab-broken-slot-$([guid]::NewGuid().ToString('N')).json"
try {
  $production | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $configurationFile -Encoding utf8NoBOM
  az rest --method put --url "$base/slots/broken/config/appsettings?api-version=2023-12-01" --body "@$configurationFile" --headers 'Content-Type=application/json' --output none
  if ($LASTEXITCODE -ne 0) { throw 'Could not configure the broken slot.' }

  @{ healthCheckPath = '/api/slot-warmup' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $configurationFile -Encoding utf8NoBOM
  az webapp config set --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --slot broken `
    --startup-file 'dotnet AmlabHello.dll' --generic-configurations "@$configurationFile" --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Could not configure the broken slot runtime.' }
} finally {
  Remove-Item -LiteralPath $configurationFile -Force -ErrorAction SilentlyContinue
}

az webapp deploy --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --slot broken `
  --src-path $ArchivePath --type zip --restart true --async true --track-status false --output none --only-show-errors
$deployExitCode = $LASTEXITCODE
if ($deployExitCode -ne 0) {
  Write-Warning "Azure CLI returned exit code $deployExitCode for the broken-slot ZIP upload. Verifying the expected deployment before deciding whether it failed; no retry will be submitted."
}

$warmup = "https://$($broken[0].defaultHostName)/api/slot-warmup"
$maxAttempts = 90
$lastObservedDeploymentId = $null
$lastProbeError = $null
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  try {
    $response = Invoke-RestMethod -Uri $warmup -TimeoutSec 15
    $lastObservedDeploymentId = $response.deploymentId
    $lastProbeError = $null
    if ($response.ready -eq $true -and $response.deploymentId -eq $DeploymentId) {
      Write-Host "Broken slot prepared with deployment $DeploymentId."
      return
    }
  } catch {
    $lastProbeError = $_.Exception.Message
  }
  if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 10 }
}
$details = if ($lastProbeError) {
  " Last warm-up probe failed: $lastProbeError"
} else {
  " Last observed deployment ID: '$lastObservedDeploymentId'."
}
throw "Broken slot did not report deployment $DeploymentId within 15 minutes.$details"
