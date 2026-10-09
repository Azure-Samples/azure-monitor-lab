[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]{2,60}$')] [string] $WebAppName,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'
if ($ResourceGroup.EndsWith('.')) { throw 'Invalid resource group.' }

function Get-Setting {
  param([string] $Slot)
  $arguments = @('webapp', 'config', 'appsettings', 'list', '--resource-group', $ResourceGroup, '--name', $WebAppName, '--output', 'json')
  if ($Slot) { $arguments += @('--slot', $Slot) }
  $settings = @(& az @arguments | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw "Could not read App Service settings for '$($Slot ?? 'production')'." }
  return ($settings | Where-Object name -eq 'LabConsole__ForceOutage' | Select-Object -First 1).value
}

$productionOutage = Get-Setting
$brokenOutage = Get-Setting -Slot 'broken'
if ($productionOutage -ne 'true') {
  if ($brokenOutage -eq 'true') {
    Write-Output 'Production is already healthy and the broken slot is armed. No rollback was needed.'
    return
  }
  throw 'The slot state is ambiguous: neither production nor the broken slot has the expected outage marker. No swap was attempted.'
}
if ($brokenOutage -eq 'true') { throw 'Both slots have the outage marker. No swap was attempted.' }

if (-not $PSCmdlet.ShouldProcess("$WebAppName/slots/broken -> production", 'Reverse the failed production swap')) { return }
az webapp deployment slot swap --resource-group $ResourceGroup --name $WebAppName --slot broken --target-slot production --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure did not report a successful rollback swap. Inspect the deployment operation before retrying.' }

$hostName = az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostName)) { throw 'The rollback completed, but the production hostname could not be verified.' }
$response = Invoke-WebRequest -Uri "https://$hostName/healthz" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
if ([int]$response.StatusCode -ne 200) { throw "The rollback completed, but production health returned HTTP $([int]$response.StatusCode). Investigate before taking another action." }
Write-Output 'Production health is restored. The intentional outage is back in the broken slot.'
