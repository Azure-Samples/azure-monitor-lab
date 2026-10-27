$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$helper = Join-Path $source 'scripts/remove-lab-entra-identities.ps1'
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); OtherSubscription = [guid]::NewGuid()
  Token = [guid]::NewGuid().ToString('N'); BadTenant = $false; CurrentClient = ''
  Apps = @(); Principals = @(); DirectoryLink = ''; ExternalScope = ''; RoleReadFails = $false
  HttpFailure = ''; DeleteFailure = ''; MissingOnDelete = $false; ForeignPage = $false; Paginate = $false
  Deletes = [Collections.Generic.List[string]]::new(); Requests = [Collections.Generic.List[string]]::new()
}
$scope = "/subscriptions/$($fixture.Subscription)/resourcegroups/test-rg"
$parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg' }

function New-TestIdentity {
  param([string] $Kind = 'console')
  $client = [guid]::NewGuid().ToString()
  $tags = @('azure-monitor-lab:managed:v1', "azure-monitor-lab:tenant:$($fixture.Tenant)", "azure-monitor-lab:resource-group:$scope", "azure-monitor-lab:kind:$Kind")
  $redirects = @()
  if ($Kind -eq 'console') { $tags += 'azure-monitor-lab:web-app:test-app'; $redirects = @('https://test-app.azurewebsites.net/.auth/login/aad/callback') }
  @{
    App = [pscustomobject]@{
      id = [guid]::NewGuid().ToString(); appId = $client; displayName = "test-$Kind"; tags = $tags
      signInAudience = 'AzureADMyOrg'; identifierUris = @(); requiredResourceAccess = @()
      web = @{ redirectUris = $redirects }; spa = @{ redirectUris = @() }; publicClient = @{ redirectUris = @() }
    }
    Principal = [pscustomobject]@{
      id = [guid]::NewGuid().ToString(); appId = $client; displayName = "test-$Kind"; tags = $tags
      servicePrincipalType = 'Application'; appOwnerOrganizationId = $fixture.Tenant.ToString(); replyUrls = $redirects
    }
  }
}

function Throw-TestHttp([int] $Status) {
  throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Offline HTTP failure', [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status))
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong Entra cleanup subscription.' }
    }
    'account show' {
      return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }); user = @{ type = 'servicePrincipal'; name = $fixture.CurrentClient } } | ConvertTo-Json
    }
    'account get-access-token' {
      if ($args -notcontains 'https://graph.microsoft.com/' -or $args -contains '--tenant') { throw 'Invalid Graph credential request.' }
      return $fixture.Token
    }
    'account list' {
      return ConvertTo-Json -InputObject @(@{ id = $fixture.Subscription; tenantId = $fixture.Tenant; state = 'Enabled' }, @{ id = $fixture.OtherSubscription; tenantId = $fixture.Tenant; state = 'Enabled' })
    }
    'role assignment' {
      if ($args[2] -ne 'list' -or $args -notcontains '--all') { throw 'Entra cleanup may only inspect all role assignments.' }
      if ($fixture.RoleReadFails) { $global:LASTEXITCODE = 1; return '[]' }
      $roleScope = if ($fixture.ExternalScope) { $fixture.ExternalScope } else { "$scope/providers/Microsoft.OperationalInsights/workspaces/law-test" }
      return ConvertTo-Json -InputObject @(@{ scope = $roleScope })
    }
    default { throw 'Unexpected Azure command in identity cleanup.' }
  }
}

function Invoke-RestMethod {
  [CmdletBinding()]
  param([string] $Method, [string] $Uri, [hashtable] $Headers, [int] $TimeoutSec)
  if ($Headers.Authorization -ne "Bearer $($fixture.Token)" -or $Uri -notlike 'https://graph.microsoft.com/v1.0/*') { throw 'Unexpected credential destination.' }
  $fixture.Requests.Add("$Method $Uri")
  if ($fixture.HttpFailure) { Throw-TestHttp 403 }
  $parsed = [uri]$Uri
  $path = $parsed.AbsolutePath
  if ($Method -eq 'GET' -and $path -match '^/v1.0/(applications|servicePrincipals)$') {
    $items = if ($Matches[1] -eq 'applications') { @($fixture.Apps) } else { @($fixture.Principals) }
    $query = [uri]::UnescapeDataString($parsed.Query)
    if ($query -match "appId eq '([^']+)'") { return @{ value = @($items | Where-Object { $_.appId -eq $Matches[1] }) } }
    if ($query -notmatch 'tags/any' -or $Headers.ConsistencyLevel -ne 'eventual') { throw 'Discovery must request ownership metadata.' }
    $items = @($items | Where-Object { $_.tags -contains "azure-monitor-lab:resource-group:$scope" })
    if ($fixture.ForeignPage) { return @{ value = $items; '@odata.nextLink' = 'https://example.invalid/v1.0/applications' } }
    if ($fixture.Paginate -and $query -notmatch 'page=2' -and $items.Count -gt 1) {
      return @{ value = @($items[0]); '@odata.nextLink' = "$Uri&page=2" }
    }
    if ($query -match 'page=2') { $items = @($items | Select-Object -Skip 1) }
    return @{ value = $items }
  }
  if ($Method -eq 'GET' -and $path -match '^/v1.0/servicePrincipals/[^/]+/(appRoleAssignments|oauth2PermissionGrants|memberOf|ownedObjects)$') {
    $relationships = @()
    if ($fixture.DirectoryLink -eq $Matches[1]) { $relationships = @(@{ id = 'other-use' }) }
    return @{ value = $relationships }
  }
  if ($Method -eq 'DELETE' -and $path -match '^/v1.0/(applications|servicePrincipals)/([a-f0-9-]+)$') {
    $collection = $Matches[1]
    $objectId = $Matches[2]
    if ($fixture.DeleteFailure -eq $collection) { Throw-TestHttp 403 }
    $items = if ($collection -eq 'applications') { @($fixture.Apps) } else { @($fixture.Principals) }
    if (-not @($items | Where-Object { $_.id -eq $objectId }).Count) { Throw-TestHttp 404 }
    $fixture.Deletes.Add($path)
    if ($collection -eq 'applications') { $fixture.Apps = @($items | Where-Object { $_.id -ne $objectId }) }
    else { $fixture.Principals = @($items | Where-Object { $_.id -ne $objectId }) }
    if ($fixture.MissingOnDelete) { Throw-TestHttp 404 }
    return
  }
  throw "Unexpected Graph request: $Method $path"
}

foreach ($kind in @('console', 'rbac-workspace', 'rbac-table', 'rbac-row')) {
  $identity = New-TestIdentity $kind
  $fixture.Apps += $identity.App
  $fixture.Principals += $identity.Principal
}
$fixture.Paginate = $true
$plan = @(& $helper @parameters -PlanOnly)
if ($plan.Count -ne 4 -or $fixture.Deletes.Count) { throw 'Planning must discover every owned identity across pages without deleting.' }
& $helper @parameters -Identities $plan -WhatIf
if ($fixture.Deletes.Count) { throw 'WhatIf deleted Entra identities.' }
& $helper @parameters -Identities $plan
if ($fixture.Deletes.Count -ne 8 -or $fixture.Apps.Count -or $fixture.Principals.Count) { throw 'Removal must delete both the principal and application by their exact IDs.' }
& $helper @parameters -Identities $plan
if ($fixture.Deletes.Count -ne 8) { throw 'Repeated cleanup should not submit duplicate deletes.' }

foreach ($case in @('untagged', 'other-rg', 'shared-tags', 'other-tenant', 'managed-identity', 'foreign-app', 'multitenant', 'extra-callback', 'extra-api', 'external-role', 'directory-role', 'current-deployer')) {
  $identity = New-TestIdentity
  $fixture.Apps = @($identity.App); $fixture.Principals = @($identity.Principal)
  $fixture.Deletes.Clear(); $fixture.ExternalScope = ''; $fixture.DirectoryLink = ''; $fixture.CurrentClient = ''
  switch ($case) {
    'untagged' { $identity.App.tags = @(); $identity.Principal.tags = @() }
    'other-rg' { $identity.App.tags = @($identity.App.tags | ForEach-Object { $_.Replace($scope, "${scope}-other") }); $identity.Principal.tags = $identity.App.tags }
    'shared-tags' { $identity.App.tags += "azure-monitor-lab:resource-group:${scope}-other" }
    'other-tenant' { $identity.App.tags = @($identity.App.tags | Where-Object { $_ -notlike 'azure-monitor-lab:tenant:*' }) + "azure-monitor-lab:tenant:$([guid]::NewGuid())" }
    'managed-identity' { $identity.Principal.servicePrincipalType = 'ManagedIdentity' }
    'foreign-app' { $identity.Principal.appOwnerOrganizationId = [guid]::NewGuid().ToString() }
    'multitenant' { $identity.App.signInAudience = 'AzureADMultipleOrgs' }
    'extra-callback' { $identity.App.web.redirectUris += 'https://another-app.example.com/callback' }
    'extra-api' { $identity.App.requiredResourceAccess = @(@{ resourceAppId = [guid]::NewGuid().ToString() }) }
    'external-role' { $fixture.ExternalScope = "/subscriptions/$($fixture.OtherSubscription)/resourceGroups/other-lab" }
    'directory-role' { $fixture.DirectoryLink = 'memberOf' }
    'current-deployer' { $fixture.CurrentClient = $identity.App.appId }
  }
  if (@(& $helper @parameters -PlanOnly).Count -or $fixture.Deletes.Count) { throw "Unsafe identity was selected for cleanup: $case" }
}
$fixture.ExternalScope = ''; $fixture.DirectoryLink = ''; $fixture.CurrentClient = ''; $fixture.Paginate = $false
foreach ($case in @('ownership-changed', 'wrong-plan', 'principal-replaced', 'role-denied', 'graph-denied', 'delete-denied', 'bad-tenant', 'foreign-page', 'partial-retry', 'already-absent', 'orphan-principal')) {
  $identity = New-TestIdentity 'rbac-workspace'
  $fixture.Apps = @($identity.App); $fixture.Principals = @($identity.Principal)
  $fixture.Deletes.Clear(); $fixture.Requests.Clear()
  $plan = @(& $helper @parameters -PlanOnly)
  $failure = ''
  switch ($case) {
    'ownership-changed' { $identity.App.tags = @() }
    'wrong-plan' { $plan[0].ResourceGroupId = "${scope}-other" }
    'principal-replaced' { $identity.Principal.id = [guid]::NewGuid().ToString() }
    'role-denied' { $fixture.RoleReadFails = $true }
    'graph-denied' { $fixture.HttpFailure = '403' }
    'delete-denied' { $fixture.DeleteFailure = 'servicePrincipals' }
    'bad-tenant' { $fixture.BadTenant = $true }
    'foreign-page' { $fixture.ForeignPage = $true }
    'partial-retry' { $fixture.Principals = @() }
    'already-absent' { $fixture.MissingOnDelete = $true }
    'orphan-principal' { $fixture.Apps = @() }
  }
  try {
    if ($case -eq 'foreign-page') { $null = & $helper @parameters -PlanOnly }
    else { & $helper @parameters -Identities $plan }
  } catch { $failure = $_.Exception.Message }
  if ($case -in @('partial-retry', 'already-absent', 'orphan-principal')) {
    if ($failure -or $fixture.Apps.Count -or $fixture.Principals.Count) { throw "Idempotent cleanup failed: $case $failure" }
  } elseif ($case -eq 'ownership-changed') {
    if ($fixture.Deletes.Count) { throw 'Changed ownership was not preserved.' }
  } elseif (-not $failure -or $fixture.Deletes.Count) { throw "Unsafe or failed cleanup did not stop before deleting: $case" }
  if ($failure.Contains($fixture.Token)) { throw 'Cleanup exposed an access token.' }
  $fixture.RoleReadFails = $false; $fixture.HttpFailure = ''; $fixture.DeleteFailure = ''; $fixture.BadTenant = $false
  $fixture.ForeignPage = $false; $fixture.MissingOnDelete = $false
}
Write-Output 'PASS: owned console/RBAC identities use exact IDs; planning, pagination, WhatIf, shared identities, tenant boundaries, failures, and idempotent partial cleanup are covered. No Azure calls.'

& {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('entra-setup-test-' + [guid]::NewGuid().ToString('N'))
  $directory = Join-Path $root 'scripts'
  $null = New-Item -ItemType Directory -Path $directory -Force
  Copy-Item -LiteralPath (Join-Path $source 'scripts/setup-rbac-demo.ps1') -Destination $directory
  @{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')
  $setup = @{ ResourceGroup = 'lab-one'; Apps = @(); Principals = @(); CredentialResets = 0; RoleWrites = 0; BadTenant = $false }
  $setup.Credential = [guid]::NewGuid().ToString('N')

  function az {
    $global:LASTEXITCODE = 0
    $currentScope = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($setup.ResourceGroup)"
    switch ($args[0..1] -join ' ') {
      'account set' { if ($args -notcontains $fixture.Subscription.ToString()) { throw 'Wrong setup subscription.' } }
      'account show' { return @{ id = $fixture.Subscription; tenantId = $(if ($setup.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json }
      'account get-access-token' { return $fixture.Token }
      'group show' { return $currentScope }
      'monitor log-analytics' { return @{ id = "$currentScope/providers/Microsoft.OperationalInsights/workspaces/law-test"; customerId = [guid]::NewGuid() } | ConvertTo-Json }
      'role definition' { return ConvertTo-Json -InputObject @(@{ id = 'test-role'; roleName = 'AMLAB - Granular Log Reader'; assignableScopes = @($currentScope) }) }
      'ad app' {
        if ($args[2] -eq 'list') {
          $name = $args[[Array]::IndexOf($args, '--display-name') + 1]
          if ($name -notmatch '^amlab-rbac-sp-(workspace|table|row)-[a-f0-9]{12}$') { throw 'RBAC setup must not reuse the old shared names.' }
          return ConvertTo-Json -InputObject @($setup.Apps | Where-Object { $_.displayName -eq $name }) -Depth 10
        }
        if (($args[2..3] -join ' ') -ne 'credential reset') { throw 'Unexpected app operation.' }
        $setup.CredentialResets++
        return @{ password = $setup.Credential } | ConvertTo-Json
      }
      'ad sp' {
        if ($args[2] -ne 'list') { throw 'Only scoped principal inspection expected.' }
        $filter = $args[[Array]::IndexOf($args, '--filter') + 1]
        if ($filter -notmatch "^appId eq '([^']+)'$") { throw 'Unexpected principal query.' }
        return ConvertTo-Json -InputObject @($setup.Principals | Where-Object { $_.appId -eq $Matches[1] }) -Depth 10
      }
      'role assignment' {
        if ($args[2] -ne 'create' -or $args -notcontains $fixture.Subscription.ToString() -or $args -notcontains "$currentScope/providers/Microsoft.OperationalInsights/workspaces/law-test") { throw 'Unexpected RBAC role scope.' }
        $setup.RoleWrites++
      }
      default { throw 'Unexpected RBAC setup command.' }
    }
  }

  function Invoke-RestMethod {
    [CmdletBinding()]
    param([string] $Method, [string] $Uri, [hashtable] $Headers, [string] $ContentType, [string] $Body, [int] $TimeoutSec)
    if ($Method -ne 'Post' -or $Headers.Authorization -ne "Bearer $($fixture.Token)") { throw 'Unexpected RBAC Graph request.' }
    $payload = $Body | ConvertFrom-Json
    $owner = "azure-monitor-lab:resource-group:/subscriptions/$($fixture.Subscription)/resourcegroups/$($setup.ResourceGroup)"
    if ($payload.tags -notcontains $owner -or $payload.tags -notcontains 'azure-monitor-lab:managed:v1' -or $payload.tags -notcontains "azure-monitor-lab:tenant:$($fixture.Tenant)") { throw 'RBAC ownership was not recorded during creation.' }
    if ($Uri -eq 'https://graph.microsoft.com/v1.0/applications') {
      if ($payload.signInAudience -ne 'AzureADMyOrg') { throw 'RBAC applications must remain single-tenant.' }
      $application = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); appId = [guid]::NewGuid().ToString(); displayName = $payload.displayName; signInAudience = $payload.signInAudience; tags = $payload.tags }
      $setup.Apps += $application
      return $application
    }
    if ($Uri -eq 'https://graph.microsoft.com/v1.0/servicePrincipals') {
      $principal = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); appId = $payload.appId; tags = $payload.tags; servicePrincipalType = 'Application'; appOwnerOrganizationId = $fixture.Tenant.ToString() }
      $setup.Principals += $principal
      return $principal
    }
    throw 'Unexpected RBAC object creation.'
  }

  try {
    foreach ($lab in @('lab-one', 'lab-one', 'lab-two')) {
      $setup.ResourceGroup = $lab
      $messages = & (Join-Path $directory 'setup-rbac-demo.ps1') -ResourceGroup $lab -WorkspaceName law-test *>&1 | Out-String
      if ($messages.Contains($setup.Credential) -or $messages.Contains($fixture.Token)) { throw 'RBAC setup exposed credentials.' }
      $saved = Get-Content -LiteralPath (Join-Path $directory '.rbac-demo-config.json') -Raw | ConvertFrom-Json
      if ($saved.resourceGroupId -ine "/subscriptions/$($fixture.Subscription)/resourceGroups/$lab" -or
          @($saved.servicePrincipals.PSObject.Properties).Count -ne 3 -or -not $saved.servicePrincipals.row.applicationObjectId) { throw 'RBAC identity configuration lost its lab and object IDs.' }
    }
    if ($setup.Apps.Count -ne 6 -or $setup.Principals.Count -ne 6 -or $setup.RoleWrites -ne 9) { throw 'RBAC setup must reuse a lab identity without sharing it with another lab.' }
    $setup.ResourceGroup = 'lab-one'
    $setup.Apps[0].tags = @()
    $before = $setup.CredentialResets
    $failure = ''
    try { & (Join-Path $directory 'setup-rbac-demo.ps1') -ResourceGroup lab-one -WorkspaceName law-test | Out-Null } catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*not exclusively owned*' -or $setup.CredentialResets -ne $before) { throw 'Setup must not reset credentials of an unowned registration with a matching name.' }
    $setup.BadTenant = $true
    $failure = ''
    try { & (Join-Path $directory 'setup-rbac-demo.ps1') -ResourceGroup lab-one -WorkspaceName law-test | Out-Null } catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*subscription or tenant mismatch*' -or $setup.CredentialResets -ne $before) { throw 'Setup must reject tenant mismatch before touching directory objects.' }
    Write-Output 'PASS: RBAC setup creates tagged per-lab app/principal pairs, preserves rerun IDs, and rejects unowned names and wrong tenants. No Azure calls.'
  } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}