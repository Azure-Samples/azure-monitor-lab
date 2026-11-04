<#
.SYNOPSIS
  FEATURE 3 — Kick off a 60-min Smart Detection ramp load test.
.DESCRIPTION
  Renders workloads/k8s/03-loadgen-ramp.yaml with the App Service URL and applies it.
  Deletes any previous ramp Job first.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [string] $WebAppName = '',
  [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,252}\.azurewebsites\.net$')]
  [string] $WebAppHost = ''
)
$ErrorActionPreference = 'Stop'

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting."
  }
}

if (-not $WebAppHost) {
  $apps = @(az webapp list -g $ResourceGroup -o json | ConvertFrom-Json)
  $matches = if ($WebAppName) {
    @($apps | Where-Object { $_.name -ceq $WebAppName })
  } else {
    @($apps | Where-Object { $_.name -like 'app-*' })
  }
  if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace($matches[0].defaultHostName)) {
    throw 'Exactly one matching Web App with a default host is required.'
  }
  $WebAppName = $matches[0].name
  $WebAppHost = $matches[0].defaultHostName
}
$url = "https://$WebAppHost"
Write-Host "Target App Service URL: $url" -ForegroundColor Cyan

# Delete any prior ramp job + configmap so we get a clean 60-min run
kubectl -n demo delete job/loadgen-ramp --ignore-not-found | Out-Null
kubectl -n demo delete configmap/loadgen-ramp-script --ignore-not-found | Out-Null

$template = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '03-loadgen-ramp.yaml'
$rendered = Join-Path $env:TEMP "amlab-ramp-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $template).Replace('__APP_SERVICE_URL__', $url) | Set-Content -Encoding UTF8 $rendered
kubectl apply -f $rendered | Out-Host
Remove-Item $rendered -Force

Write-Host ""
Write-Host "Smart Detection ramp started. It will run for ~60 minutes."   -ForegroundColor Green
Write-Host "Watch logs with:  kubectl logs -f job/loadgen-ramp -n demo"   -ForegroundColor Yellow
Write-Host "Expect an Azure email from Smart Detection within ~15 min."   -ForegroundColor Yellow
