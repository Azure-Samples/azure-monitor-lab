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
if ($productionOutage -eq 'true') { throw 'Production is already serving the intentional outage. Use the rollback workflow instead of swapping again.' }
if ($brokenOutage -ne 'true') { throw "The broken slot is not armed with LabConsole__ForceOutage=true. No swap was attempted." }

if (-not $PSCmdlet.ShouldProcess("$WebAppName/slots/broken -> production", 'Swap the intentional outage into production')) { return }
az webapp deployment slot swap --resource-group $ResourceGroup --name $WebAppName --slot broken --target-slot production --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure did not report a successful slot swap. Inspect the deployment operation before retrying.' }

$hostName = az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostName)) { throw 'The swap completed, but the production hostname could not be verified.' }
$response = Invoke-WebRequest -Uri "https://$hostName/healthz" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
if ([int]$response.StatusCode -ne 503) { throw "The swap completed, but production returned HTTP $([int]$response.StatusCode) instead of the expected 503. Inspect both slots before another action." }
Write-Output 'The broken slot is now in production and returns HTTP 503. Recover externally by swapping the broken slot back to production.'
