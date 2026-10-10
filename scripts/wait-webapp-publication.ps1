[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*\.azurewebsites\.net$')] [string] $WebAppHost,
  [Parameter(Mandatory)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $DeploymentId,
  [ValidateRange(1, 120)] [int] $MaxAttempts = 90
)

$ErrorActionPreference = 'Stop'
Write-Host '==> Waiting for the newly published Web App version' -ForegroundColor Cyan
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  try {
    $response = Invoke-WebRequest -Uri "https://$WebAppHost/api/console/version?expected=$DeploymentId" `
      -Headers @{ 'Cache-Control' = 'no-cache' } -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 15
    $version = $response.Content | ConvertFrom-Json
    if ($response.StatusCode -eq 200 -and $version.deploymentId -ceq $DeploymentId) {
      Write-Host '   Published Web App version verified.' -ForegroundColor Green
      return
    }
  } catch { }
  if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
    Write-Host "   New version is not serving yet (check $attempt/$MaxAttempts)." -ForegroundColor DarkGray
  }
  if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 10 }
}
throw "The expected application version was not verified after $MaxAttempts checks. Inspect App Service deployment status before retrying. No further deployment was submitted."
