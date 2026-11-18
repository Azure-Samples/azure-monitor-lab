<#
.SYNOPSIS
  Intentionally degrade resources so the Traffic-Lights workbook turns Orange/Red.
.DESCRIPTION
  - Stops both VMs (heartbeat ages out → Red after 15 min)
  - Scales the AKS frontend to 0 + crashloops it to bump restart counts (Orange/Red)
  - Bumps load-gen failure rate by editing the ConfigMap (more 5xx in App Service)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $WebAppName = $env:LAB_WEB_APP_NAME,
  [string] $AppInsightsName
)
$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Magenta }

function Assert-NativeCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting break-the-lab."
  }
}

. (Join-Path $PSScriptRoot 'app-insights-target.ps1')
$AppInsightsName = Resolve-LabAppInsightsName -ResourceGroup $ResourceGroup -WebAppName $WebAppName -AppInsightsName $AppInsightsName
if (-not $WebAppName) {
  if ($AppInsightsName -cnotmatch '^appi-.+$') { throw 'Specify -WebAppName for a nonstandard Application Insights name.' }
  $WebAppName = 'app-' + $AppInsightsName.Substring(5)
}
. (Join-Path $PSScriptRoot 'slot-health.ps1')
$webAppHost = (Get-LabWebAppMetadata -ResourceGroup $ResourceGroup -WebAppName $WebAppName).defaultHostName

$aksName = az aks list -g $ResourceGroup --query "[0].name" -o tsv
Assert-NativeCommandSucceeded 'Looking up the AKS cluster'
if ([string]::IsNullOrWhiteSpace($aksName)) {
  throw "No AKS cluster found in resource group '$ResourceGroup'."
}

az aks get-credentials --resource-group $ResourceGroup --name $aksName --overwrite-existing --output none
Assert-NativeCommandSucceeded "Connecting kubectl to '$aksName'"

Write-Step "Stopping all VMs in $ResourceGroup (heartbeat will go Red)"
$vms = az vm list -g $ResourceGroup --query "[].name" -o tsv
foreach ($vm in $vms) {
  Write-Host "  deallocating $vm"
  az vm deallocate -g $ResourceGroup -n $vm --no-wait | Out-Null
  Assert-NativeCommandSucceeded "Deallocating VM '$vm'"
}

Write-Step "Crashlooping the AKS frontend (Orange — restart spike)"
kubectl -n demo set image deployment/hello-frontend hello=busybox:1.36 | Out-Null
Assert-NativeCommandSucceeded 'Setting the AKS frontend crash-loop image'

Write-Step "Boosting load-gen failure rate to 80% (App Service goes Red)"
$webAppUrl = "https://$webAppHost"
$cm = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-script
  namespace: demo
data:
  loadtest.js: |
    import http from 'k6/http';
    import { sleep } from 'k6';
    export const options = { vus: 5, duration: '50s' };
    const TARGET = '$webAppUrl';
    export default function () {
      if (Math.random() < 0.8) {
        http.get(TARGET + '/api/explode?force=1');
      } else {
        http.get(TARGET + '/');
      }
      sleep(1);
    }
"@
$tmp = Join-Path $env:TEMP "amlab-broken-cm-$([guid]::NewGuid().ToString('N')).yaml"
$cm | Set-Content -Encoding UTF8 $tmp
try {
  kubectl apply -f $tmp | Out-Null
  Assert-NativeCommandSucceeded 'Updating the load-generator ConfigMap'
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$loadJobName = "loadgen-break-$(Get-Date -Format yyyyMMddHHmmss)"
kubectl -n demo create job --from=cronjob/loadgen $loadJobName | Out-Null
Assert-NativeCommandSucceeded "Starting immediate load-generator job '$loadJobName'"
kubectl -n demo patch job $loadJobName --type merge -p '{"spec":{"ttlSecondsAfterFinished":600}}' | Out-Null
Assert-NativeCommandSucceeded "Setting automatic cleanup for load-generator job '$loadJobName'"

Write-Host "`n💥 Lab is now broken on purpose. Azure Monitor alerts can take 5-10 minutes to fire." -ForegroundColor Magenta
Write-Host "Run scripts/restore-the-lab.ps1 to bring everything back." -ForegroundColor Yellow

# Drop an App Insights release annotation tagged 'Incident' so the chart shows the moment.
$annot = Join-Path $PSScriptRoot 'send-release-annotation.ps1'
if (Test-Path $annot) {
  & $annot -ResourceGroup $ResourceGroup -WebAppName $WebAppName -AppInsightsName $AppInsightsName -Name "break-the-lab-$(Get-Date -Format yyyyMMdd-HHmmss)" -Category 'Incident'
}
