<#
.SYNOPSIS
  Review Fabric tenant settings or explicitly enable selected settings for a lab security group.
.DESCRIPTION
  Run separately as a Fabric administrator. Without -Apply this only lists relevant
  settings and their exact API names. Changes preserve existing groups, exclusions,
  properties and delegation. Settings that cannot be group-scoped are refused.
  This helper does not create groups, assign administrator roles or acquire licences.
.EXAMPLE
  ./scripts/setup-fabric-tenant.ps1 -TenantId <tenant-id>
.EXAMPLE
  ./scripts/setup-fabric-tenant.ps1 -TenantId <tenant-id> -SettingName <discovered-name> -SecurityGroupId <group-id> -SecurityGroupName <group-name> -Apply -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)] [guid] $TenantId,
  [string[]] $SettingName = @(),
  [guid] $SecurityGroupId,
  [string] $SecurityGroupName,
  [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($Apply -and (-not $SettingName.Count -or $SecurityGroupId -eq [guid]::Empty -or
    [string]::IsNullOrWhiteSpace($SecurityGroupName))) {
  throw '-Apply requires exact discovered -SettingName values, -SecurityGroupId and -SecurityGroupName.'
}
if (@($SettingName | Where-Object { $_ -notmatch '^[A-Za-z0-9_-]+$' }).Count -or
    @($SettingName | Select-Object -Unique).Count -ne $SettingName.Count) {
  throw 'Tenant setting names must be distinct API identifiers returned by the discovery command.'
}

. (Join-Path $PSScriptRoot 'fabric-observability.ps1')
$fabricApi = 'https://api.fabric.microsoft.com/v1'
$token = az account get-access-token --tenant $TenantId.ToString() --resource https://api.fabric.microsoft.com `
  --query '{tenant:tenant,accessToken:accessToken}' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $token.tenant -ne $TenantId.ToString() -or
    [string]::IsNullOrWhiteSpace($token.accessToken)) {
  throw 'Could not acquire a Fabric administrator token for the explicit tenant. No authentication context was changed.'
}
$script:fabricHeaders = @{ Authorization = "Bearer $($token.accessToken)" }
try {
  $settings = @(Get-FabricApiCollection -Path 'admin/tenantsettings')
  foreach ($name in $SettingName) {
    if (@($settings | Where-Object settingName -CEQ $name).Count -ne 1) {
      throw "Tenant setting '$name' was not uniquely discovered; no updates were submitted."
    }
  }
  if (-not $Apply) {
    $settings | Where-Object {
      if ($SettingName.Count) { $_.settingName -in $SettingName }
      else { "$($_.settingName) $($_.title)" -match '(?i)fabric|mirror|monitor|operations.?agent|copilot|openai' }
    } | Select-Object settingName, title, enabled, canSpecifySecurityGroups, enabledSecurityGroups, excludedSecurityGroups
    Write-Host 'Read-only discovery. Review each setting and security-group membership before using -Apply. AI/cross-geo settings are not automatically enabled.'
    return
  }

  $plans = foreach ($name in $SettingName) {
    $setting = @($settings | Where-Object settingName -CEQ $name)[0]
    if (@($setting.excludedSecurityGroups | Where-Object graphId -EQ $SecurityGroupId.ToString()).Count) {
      throw "Lab group is excluded from '$name'. Resolve the exclusion separately; no updates were submitted."
    }
    $groups = @($setting.enabledSecurityGroups | Where-Object { $null -ne $_ })
    if ($setting.enabled -eq $true -and (-not $groups.Count -or
        @($groups | Where-Object graphId -EQ $SecurityGroupId.ToString()).Count)) {
      [pscustomobject]@{ Name = $name; Body = $null }
      continue
    }
    if ($setting.canSpecifySecurityGroups -ne $true) {
      throw "Tenant setting '$name' cannot be security-group scoped. Tenant-wide enablement is not permitted by this helper; no updates were submitted."
    }
    $body = @{ enabled = $true }
    foreach ($property in @('delegateToCapacity', 'delegateToDomain', 'delegateToWorkspace', 'excludedSecurityGroups', 'properties')) {
      if ($setting.PSObject.Properties.Name -contains $property) { $body[$property] = $setting.$property }
    }
    if (-not @($groups | Where-Object graphId -EQ $SecurityGroupId.ToString()).Count) {
      $groups += @{ graphId = $SecurityGroupId.ToString(); name = $SecurityGroupName }
    }
    $body.enabledSecurityGroups = $groups
    [pscustomobject]@{ Name = $name; Body = $body }
  }

  foreach ($plan in $plans) {
    if (-not $plan.Body) {
      [pscustomobject]@{ Feature = $plan.Name; Status = 'Configured'; Detail = 'Already enabled globally or for the selected group. No write submitted; exclusions and group membership still apply.' }
      continue
    }
    $target = "tenant $TenantId, setting $($plan.Name), group $SecurityGroupName ($SecurityGroupId)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Enable Fabric tenant setting, preserving existing scope and exclusions')) {
      [pscustomobject]@{ Feature = $plan.Name; Status = 'Skipped'; Detail = 'No update submitted.' }
      continue
    }
    Invoke-RestMethod -Method Post -Uri "$fabricApi/admin/tenantsettings/$($plan.Name)/update" `
      -Headers $script:fabricHeaders -ContentType 'application/json' -Body ($plan.Body | ConvertTo-Json -Depth 12) | Out-Null
    $verified = @(Get-FabricApiCollection -Path 'admin/tenantsettings' | Where-Object settingName -CEQ $plan.Name)
    if ($verified.Count -ne 1 -or $verified[0].enabled -ne $true -or
        -not @($verified[0].enabledSecurityGroups | Where-Object graphId -EQ $SecurityGroupId.ToString()).Count) {
      throw "Tenant setting '$($plan.Name)' update was submitted once, but its saved group scope is not verified. Inspect tenant settings before retrying."
    }
    [pscustomobject]@{
      Feature = $plan.Name; Status = 'Configured'
      Detail = 'Saved enablement for the lab group verified. Existing exclusions and group membership still apply; feature availability is verified by lab setup.'
    }
  }
} finally {
  $token = $null
  $script:fabricHeaders = $null
}
