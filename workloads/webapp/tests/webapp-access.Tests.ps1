$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../../../scripts/setup-webapp-agent-access.ps1'
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Operator = [guid]::NewGuid()
  Identity = [guid]::NewGuid(); Client = [guid]::NewGuid(); Registration = [guid]::NewGuid()
  Credential = [guid]::NewGuid().ToString(); BadTenant = $false; FailRole = $false
  Applications = @(); Principals = @(); Auth = @{ platform = @{ enabled = $false } }
  Settings = @{ ExistingSetting = 'preserve-me' }; RoleDefinitions = @{}; Roles = @()
  AddedCredentials = 0; RegistrationUpdates = 0; Requests = @(); SettingsWrites = @()
}
$parameters = @{
  SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'
  WebAppName = 'test-webapp'; SreAgentName = 'test-sre'; FoundryAccountName = 'test-foundry'
  FoundryProjectName = 'test-project'; ModelDeployment = 'test-model'; AllowedUserObjectIds = @($fixture.Operator)
}

function az {
  $global:LASTEXITCODE = 0
  if ($args -notcontains '--subscription' -and $args[1] -ne 'show') { throw 'Missing explicit subscription.' }
  if ($args[0] -eq 'account' -and $args[1] -eq 'set') { return }
  if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
    return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json
  }
  if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
    if ($args -contains '--tenant') { throw 'Token acquisition must not combine subscription and tenant arguments.' }
    return 'offline-access-token'
  }
  if ($args[0] -eq 'role' -and $args[1] -eq 'definition') {
    $name = $args[[Array]::IndexOf($args, '--name') + 1]
    if (-not $fixture.RoleDefinitions.ContainsKey($name)) { $fixture.RoleDefinitions[$name] = "/providers/Microsoft.Authorization/roleDefinitions/$([guid]::NewGuid())" }
    return ConvertTo-Json -InputObject @($fixture.RoleDefinitions[$name])
  }
  if ($args[0] -eq 'role' -and $args[1] -eq 'assignment' -and $args[2] -eq 'list') { return ConvertTo-Json -InputObject @($fixture.Roles) }
  if ($args[0] -eq 'role' -and $args[1] -eq 'assignment' -and $args[2] -eq 'create') {
    if ($fixture.FailRole) { $global:LASTEXITCODE = 1; return }
    $scope = $args[[Array]::IndexOf($args, '--scope') + 1]
    if ($scope -notlike "*/resourceGroups/test-rg/providers/*") { throw 'Role scope is too broad.' }
    $fixture.Roles += @{ roleDefinitionId = $args[[Array]::IndexOf($args, '--role') + 1]; scope = $scope }
    return
  }
  throw "Unexpected CLI command: $($args[0..2] -join ' ')"
}

function Invoke-RestMethod {
  [CmdletBinding()]
  param([string] $Method, [string] $Uri, [hashtable] $Headers, [string] $Body, [string] $ContentType, [int] $TimeoutSec)
  $fixture.Requests += "$Method $Uri"
  $payload = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
  if ($Uri -match '/users/') { return @{ id = $fixture.Operator } }
  if ($Uri -match '/applications\?') { return @{ value = $fixture.Applications } }
  if ($Uri.EndsWith('/applications') -and $Method -eq 'POST') {
    if ($payload.signInAudience -ne 'AzureADMyOrg' -or $payload.web.redirectUris[0] -ne 'https://test-webapp.azurewebsites.net/.auth/login/aad/callback') { throw 'Unsafe Entra audience or redirect.' }
    foreach ($tag in @('azure-monitor-lab:managed:v1', "azure-monitor-lab:tenant:$($fixture.Tenant)", "azure-monitor-lab:resource-group:/subscriptions/$($fixture.Subscription)/resourcegroups/test-rg", 'azure-monitor-lab:kind:console', 'azure-monitor-lab:web-app:test-webapp')) {
      if ($payload.tags -notcontains $tag) { throw 'New console registrations must record exact lab ownership for teardown.' }
    }
    if ($payload.web.implicitGrantSettings.enableIdTokenIssuance -ne $true -or $payload.web.implicitGrantSettings.enableAccessTokenIssuance) { throw 'App Service requires hybrid ID tokens, not implicit access tokens.' }
    $payload.id = $fixture.Registration.ToString(); $payload.appId = $fixture.Client.ToString()
    $fixture.Applications = @($payload)
    return ($payload | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
  }
  if ($Uri -eq "https://graph.microsoft.com/v1.0/applications/$($fixture.Registration)" -and $Method -eq 'PATCH') {
    if ($payload.Count -ne 1 -or $payload.web.Count -ne 1 -or -not $payload.web.ContainsKey('implicitGrantSettings')) { throw 'Sign-in repair must only change the token-issuance settings.' }
    if ($payload.web.implicitGrantSettings.enableIdTokenIssuance -ne $true) { throw 'Hybrid sign-in ID tokens were not enabled.' }
    if ($payload.web.implicitGrantSettings.enableAccessTokenIssuance -ne $fixture.Applications[0].web.implicitGrantSettings.enableAccessTokenIssuance) { throw 'Existing access-token policy was modified.' }
    $fixture.RegistrationUpdates++
    $fixture.Applications[0].web.implicitGrantSettings = $payload.web.implicitGrantSettings
    return @{}
  }
  if ($Uri -match '/servicePrincipals\?') { return @{ value = $fixture.Principals } }
  if ($Uri.EndsWith('/servicePrincipals')) {
    if (($payload.tags -join ',') -ne ($fixture.Applications[0].tags -join ',')) { throw 'New service principals must retain the registration ownership tags.' }
    $fixture.Principals = @(@{ appId = $fixture.Client.ToString(); tags = $payload.tags }); return @{}
  }
  if ($Uri.EndsWith('/addPassword')) { $fixture.AddedCredentials++; return @{ secretText = $fixture.Credential } }
  if ($Uri -match '/config/appsettings/list') { return (@{ properties = $fixture.Settings } | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
  if ($Uri -match '/config/appsettings\?' -and $Method -eq 'PUT') {
    $fixture.Settings = $payload.properties
    $fixture.SettingsWrites += $payload.properties.Clone()
    return @{}
  }
  if ($Uri -match '/config/authsettingsV2') {
    if ($Method -eq 'PUT') { $fixture.Auth = $payload.properties }
    return (@{ properties = $fixture.Auth } | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
  }
  if ($Uri -match '/sites/test-webapp\?') {
    return @{ identity = @{ principalId = $fixture.Identity.ToString(); tenantId = $fixture.Tenant.ToString(); type = 'SystemAssigned' }; properties = @{ defaultHostName = 'test-webapp.azurewebsites.net' } }
  }
  if ($Uri -match '/projects/test-project\?') { return ([pscustomobject]@{ properties = [pscustomobject]@{ endpoints = [pscustomobject]@{ API = 'https://test-foundry.services.ai.azure.com/api/projects/test-project' } } }) }
  if ($Uri -match '/accounts/test-foundry\?') { return ([pscustomobject]@{ properties = [pscustomobject]@{ endpoints = [pscustomobject]@{ OpenAI = 'https://test-foundry.openai.azure.com/' } } }) }
  if ($Uri -match '/agents/test-sre\?|/deployments/test-model\?') { return @{} }
  throw "Unexpected REST endpoint: $Method $Uri"
}

& $helper @parameters -WhatIf
if ($fixture.Requests.Count -ne 0) { throw 'WhatIf called Azure.' }
$output = & $helper @parameters 6>&1 | Out-String
if ($output.Contains($fixture.Credential)) { throw 'A generated sign-in credential was printed.' }
if ($fixture.AddedCredentials -ne 1 -or $fixture.Roles.Count -ne 4) { throw 'Expected one sign-in credential and four scoped roles.' }
if ($fixture.Settings.ExistingSetting -ne 'preserve-me') { throw 'Unrelated app settings were overwritten.' }
if ($fixture.Settings['LabConsole__AllowedPrincipalIds__0'] -ne $fixture.Operator.ToString()) { throw 'Operator allowlist missing.' }
if ($fixture.Auth.globalValidation.requireAuthentication -or $fixture.Auth.globalValidation.unauthenticatedClientAction -ne 'AllowAnonymous') { throw 'Anonymous demo endpoints were disabled.' }
if ($fixture.Auth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities[0] -ne $fixture.Operator.ToString()) { throw 'Provider operator restriction missing.' }
if ($fixture.SettingsWrites[0]['LabConsole__Sre__Enabled'] -ne 'false' -or $fixture.SettingsWrites[-1]['LabConsole__Sre__Enabled'] -ne 'true') { throw 'Agent enablement was not gated on completed access setup.' }
& $helper @parameters | Out-Null
if ($fixture.AddedCredentials -ne 1 -or $fixture.Roles.Count -ne 4) { throw 'Repeated setup recreated a credential or role.' }
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$expectedExpiry = [DateTimeOffset]::new([DateTimeOffset]::UtcNow.Year + 2, 3, 13, 12, 0, 0, [TimeSpan]::Zero)
try {
  foreach ($culture in @('en-US', 'en-BE')) {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
    $fixture.Settings['LabConsole__SignInCredentialExpiresAt'] = $expectedExpiry.ToString('o')
    & $helper @parameters | Out-Null
    if ($fixture.AddedCredentials -ne 1 -or [DateTimeOffset]$fixture.Settings['LabConsole__SignInCredentialExpiresAt'] -ne $expectedExpiry) { throw "Credential expiry parsing depends on locale: $culture" }
  }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }
if ($fixture.RegistrationUpdates -ne 0) { throw 'A compatible registration was unnecessarily modified.' }
$fixture.Applications[0].web.redirectUris += 'https://test-webapp.azurewebsites.net/extra-callback'
$fixture.Applications[0].web.implicitGrantSettings.enableIdTokenIssuance = $false
& $helper @parameters | Out-Null
if ($fixture.RegistrationUpdates -ne 1 -or $fixture.Applications[0].web.implicitGrantSettings.enableIdTokenIssuance -ne $true) { throw 'An older registration was not repaired for hybrid sign-in.' }
if ($fixture.Applications[0].web.implicitGrantSettings.enableAccessTokenIssuance -or $fixture.Applications[0].web.redirectUris.Count -ne 2) { throw 'Repair changed unrelated registration settings.' }
& $helper @parameters | Out-Null
if ($fixture.RegistrationUpdates -ne 1 -or $fixture.AddedCredentials -ne 1 -or $fixture.Roles.Count -ne 4) { throw 'Repaired registration was not idempotent or recreated resources.' }
$fixture.Settings['LabConsole__SignInCredentialExpiresAt'] = [DateTimeOffset]::UtcNow.AddDays(10).ToString('o')
& $helper @parameters | Out-Null
if ($fixture.AddedCredentials -ne 2 -or [DateTimeOffset]$fixture.Settings['LabConsole__SignInCredentialExpiresAt'] -le [DateTimeOffset]::UtcNow.AddDays(30)) { throw 'Redeployment did not renew the near-expiry sign-in credential.' }
& $helper @parameters | Out-Null
if ($fixture.AddedCredentials -ne 2) { throw 'Credential renewal is not idempotent.' }
$ownedTags = $fixture.Applications[0].tags
$fixture.Applications[0].tags = @()
$output = & $helper @parameters 3>&1 | Out-String
if ($fixture.Applications[0].tags.Count -or $output -notmatch 'Teardown will preserve it for manual review') { throw 'Existing untracked registrations must not be silently adopted for deletion.' }
$fixture.Applications[0].tags = $ownedTags
$fixture.Applications[0].tags += "azure-monitor-lab:resource-group:/subscriptions/$($fixture.Subscription)/resourcegroups/another-lab"
$credentialCount = $fixture.AddedCredentials
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $_.Exception.Message -like '*ownership does not match*' }
if (-not $caught -or $fixture.AddedCredentials -ne $credentialCount) { throw 'A shared registration must not be claimed by setup.' }
$fixture.Applications[0].tags = $ownedTags
$fixture.Roles = @(); $fixture.FailRole = $true
 $beforeAgentRequests = @($fixture.Requests | Where-Object { $_ -match '/agents/|/accounts/' }).Count
 $authOnly = $parameters.Clone()
 foreach ($key in @('SreAgentName', 'FoundryAccountName', 'FoundryProjectName', 'ModelDeployment')) { $authOnly.Remove($key) }
 & $helper @authOnly -AuthenticationOnly | Out-Null
 if (@($fixture.Requests | Where-Object { $_ -match '/agents/|/accounts/' }).Count -ne $beforeAgentRequests) { throw 'Authentication-only setup queried optional agent resources.' }
 if ($fixture.Roles.Count -ne 0 -or $fixture.Settings['LabConsole__Sre__Enabled'] -ne 'true') { throw 'Authentication-only setup changed existing agent roles or settings.' }
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $true }
if (-not $caught -or $fixture.Settings['LabConsole__Sre__Enabled'] -ne 'false') { throw 'Role failure did not fail closed.' }
$fixture.BadTenant = $true
$before = $fixture.Requests.Count
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $true }
if (-not $caught -or $fixture.Requests.Count -ne $before) { throw 'Tenant mismatch did not stop before resource operations.' }
Write-Host 'PASS: hybrid sign-in configuration and repair, operator restrictions, secret transfer, scoped roles, rerun safety, and fail-closed setup.'