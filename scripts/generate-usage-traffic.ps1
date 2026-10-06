<#
.SYNOPSIS
  Generate realistic multi-user browser journeys for Application Insights Usage analysis.

.EXAMPLE
  ./scripts/generate-usage-traffic.ps1 -BaseUrl https://app-amlab-abcde.azurewebsites.net
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $BaseUrl,

  [ValidateRange(1, 200)]
  [int] $Users = 24,

  [ValidateRange(1, 10)]
  [int] $Concurrency = 4,

  [ValidateRange(0, 200)]
  [int] $RepeatUsers = 6,

  [switch] $Headed
)

$ErrorActionPreference = 'Stop'
$uri = $null
if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
  throw 'BaseUrl must be an absolute HTTP or HTTPS URL.'
}
if ($uri.Scheme -eq 'http' -and $uri.Host -notin @('localhost', '127.0.0.1', '::1', '[::1]')) {
  throw 'HTTP is allowed only for a loopback development URL.'
}
if ($RepeatUsers -gt $Users) { throw 'RepeatUsers cannot exceed Users.' }

$webApp = Join-Path $PSScriptRoot '..' 'workloads' 'webapp'
$generator = Join-Path $webApp 'scripts' 'generate-usage-traffic.mjs'
$playwright = Join-Path $webApp 'node_modules' '@playwright' 'test'
if (-not (Test-Path -LiteralPath $playwright)) {
  throw "Playwright is not installed. Run 'npm ci --prefix workloads\webapp' and 'npx --prefix workloads\webapp playwright install chromium', then retry."
}

$arguments = @(
  $generator
  '--base-url', $uri.AbsoluteUri.TrimEnd('/')
  '--users', $Users
  '--concurrency', $Concurrency
  '--repeat-users', $RepeatUsers
)
if ($Headed) { $arguments += '--headed' }

Write-Host "Generating $Users synthetic users plus $RepeatUsers repeat sessions against $($uri.AbsoluteUri) ..." -ForegroundColor Cyan
& node @arguments
if ($LASTEXITCODE -ne 0) { throw "Usage traffic generator failed with exit code $LASTEXITCODE." }

Write-Host "`nTelemetry can take several minutes to appear in Application Insights Usage views." -ForegroundColor Green
Write-Host 'All identities, segments, products, orders, and journeys are synthetic.' -ForegroundColor DarkGray
