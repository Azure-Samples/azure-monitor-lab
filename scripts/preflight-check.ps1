<#
.SYNOPSIS
  Pre-flight availability + quota check for the Azure Monitor Lab.

.DESCRIPTION
  Validates — BEFORE a 20-minute deployment starts — that everything the lab needs is
  actually deployable in the target region for the current subscription:

    1. VM SKUs (Linux/Windows VM, AKS nodes, VMSS) exist in the region and are NOT
       restricted for this subscription (NotAvailableForSubscription / zone restrictions).
    2. Per-family vCPU quota has enough headroom for the VMs the lab will create,
       plus the region-wide "Total Regional Cores" quota.
    3. The PaaS resource types the lab deploys (AKS, App Service, Managed Grafana,
       Azure Monitor Workspace, Event Hub, Key Vault, Log Analytics) are available
       in the region.
    4. When requested, the Observability Agent location is supported and the
       subscription has not reached the five-agent preview limit.

  Prints a PASS / WARN / FAIL table and returns a non-zero exit code (and throws when
  invoked from deploy.ps1) if any hard blocker is found, so you fail in ~15 seconds
  instead of 20 minutes in.

.PARAMETER Location
  Target region (e.g. swedencentral). Required.

.PARAMETER VmSize
  SKU for the Linux + Windows demo VMs. Defaults to the Bicep default (Standard_B2s).

.PARAMETER AksNodeVmSize
  SKU for the AKS node pool. Defaults to the Bicep default (Standard_B2s).

.PARAMETER AksNodeCount
  AKS node count. Defaults to 1 (Bicep default).

.PARAMETER VmssSize
  SKU for the predictive-autoscale VMSS. Defaults to the Bicep default (Standard_B1s).

.PARAMETER DeployLinuxVm
  Whether the Linux VM is part of the deployment. Default true.

.PARAMETER DeployWindowsVm
  Whether the Windows VM is part of the deployment. Default true.

.PARAMETER DeployObservabilityAgent
  Whether the optional Observability Agent is part of the deployment. Default false.

.PARAMETER ObservabilityAgentLocation
  Region for the optional Observability Agent and its dedicated workspace.

.PARAMETER ResourceGroup
  Target resource group. Used to distinguish an idempotent agent redeployment from
  creation of a sixth agent when the subscription preview limit is reached.

.PARAMETER WarnOnly
  Report problems but do not fail (exit 0 / no throw). Useful for a dry inspection.

.EXAMPLE
  ./scripts/preflight-check.ps1 -Location northeurope

.EXAMPLE
  ./scripts/preflight-check.ps1 -Location westeurope -AksNodeCount 2 -WarnOnly
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Location,
  [string] $VmSize          = 'Standard_B2s',
  [string] $AksNodeVmSize   = 'Standard_B2s',
  [int]    $AksNodeCount    = 1,
  [string] $VmssSize        = 'Standard_B1s',
  [bool]   $DeployLinuxVm   = $true,
  [bool]   $DeployWindowsVm = $true,
  [bool]   $DeployObservabilityAgent = $false,
  [string] $ObservabilityAgentLocation = 'westeurope',
  [string] $ResourceGroup,
  [string] $AppServicePlanTier = 'Basic',
  [switch] $WarnOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# Accumulates one row per check: @{ Check; Detail; Status } where Status is PASS/WARN/FAIL.
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($check, $detail, $status) {
  $results.Add([pscustomobject]@{ Check = $check; Detail = $detail; Status = $status })
}

# Normalize a region display name ("Sweden Central") or code ("swedencentral") to a
# comparable token so provider display-name locations line up with region codes.
function Get-RegionToken($s) { if ($null -eq $s) { '' } else { ($s -replace '\s','').ToLowerInvariant() } }
$locToken = Get-RegionToken $Location

# App Service is pinned to westeurope by the templates (northeurope has no Basic quota
# on the sponsored lab subs), so its availability + quota are validated against that
# region, not the lab $Location.
$appServiceLocation = 'westeurope'
$appServiceLocToken = Get-RegionToken $appServiceLocation

Write-Step "Pre-flight availability + quota check for region '$Location'"
$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Host "   Subscription: $($sub.name) ($($sub.id))" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 0. Region sanity — is this a real region for the subscription?
# ---------------------------------------------------------------------------
$validLocations = az account list-locations --query "[].name" -o json | ConvertFrom-Json
if ($validLocations -notcontains $Location) {
  Add-Result 'Region name' "'$Location' is not a valid region for this subscription" 'FAIL'
  # Print what we have and bail early — every downstream query needs a real region.
  $results | Format-Table -AutoSize | Out-Host
  if ($WarnOnly) { exit 0 } else { throw "Pre-flight failed: '$Location' is not a valid Azure region." }
}
Add-Result 'Region name' "'$Location' is a valid region" 'PASS'

if ($DeployObservabilityAgent) {
  $supportedAgentLocations = @(
    'australiaeast', 'canadacentral', 'centralus', 'eastasia', 'eastus',
    'southcentralus', 'uksouth', 'westcentralus', 'westeurope'
  )
  if ($supportedAgentLocations -notcontains $ObservabilityAgentLocation.ToLowerInvariant()) {
    Add-Result 'Observability Agent region' "'$ObservabilityAgentLocation' is not supported by this preview" 'FAIL'
  } else {
    Add-Result 'Observability Agent region' "'$ObservabilityAgentLocation' is supported by this preview" 'PASS'
  }

  $agentListJson = az resource list --subscription $sub.id `
    --resource-type Microsoft.Monitor/observabilityAgents `
    --query '[].{id:id}' --output json 2>$null
  if ($LASTEXITCODE -eq 0 -and $agentListJson) {
    $agents = @($agentListJson | ConvertFrom-Json)
    $agentCount = $agents.Count
    $targetAgentExists = -not [string]::IsNullOrWhiteSpace($ResourceGroup) -and
      @($agents | Where-Object { $_.id -like "*/resourceGroups/$ResourceGroup/providers/Microsoft.Monitor/observabilityAgents/*" }).Count -gt 0
    if ($agentCount -ge 5 -and -not $targetAgentExists) {
      Add-Result 'Observability Agent limit' "$agentCount existing agents; the preview maximum is five per subscription" 'FAIL'
    } elseif ($agentCount -ge 5) {
      Add-Result 'Observability Agent limit' "$agentCount existing agents; the target resource group already contains an agent, so an idempotent update does not require another slot" 'PASS'
    } else {
      Add-Result 'Observability Agent limit' "$agentCount existing agents; $((5 - $agentCount)) preview slot(s) remain" 'PASS'
    }
  } else {
    Add-Result 'Observability Agent limit' 'could not query the preview resource list; verify fewer than five agents before deployment' 'WARN'
  }
}

# ---------------------------------------------------------------------------
# Build the VM demand list: which SKUs, and how many of each, will be created.
# ---------------------------------------------------------------------------
$vmDemand = @{}   # size -> count
function Add-VmDemand($size, $count) {
  if ($count -le 0 -or [string]::IsNullOrWhiteSpace($size)) { return }
  if ($vmDemand.ContainsKey($size)) { $vmDemand[$size] += $count } else { $vmDemand[$size] = $count }
}
if ($DeployLinuxVm)   { Add-VmDemand $VmSize 1 }
if ($DeployWindowsVm) { Add-VmDemand $VmSize 1 }
Add-VmDemand $AksNodeVmSize $AksNodeCount
Add-VmDemand $VmssSize 1   # predictive-autoscale VMSS, always 1 instance

# ---------------------------------------------------------------------------
# 1. VM SKU availability + subscription restrictions (single list-skus call).
# ---------------------------------------------------------------------------
Write-Step "Checking VM SKU availability + restrictions"
$skusJson = az vm list-skus --location $Location --resource-type virtualMachines --all -o json 2>$null
$skus = if ($skusJson) { $skusJson | ConvertFrom-Json } else { @() }
$skuBySize = @{}
foreach ($s in $skus) { $skuBySize[$s.name] = $s }

# size -> family, and per-family required vCPU totals (for the quota check below).
$familyRequired = @{}   # familyValue -> required vCPUs
$totalRequiredCores = 0

foreach ($size in $vmDemand.Keys) {
  $count = $vmDemand[$size]
  $sku = $skuBySize[$size]
  if ($null -eq $sku) {
    Add-Result "VM SKU $size" "not offered in $Location (x$count needed)" 'FAIL'
    continue
  }

  $vcpuCap = ($sku.capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1).value
  $vcpu = if ($vcpuCap) { [int]$vcpuCap } else { 0 }
  $family = $sku.family

  # Subscription-level restrictions: Location = hard block, Zone = soft (non-zonal still OK).
  $locRestricted  = $false
  $zoneRestricted = $false
  foreach ($r in @($sku.restrictions)) {
    if ($r.type -eq 'Location') { $locRestricted = $true }
    if ($r.type -eq 'Zone')     { $zoneRestricted = $true }
  }

  if ($locRestricted) {
    $reason = (@($sku.restrictions) | Where-Object { $_.type -eq 'Location' } | Select-Object -First 1).reasonCode
    Add-Result "VM SKU $size" "restricted in $Location for this subscription ($reason). Request access or pick another size/region." 'FAIL'
    continue
  }

  # Tally required vCPUs for quota check (only for SKUs that are actually deployable).
  if ($family) {
    if ($familyRequired.ContainsKey($family)) { $familyRequired[$family] += ($vcpu * $count) }
    else { $familyRequired[$family] = ($vcpu * $count) }
  }
  $totalRequiredCores += ($vcpu * $count)

  if ($zoneRestricted) {
    Add-Result "VM SKU $size" "available (x$count, ${vcpu} vCPU ea, family $family) but zone-restricted — OK for non-zonal deploy" 'WARN'
  } else {
    Add-Result "VM SKU $size" "available (x$count, ${vcpu} vCPU ea, family $family)" 'PASS'
  }
}

# ---------------------------------------------------------------------------
# 2. Per-family + total regional vCPU quota headroom.
# ---------------------------------------------------------------------------
Write-Step "Checking vCPU quota headroom"
$usageJson = az vm list-usage --location $Location -o json 2>$null
$usage = if ($usageJson) { $usageJson | ConvertFrom-Json } else { @() }
$usageByName = @{}
foreach ($u in $usage) { $usageByName[$u.name.value] = $u }

foreach ($family in $familyRequired.Keys) {
  $need = $familyRequired[$family]
  $u = $usageByName[$family]
  if ($null -eq $u) {
    Add-Result "Quota $family" "need $need vCPU — usage/limit not reported (assuming default). Verify manually if deploy fails." 'WARN'
    continue
  }
  $available = [int]$u.limit - [int]$u.currentValue
  $detail = "need $need vCPU, have $available free (limit $($u.limit), used $($u.currentValue))"
  if ($need -gt $available) { Add-Result "Quota $family" "$detail — INSUFFICIENT, request an increase" 'FAIL' }
  else { Add-Result "Quota $family" $detail 'PASS' }
}

# Total Regional Cores (name.value = 'cores').
$coresUsage = $usageByName['cores']
if ($coresUsage) {
  $availCores = [int]$coresUsage.limit - [int]$coresUsage.currentValue
  $detail = "need $totalRequiredCores vCPU, have $availCores free (limit $($coresUsage.limit), used $($coresUsage.currentValue))"
  if ($totalRequiredCores -gt $availCores) { Add-Result 'Quota Total Regional Cores' "$detail — INSUFFICIENT" 'FAIL' }
  else { Add-Result 'Quota Total Regional Cores' $detail 'PASS' }
}

# ---------------------------------------------------------------------------
# 3. PaaS resource-type availability in the region.
#     NOTE: this proves the resource TYPE is offered in the region — it is NOT a
#     live-capacity guarantee. Control-plane capacity (e.g. AKS 'AksCapacityHeavyUsage')
#     is transient and has no pre-check API; deploy.ps1 handles that class at deploy time.
# ---------------------------------------------------------------------------
Write-Step "Checking PaaS resource-type availability (region offering, not live capacity)"
$paasTypes = @(
  @{ Label = 'AKS';                    Ns = 'Microsoft.ContainerService'; Type = 'managedClusters' }
  @{ Label = 'App Service (Linux)';    Ns = 'Microsoft.Web';              Type = 'sites' }
  @{ Label = 'Managed Grafana';        Ns = 'Microsoft.Dashboard';        Type = 'grafana' }
  @{ Label = 'Azure Monitor Workspace';Ns = 'Microsoft.Monitor';          Type = 'accounts' }
  @{ Label = 'Event Hub';              Ns = 'Microsoft.EventHub';         Type = 'namespaces' }
  @{ Label = 'Key Vault';              Ns = 'Microsoft.KeyVault';         Type = 'vaults' }
  @{ Label = 'Log Analytics';          Ns = 'Microsoft.OperationalInsights'; Type = 'workspaces' }
)
foreach ($t in $paasTypes) {
  $locsJson = az provider show -n $t.Ns --query "resourceTypes[?resourceType=='$($t.Type)'].locations | [0]" -o json 2>$null
  $locs = if ($locsJson) { $locsJson | ConvertFrom-Json } else { $null }
  if ($null -eq $locs -or @($locs).Count -eq 0) {
    # Global services (e.g. some are location-agnostic) report no per-region list.
    Add-Result "$($t.Label)" "$($t.Ns)/$($t.Type): no region list (global or provider not registered) — skipped" 'WARN'
    continue
  }
  # App Service is pinned to westeurope, so validate it against that region.
  $checkLoc = if ($t.Ns -eq 'Microsoft.Web') { $appServiceLocation } else { $Location }
  $checkTok = if ($t.Ns -eq 'Microsoft.Web') { $appServiceLocToken } else { $locToken }
  $tokens = @($locs | ForEach-Object { Get-RegionToken $_ })
  if ($tokens -contains $checkTok) {
    Add-Result "$($t.Label)" "available in $checkLoc" 'PASS'
  } else {
    Add-Result "$($t.Label)" "$($t.Ns)/$($t.Type) NOT available in $checkLoc — pick a supported region" 'FAIL'
  }
}

# ---------------------------------------------------------------------------
# 3b. App Service Plan quota — subscription-specific, per-region, per-tier.
#     ADVISORY ONLY (never a hard blocker). The Microsoft.Web '.../usages' Basic entry is a
#     legacy Av2-family reservation number: 'limit 0' does NOT reliably mean creation fails
#     (e.g. westus3 reports 0 yet creates Basic plans fine), while uksouth reports 0 AND
#     genuinely fails with 'InternalSubscriptionIsOverQuotaForSku'. Since the signal can't
#     tell those apart, we WARN (not FAIL) here and let ARM's fast preflight validation at
#     deploy time be the authoritative gate (deploy.ps1 hard-fails in seconds with guidance).
# ---------------------------------------------------------------------------
Write-Step "Checking App Service Plan quota ($AppServicePlanTier tier in $appServiceLocation, advisory)"
$webUsageJson = az rest --method get `
  --url "https://management.azure.com/subscriptions/$($sub.id)/providers/Microsoft.Web/locations/$appServiceLocation/usages?api-version=2023-12-01" `
  -o json 2>$null
if ($webUsageJson) {
  $webUsage = ($webUsageJson | ConvertFrom-Json).value
  $tierUsage = $webUsage | Where-Object { $_.name.localizedValue -eq $AppServicePlanTier } | Select-Object -First 1
  if ($null -eq $tierUsage) {
    Add-Result "App Service quota" "$AppServicePlanTier-tier quota not reported for $appServiceLocation — verify manually" 'WARN'
  } else {
    $webLimit = [int]$tierUsage.limit
    if ($webLimit -lt 0) {
      # Azure reports -1 for "no cap" (unlimited).
      Add-Result "App Service quota" "$AppServicePlanTier tier: unlimited (limit -1, used $($tierUsage.currentValue))" 'PASS'
    } else {
      $availWeb = $webLimit - [int]$tierUsage.currentValue
      $detail = "$AppServicePlanTier tier: reported limit $webLimit, used $($tierUsage.currentValue)"
      if ($availWeb -lt 1) {
        Add-Result "App Service quota" "$detail — region reports 0 $AppServicePlanTier quota. This signal is UNRELIABLE (some regions create Basic plans anyway). If the deploy really is blocked it fails fast with 'InternalSubscriptionIsOverQuotaForSku' — then pick another region or request an increase." 'WARN'
      } else {
        Add-Result "App Service quota" $detail 'PASS'
      }
    }
  }
} else {
  Add-Result "App Service quota" "could not query Microsoft.Web usages for $appServiceLocation — verify manually" 'WARN'
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Step "Pre-flight results"
foreach ($r in $results) {
  $color = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
  Write-Host ("  [{0,-4}] {1,-26} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
}

$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ""
Write-Host ("Summary: {0} pass, {1} warn, {2} fail" -f `
  (($results | Where-Object { $_.Status -eq 'PASS' }).Count), $warnCount, $failCount) `
  -ForegroundColor ($(if ($failCount) { 'Red' } elseif ($warnCount) { 'Yellow' } else { 'Green' }))

if ($failCount -gt 0) {
  if ($WarnOnly) {
    Write-Host "WarnOnly set — continuing despite $failCount blocker(s)." -ForegroundColor Yellow
    exit 0
  }
  throw "Pre-flight failed: $failCount blocker(s) in '$Location'. Fix the FAIL rows above (change region, pick another SKU, or request a quota increase) and retry."
}

Write-Host "✅ Pre-flight OK — region '$Location' can host the lab." -ForegroundColor Green
Write-Host "   Note: this validates availability + quota, NOT live service capacity. Transient" -ForegroundColor DarkGray
Write-Host "   region-wide shortages (e.g. AKS 'AksCapacityHeavyUsage') can't be pre-checked by any" -ForegroundColor DarkGray
Write-Host "   Azure API; if one occurs at deploy time, re-run with -Location <other region>." -ForegroundColor DarkGray
exit 0
