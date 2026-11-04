<#
.SYNOPSIS
  Post an Application Insights Release Annotation to mark a deployment / incident
  on the App Insights timeline.

.DESCRIPTION
  Release annotations show as vertical lines in the App Insights metric charts
  (Performance, Failures, Live Metrics). They're how SRE teams correlate a spike
  with "what changed". This script posts via the ARM-backed Annotations API
  (no SDK / no auth dance — uses az access token).

.PARAMETER ResourceGroup
  Lab RG.

.PARAMETER Category
  Logical event category stored in annotation metadata. Application Insights
  requires the display category to be Deployment for the marker to appear.

.PARAMETER Name
  Annotation display name.

.PARAMETER WebAppName
  Exact Control Center Web App name (app-<suffix>); resolves appi-<suffix>.

.PARAMETER AppInsightsName
  Explicit non-customer component name. Must agree with WebAppName when supplied.

.EXAMPLE
  ./scripts/send-release-annotation.ps1 -Name "v1.2 hotfix"
  ./scripts/send-release-annotation.ps1 -Name "Lab broken intentionally" -Category Incident
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [string] $Name          = "release-$(Get-Date -Format yyyyMMdd-HHmmss)",
  [string] $Category      = 'Deployment',
  [string] $WebAppName    = $env:LAB_WEB_APP_NAME,
  [string] $AppInsightsName
)
$ErrorActionPreference = 'Stop'

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
}

. (Join-Path $PSScriptRoot 'app-insights-target.ps1')
$appi = Resolve-LabAppInsightsName -ResourceGroup $ResourceGroup -WebAppName $WebAppName -AppInsightsName $AppInsightsName

$subId = az account show --query id -o tsv
$annotationId = [guid]::NewGuid().ToString()
$body = @{
  Id            = $annotationId
  AnnotationName = $Name
  EventTime     = (Get-Date).ToUniversalTime().ToString('o')
  Category      = 'Deployment'
  Properties    = (@{
    ReleaseName = $Name
    BuildNumber = (Get-Date -Format 'yyyyMMddHHmmss')
    Source      = 'amlab-demo'
    EventCategory = $Category
  } | ConvertTo-Json -Compress)
} | ConvertTo-Json -Depth 5

$uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/microsoft.insights/components/$appi/Annotations?api-version=2015-05-01"
$token = az account get-access-token --resource 'https://management.azure.com' --query accessToken -o tsv

Write-Host "==> Posting release annotation '$Name' (event category: $Category) to $appi" -ForegroundColor Cyan
Invoke-RestMethod -Method PUT -Uri $uri -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null
Write-Host "✅ Annotation created. Visible as a vertical line on App Insights charts within ~30 s." -ForegroundColor Green
