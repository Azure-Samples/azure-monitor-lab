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
  throw 'The customer production Web App is not running or did not report a hostname. No swap was attempted.'
}
$slots = @(az webapp deployment slot list --resource-group $ResourceGroup --name $WebAppName --output json --only-show-errors | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect customer Web App deployment slots.' }
$broken = @($slots | Where-Object name -eq 'broken')
if ($broken.Count -ne 1 -or [string]::IsNullOrWhiteSpace($broken[0].defaultHostName)) {
  throw "The customer Web App's 'broken' slot is not uniquely addressable."
}

$productionStatus = Get-LabWebAppHealthStatus -HostName $production.defaultHostName
$brokenStatus = Get-LabWebAppHealthStatus -HostName $broken[0].defaultHostName
if ($productionStatus -ne 200 -or $brokenStatus -ne 503) {
  throw "The customer slot is not in the armed state (production HTTP $productionStatus, broken slot HTTP $brokenStatus). No swap was attempted."
}

if (-not $PSCmdlet.ShouldProcess("$WebAppName/slots/broken -> production", 'Swap the intentional outage into the customer Web App')) { return }
az webapp deployment slot swap --resource-group $ResourceGroup --name $WebAppName --slot broken --target-slot production --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Azure did not report a successful slot swap. Inspect the deployment operation before retrying.' }

Wait-LabWebAppHealthStatus -HostName $production.defaultHostName -ExpectedStatusCode 503
Wait-LabWebAppHealthStatus -HostName $broken[0].defaultHostName -ExpectedStatusCode 200
Write-Output 'The customer Web App now returns HTTP 503 while this Control Center remains healthy. The SRE Agent should restore it from the matching Azure Monitor alert.'
