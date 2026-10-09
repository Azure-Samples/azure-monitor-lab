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

$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$WebAppName"
$production = az rest --method post --url "$base/config/appsettings/list?api-version=2023-12-01" --output json | ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0 -or $production.properties -isnot [Collections.IDictionary]) { throw 'Could not clone production App Service settings.' }
$production.properties['LabConsole__SlotScenarioEnabled'] = 'true'
$production.properties['LabConsole__ForceOutage'] = 'true'
$production.properties['WEBSITE_SWAP_WARMUP_PING_PATH'] = '/api/slot-warmup'
$production.properties['WEBSITE_SWAP_WARMUP_PING_STATUSES'] = '200'
$production.properties['SCM_DO_BUILD_DURING_DEPLOYMENT'] = 'false'

$settingsFile = Join-Path ([IO.Path]::GetTempPath()) "amlab-broken-slot-$([guid]::NewGuid().ToString('N')).json"
try {
  $production | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
  az rest --method put --url "$base/slots/broken/config/appsettings?api-version=2023-12-01" --body "@$settingsFile" --headers 'Content-Type=application/json' --output none
  if ($LASTEXITCODE -ne 0) { throw 'Could not configure the broken slot.' }
} finally {
  Remove-Item -LiteralPath $settingsFile -Force -ErrorAction SilentlyContinue
}

az webapp config set --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --slot broken `
  --startup-file 'dotnet AmlabHello.dll' --generic-configurations '{"healthCheckPath":"/api/slot-warmup"}' --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the broken slot runtime.' }
az webapp deploy --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName --slot broken `
  --src-path $ArchivePath --type zip --restart true --async false --track-status false --timeout 600000 --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Broken-slot ZIP deployment did not report success.' }

$warmup = "https://$($broken[0].defaultHostName)/api/slot-warmup"
for ($attempt = 1; $attempt -le 30; $attempt++) {
  try {
    $response = Invoke-RestMethod -Uri $warmup -TimeoutSec 15
    if ($response.ready -eq $true -and $response.deploymentId -eq $DeploymentId) {
      Write-Host "Broken slot prepared with deployment $DeploymentId."
      return
    }
  } catch {
    if ($attempt -eq 30) { throw "Broken-slot warm-up failed: $($_.Exception.Message)" }
  }
  Start-Sleep -Seconds 10
}
throw "Broken slot did not report deployment $DeploymentId within five minutes."
