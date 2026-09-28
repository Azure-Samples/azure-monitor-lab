<#
.SYNOPSIS
  Stop or deallocate the lab's startable compute resources.
.DESCRIPTION
  Cost-control counterpart to start-the-lab.ps1. Idempotently deallocates VMs
  and VMSS instances, stops AKS, and stops Web Apps in the selected resource
  group. The Web App is stopped last because it hosts the Control Center.

  This reduces compute consumption but does not eliminate all charges. App
  Service Plan, managed disks, public IPs, Grafana, Event Hubs, ACR, stored
  telemetry, and optional agent allocations can continue billing.

  Pass -WhatIf to perform resource discovery without issuing stop commands.
.EXAMPLE
  ./scripts/stop-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup
)
$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw 'BLOCKED: not on allowed lab subscription. Aborting stop-the-lab.'
  }
}

if (-not (az group exists -n $ResourceGroup | ConvertFrom-Json)) {
  throw "Resource group '$ResourceGroup' not found in the active subscription."
}

$stopped = @{ vm = @(); vmss = @(); aks = @(); webapp = @() }
$skipped = @{ vm = @(); vmss = @(); aks = @(); webapp = @() }

Write-Step 'Virtual Machines'
$vms = az vm list -g $ResourceGroup -d --query "[].{name:name, power:powerState}" -o json | ConvertFrom-Json
if (-not $vms) { Write-Info "no VMs in $ResourceGroup" }
foreach ($vm in $vms) {
  if ($vm.power -in @('VM deallocated', 'VM stopped')) {
    Write-Info "$($vm.name) already stopped"
    $skipped.vm += $vm.name
  } elseif ($PSCmdlet.ShouldProcess($vm.name, 'Deallocate virtual machine')) {
    Write-Ok "deallocating $($vm.name) (was: $($vm.power))"
    az vm deallocate -g $ResourceGroup -n $vm.name --no-wait | Out-Null
    $stopped.vm += $vm.name
  }
}

Write-Step 'VM Scale Sets'
$vmssPowerStateQuery = "[].{power:instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]}"
$vmsses = az vmss list -g $ResourceGroup --query "[].name" -o tsv
if (-not $vmsses) { Write-Info "no VMSS in $ResourceGroup" }
foreach ($name in $vmsses) {
  $instances = az vmss list-instances -g $ResourceGroup -n $name --expand instanceView --query $vmssPowerStateQuery -o json | ConvertFrom-Json
  $runningCount = @($instances | Where-Object { $_.power -eq 'PowerState/running' }).Count
  if ($runningCount -eq 0) {
    Write-Info "$name has no running instances"
    $skipped.vmss += $name
  } elseif ($PSCmdlet.ShouldProcess($name, 'Deallocate virtual machine scale set')) {
    Write-Ok "deallocating $name ($runningCount/$($instances.Count) instances running)"
    az vmss deallocate -g $ResourceGroup -n $name --no-wait | Out-Null
    $stopped.vmss += $name
  }
}

Write-Step 'AKS clusters'
$aksClusters = az aks list -g $ResourceGroup --query "[].{name:name, power:powerState.code}" -o json | ConvertFrom-Json
if (-not $aksClusters) { Write-Info "no AKS clusters in $ResourceGroup" }
foreach ($aks in $aksClusters) {
  if ($aks.power -eq 'Stopped') {
    Write-Info "$($aks.name) already Stopped"
    $skipped.aks += $aks.name
  } elseif ($PSCmdlet.ShouldProcess($aks.name, 'Stop AKS cluster')) {
    Write-Ok "stopping $($aks.name) (was: $($aks.power))"
    az aks stop -g $ResourceGroup -n $aks.name --no-wait | Out-Null
    $stopped.aks += $aks.name
  }
}

Write-Step 'Web Apps'
$webapps = az webapp list -g $ResourceGroup --query "[].{name:name, state:state}" -o json | ConvertFrom-Json
if (-not $webapps) { Write-Info "no Web Apps in $ResourceGroup" }
foreach ($webapp in $webapps) {
  if ($webapp.state -eq 'Stopped') {
    Write-Info "$($webapp.name) already Stopped"
    $skipped.webapp += $webapp.name
  } elseif ($PSCmdlet.ShouldProcess($webapp.name, 'Stop web app')) {
    Write-Ok "stopping $($webapp.name) last; the Control Center will become unavailable"
    az webapp stop -g $ResourceGroup -n $webapp.name | Out-Null
    $stopped.webapp += $webapp.name
  }
}

if ($WhatIfPreference) {
  Write-Host 'Resource discovery completed. No stop commands were issued.'
  return
}

Write-Step 'Summary'
$total = ($stopped.vm + $stopped.vmss + $stopped.aks + $stopped.webapp).Count
$noop = ($skipped.vm + $skipped.vmss + $skipped.aks + $skipped.webapp).Count
Write-Host "  Stop/deallocate commands issued: $total  ·  Already stopped: $noop" -ForegroundColor Yellow
Write-Host "`nCompute usage is being reduced. Fixed services, retained resources, telemetry, and optional agents can still incur charges." -ForegroundColor Yellow
Write-Host 'Use teardown.ps1 when the lab is no longer needed, and verify deletion completes.' -ForegroundColor Yellow
