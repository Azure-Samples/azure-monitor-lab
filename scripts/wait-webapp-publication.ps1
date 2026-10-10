[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*\.azurewebsites\.net$')] [string] $WebAppHost,
  [Parameter(Mandatory)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $DeploymentId,
  [ValidateRange(1, 120)] [int] $MaxAttempts = 90
)

$ErrorActionPreference = 'Stop'
Write-Host '==> Waiting for the newly published Web App version' -ForegroundColor Cyan
Write-Host "   Expected deployment: $DeploymentId" -ForegroundColor DarkGray
$lastObservation = 'No response received.'
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  try {
    $response = Invoke-WebRequest -Uri "https://$WebAppHost/api/console/version?expected=$DeploymentId" `
      -Headers @{ 'Cache-Control' = 'no-cache' } -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 15
    $version = $response.Content | ConvertFrom-Json
    $reportedVersion = if ($version.deploymentId -match '^[a-f0-9]{32}$') { $version.deploymentId } else { 'missing or invalid' }
    $lastObservation = "HTTP $($response.StatusCode); reported deployment: $reportedVersion."
    if ($response.StatusCode -eq 200 -and $version.deploymentId -ceq $DeploymentId) {
      Write-Host '   Published Web App version verified.' -ForegroundColor Green
      return
    }
  } catch {
    $lastObservation = "Version request failed: $($_.Exception.Message)"
  }
  if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
    Write-Host "   New version is not serving yet (check $attempt/$MaxAttempts). $lastObservation" -ForegroundColor DarkGray
  }
  if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 10 }
}
throw "The expected application version was not verified after $MaxAttempts checks. Host: $WebAppHost. Expected deployment: $DeploymentId. Last observation: $lastObservation Inspect App Service deployment status and startup logs before retrying. No further deployment was submitted."
