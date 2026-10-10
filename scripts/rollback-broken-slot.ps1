[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]{2,60}$')] [string] $WebAppName
)

$ErrorActionPreference = 'Stop'
if ($ResourceGroup.EndsWith('.')) { throw 'Invalid resource group.' }
. (Join-Path $PSScriptRoot 'slot-health.ps1')

$production = az webapp show --resource-group $ResourceGroup --name $WebAppName `
  --query '{state:state,defaultHostName:defaultHostName}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $production.state -ne 'Running' -or -not $production.defaultHostName) {
  throw 'The customer production Web App is not running or did not report a hostname.'
}
$slots = @(az webapp deployment slot list --resource-group $ResourceGroup --name $WebAppName --output json --only-show-errors | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect customer Web App deployment slots.' }
$broken = @($slots | Where-Object name -eq 'broken')
if ($broken.Count -ne 1 -or [string]::IsNullOrWhiteSpace($broken[0].defaultHostName)) {
  throw "The customer Web App's 'broken' slot is not uniquely addressable."
}

$productionStatus = Get-LabWebAppHealthStatus -HostName $production.defaultHostName
$brokenStatus = Get-LabWebAppHealthStatus -HostName $broken[0].defaultHostName
if ($productionStatus -eq 200 -and $brokenStatus -eq 503) {
  Write-Output 'The customer Web App is already healthy and the broken slot is armed. No rollback was needed.'
  return
}
if ($productionStatus -ne 503 -or $brokenStatus -ne 200) {
  throw "The slot state is ambiguous (production HTTP $productionStatus, broken slot HTTP $brokenStatus). No swap was attempted."
}

if (-not $PSCmdlet.ShouldProcess("$WebAppName/slots/broken -> production", 'Restore the customer Web App from its healthy slot')) { return }
az webapp deployment slot swap --resource-group $ResourceGroup --name $WebAppName --slot broken --target-slot production --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Azure did not report a successful rollback swap. Inspect the deployment operation before retrying.' }

Wait-LabWebAppHealthStatus -HostName $production.defaultHostName -ExpectedStatusCode 200
Wait-LabWebAppHealthStatus -HostName $broken[0].defaultHostName -ExpectedStatusCode 503
Write-Output 'Customer production health is restored. The intentional outage is back in the broken slot.'
