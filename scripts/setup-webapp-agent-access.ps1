[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_.()-]+$')] [string] $ResourceGroup,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $WebAppName,
  [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $SreAgentName,
  [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $FoundryAccountName,
  [ValidatePattern('^[a-zA-Z0-9_-]+$')] [string] $FoundryProjectName,
  [ValidatePattern('^[a-zA-Z0-9_.-]+$')] [string] $ModelDeployment,
  [Parameter(Mandatory)] [ValidateCount(1, 10)] [guid[]] $AllowedUserObjectIds,
  [switch] $AuthenticationOnly
)

$ErrorActionPreference = 'Stop'
if (-not $AuthenticationOnly -and (-not $SreAgentName -or -not $FoundryAccountName -or -not $FoundryProjectName -or -not $ModelDeployment)) {
  throw 'Agent setup requires the SRE, Foundry, and model targets. Use AuthenticationOnly for a lab without optional agents.'
}
$action = if ($AuthenticationOnly) { 'Configure single-tenant console operator sign-in' } else { 'Configure console sign-in, scoped app identity roles, and agent access' }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroup/$WebAppName", $action)) { return }
az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not select the expected subscription.' }
$account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
  throw 'Subscription or tenant mismatch. No resources were changed.'
}

function Get-SessionToken([string] $Resource) {
  $value = az account get-access-token --subscription $SubscriptionId --resource $Resource --query accessToken --output tsv --only-show-errors
  if ($LASTEXITCODE -ne 0 -or -not $value) { throw 'A required Azure authentication token could not be acquired.' }
  return $value
}

$tokens = @{
  'management.azure.com' = Get-SessionToken 'https://management.azure.com/'
  'graph.microsoft.com' = Get-SessionToken 'https://graph.microsoft.com/'
}

function Invoke-SetupRequest([string] $Method, [string] $Uri, [object] $Body = $null) {
  $parsed = [Uri]$Uri
  if ($parsed.Scheme -ne 'https' -or -not $tokens.ContainsKey($parsed.Host)) { throw 'Unexpected setup API endpoint.' }
  $request = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $($tokens[$parsed.Host])" }; TimeoutSec = 90; ErrorAction = 'Stop'; Verbose = $false; Debug = $false }
  if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 25 -Compress; $request.ContentType = 'application/json' }
  try { return Invoke-RestMethod @request }
  catch {
    $statusCode = [int]$_.Exception.Response.StatusCode
    if ($parsed.Host -eq 'graph.microsoft.com' -and $statusCode -eq 401) {
      throw "Microsoft Graph rejected the cached Azure CLI session. Run 'az logout', then 'az login --tenant $TenantId', select subscription $SubscriptionId, and retry the deployment."
    }
    throw "Setup API request failed: $Method $($parsed.Host)$($parsed.AbsolutePath) (HTTP $statusCode). Response details suppressed to protect credentials."
  }
}

$resourceBase = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$webId = "$resourceBase/providers/Microsoft.Web/sites/$WebAppName"
$sreId = "$resourceBase/providers/Microsoft.App/agents/$SreAgentName"
$modelId = "$resourceBase/providers/Microsoft.CognitiveServices/accounts/$FoundryAccountName"
$projectId = "$modelId/projects/$FoundryProjectName"
$arm = 'https://management.azure.com'
$version = '2024-11-01'
$phase = 'resource preflight'
try {
  $web = Invoke-SetupRequest GET "$arm${webId}?api-version=$version"
  if (-not $web.identity.principalId -or $web.identity.type -notmatch 'SystemAssigned' -or $web.identity.tenantId -ne $TenantId.ToString()) {
    throw 'The Web App needs an existing system-assigned identity in the expected tenant.'
  }
  if (-not $AuthenticationOnly) {
  $null = Invoke-SetupRequest GET "$arm${sreId}?api-version=2025-05-01-preview"
  $model = Invoke-SetupRequest GET "$arm${modelId}?api-version=2025-06-01"
  $project = Invoke-SetupRequest GET "$arm${projectId}?api-version=2025-06-01"
  $null = Invoke-SetupRequest GET "$arm$modelId/deployments/${ModelDeployment}?api-version=2025-06-01"
  $modelEndpoint = @($model.properties.endpoints.PSObject.Properties.Value | Where-Object {
    $candidate = $null
    [Uri]::TryCreate([string]$_, [UriKind]::Absolute, [ref]$candidate) -and $candidate.Scheme -eq 'https' `
      -and $candidate.Host.EndsWith('.openai.azure.com') -and $candidate.AbsolutePath -eq '/' `
      -and -not $candidate.UserInfo -and -not $candidate.Query -and -not $candidate.Fragment
  } | Select-Object -Unique)
  $projectEndpoint = @($project.properties.endpoints.PSObject.Properties.Value | Where-Object {
    $candidate = $null
    [Uri]::TryCreate([string]$_, [UriKind]::Absolute, [ref]$candidate) -and $candidate.Scheme -eq 'https' `
      -and $candidate.Host.EndsWith('.services.ai.azure.com') -and $candidate.AbsolutePath.StartsWith('/api/projects/') `
      -and -not $candidate.UserInfo -and -not $candidate.Query -and -not $candidate.Fragment
  } | Select-Object -Unique)
  if ($modelEndpoint.Count -ne 1 -or $projectEndpoint.Count -ne 1) { throw 'Could not resolve unique trusted model and project endpoints.' }
  }
  foreach ($operatorId in $AllowedUserObjectIds) { $null = Invoke-SetupRequest GET "https://graph.microsoft.com/v1.0/users/$operatorId`?`$select=id" }

  $auth = (Invoke-SetupRequest GET "$arm$webId/config/authsettingsV2?api-version=$version").properties
  $settingsResponse = Invoke-SetupRequest POST "$arm$webId/config/appsettings/list?api-version=$version"
  $settings = @{}
  foreach ($property in $settingsResponse.properties.PSObject.Properties) { $settings[$property.Name] = $property.Value }
  $issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
  $clientId = $auth.identityProviders.azureActiveDirectory.registration.clientId
  $secretSetting = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
  if ($auth.platform.enabled -and ($auth.identityProviders.azureActiveDirectory.registration.openIdIssuer -ne $issuer `
      -or $auth.identityProviders.azureActiveDirectory.registration.clientSecretSettingName -ne $secretSetting)) {
    throw 'An existing authentication configuration differs from this lab setup. Review it before changing providers.'
  }
  $roleRequests = if ($AuthenticationOnly) { @() } else { @(
    @{ Name = 'Reader'; Scope = $sreId },
    @{ Name = 'SRE Agent Administrator'; Scope = $sreId },
    @{ Name = 'Cognitive Services OpenAI User'; Scope = $modelId },
    @{ Name = 'Foundry User'; Scope = $projectId }
  ) }
  foreach ($role in $roleRequests) {
    $definitions = @(az role definition list --name $role.Name --subscription $SubscriptionId --query '[].id' --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $definitions.Count -ne 1) { throw "Could not resolve role '$($role.Name)'." }
    $role.DefinitionId = $definitions[0]
  }

  $phase = 'Entra registration'
  $displayName = "$WebAppName-lab-console"
  $identityTags = @(
    'azure-monitor-lab:managed:v1'
    "azure-monitor-lab:tenant:$($TenantId.ToString().ToLowerInvariant())"
    "azure-monitor-lab:resource-group:$($resourceBase.ToLowerInvariant())"
    'azure-monitor-lab:kind:console'
    "azure-monitor-lab:web-app:$($WebAppName.ToLowerInvariant())"
  )
  $filter = if ($clientId) { "appId eq '$clientId'" } else { "displayName eq '$displayName'" }
  $applications = (Invoke-SetupRequest GET ("https://graph.microsoft.com/v1.0/applications?`$filter=" + [Uri]::EscapeDataString($filter))).value
  if (@($applications).Count -gt 1) { throw 'Multiple matching Entra registrations exist. Select one explicitly in App Service Authentication.' }
  $callback = "https://$($web.properties.defaultHostName)/.auth/login/aad/callback"
  if (@($applications).Count -eq 1) {
    $registration = @($applications)[0]
    if (@($registration.tags) -contains 'azure-monitor-lab:managed:v1' -and
        (@($identityTags | Where-Object { $_ -notin @($registration.tags) }).Count -or
         @($registration.tags | Where-Object { $_ -like 'azure-monitor-lab:resource-group:*' }).Count -ne 1 -or
         @($registration.tags | Where-Object { $_ -like 'azure-monitor-lab:tenant:*' }).Count -ne 1)) {
      throw 'The registration ownership does not match this lab. It was not modified.'
    }
    if ($registration.signInAudience -ne 'AzureADMyOrg' -or $registration.web.redirectUris -notcontains $callback) {
      throw 'The existing registration has a different audience or redirect URI. It was not modified.'
    }
    if (-not $registration.web.implicitGrantSettings.enableIdTokenIssuance) {
      $null = Invoke-SetupRequest PATCH "https://graph.microsoft.com/v1.0/applications/$($registration.id)" @{
        web = @{ implicitGrantSettings = @{
          enableIdTokenIssuance = $true
          enableAccessTokenIssuance = [bool]$registration.web.implicitGrantSettings.enableAccessTokenIssuance
        } }
      }
      Write-Host 'Enabled ID-token issuance for the App Service hybrid sign-in flow.'
    }
  } else {
    $registration = Invoke-SetupRequest POST 'https://graph.microsoft.com/v1.0/applications' @{
      displayName = $displayName; signInAudience = 'AzureADMyOrg'
      tags = $identityTags
      web = @{ redirectUris = @($callback); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } }
      api = @{ requestedAccessTokenVersion = 2 }
    }
  }
  $ownedRegistration = @($registration.tags) -contains 'azure-monitor-lab:managed:v1'
  if ($ownedRegistration -and @($identityTags | Where-Object { $_ -notin @($registration.tags) }).Count) {
    throw 'The registration ownership does not match this lab. It will not be adopted.'
  }
  if (-not $ownedRegistration) {
    Write-Warning 'The existing Entra registration has no lab ownership record. Teardown will preserve it for manual review.'
  }
  $clientId = $registration.appId
  Write-Host "Entra registration: $clientId"
  $principals = (Invoke-SetupRequest GET ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=" + [Uri]::EscapeDataString("appId eq '$clientId'"))).value
  if (@($principals).Count -eq 0) {
    $principalBody = @{ appId = $clientId }
    if ($ownedRegistration) { $principalBody.tags = $identityTags }
    $null = Invoke-SetupRequest POST 'https://graph.microsoft.com/v1.0/servicePrincipals' $principalBody
  }

  $phase = 'sign-in credential transfer'
  $credentialExpiry = [DateTimeOffset]::MinValue
  $expiryValue = $settings['LabConsole__SignInCredentialExpiresAt']
  $expiryKnown = if ($expiryValue -is [DateTime] -or $expiryValue -is [DateTimeOffset]) {
    $credentialExpiry = [DateTimeOffset]$expiryValue
    $true
  } else {
    [DateTimeOffset]::TryParse([string]$expiryValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$credentialExpiry)
  }
  if ($expiryKnown) { $settings['LabConsole__SignInCredentialExpiresAt'] = $credentialExpiry.ToString('o') }
  if (-not $settings[$secretSetting] -or -not $expiryKnown -or $credentialExpiry -le [DateTimeOffset]::UtcNow.AddDays(30)) {
    $expiry = [DateTimeOffset]::UtcNow.AddDays(180).ToString('o')
    $credential = Invoke-SetupRequest POST "https://graph.microsoft.com/v1.0/applications/$($registration.id)/addPassword" @{
      passwordCredential = @{ displayName = 'App Service lab sign-in'; endDateTime = $expiry }
    }
    if (-not $credential.secretText) { throw 'The sign-in credential was not returned by Microsoft Entra.' }
    $settings[$secretSetting] = $credential.secretText
    $settings['LabConsole__SignInCredentialExpiresAt'] = $expiry
    $credential = $null
  }
  foreach ($name in @($settings.Keys | Where-Object { $_ -like 'LabConsole__AllowedPrincipalIds__*' })) { $settings.Remove($name) }
  for ($index = 0; $index -lt $AllowedUserObjectIds.Count; $index++) { $settings["LabConsole__AllowedPrincipalIds__$index"] = $AllowedUserObjectIds[$index].ToString() }
  $settings['WEBSITE_AUTH_AAD_ALLOWED_TENANTS'] = $TenantId.ToString()
  if (-not $AuthenticationOnly) {
  $settings['LabConsole__Sre__Enabled'] = 'false'
  $settings['LabConsole__Foundry__Enabled'] = 'false'
  $settings['LabConsole__ResourceGroup'] = $ResourceGroup
  $settings['LabConsole__AppService'] = $WebAppName
  $settings['LabConsole__Sre__SubscriptionId'] = $SubscriptionId.ToString()
  $settings['LabConsole__Sre__TenantId'] = $TenantId.ToString()
  $settings['LabConsole__Sre__AgentName'] = $SreAgentName
  $settings['LabConsole__Sre__McpExecutable'] = 'mcp/azmcp'
  $settings['LabConsole__Sre__ModelEndpoint'] = $modelEndpoint[0]
  $settings['LabConsole__Sre__ModelDeployment'] = $ModelDeployment
  $settings['LabConsole__Foundry__ProjectEndpoint'] = $projectEndpoint[0]
  }
  $settings['LabConsole__ResourceGroup'] = $ResourceGroup
  $settings['LabConsole__AppService'] = $WebAppName
  $null = Invoke-SetupRequest PUT "$arm$webId/config/appsettings?api-version=$version" @{ properties = $settings }
  $authProperties = @{
    platform = @{ enabled = $true; runtimeVersion = '~1' }
    globalValidation = @{ requireAuthentication = $false; unauthenticatedClientAction = 'AllowAnonymous' }
    httpSettings = @{ requireHttps = $true }
    identityProviders = @{ azureActiveDirectory = @{
      enabled = $true
      registration = @{ clientId = $clientId; clientSecretSettingName = $secretSetting; openIdIssuer = $issuer }
      login = @{ loginParameters = @('scope=openid profile email') }
      validation = @{ allowedAudiences = @($clientId); defaultAuthorizationPolicy = @{ allowedPrincipals = @{ identities = @($AllowedUserObjectIds | ForEach-Object { $_.ToString() }) } } }
    } }
    login = @{ tokenStore = @{ enabled = $false }; cookieExpiration = @{ convention = 'FixedTime'; timeToExpiration = '02:00:00' } }
  }
  $phase = 'App Service authentication'
  $null = Invoke-SetupRequest PUT "$arm$webId/config/authsettingsV2?api-version=$version" @{ properties = $authProperties }

  $phase = 'resource-scoped roles'
  foreach ($role in $roleRequests) {
    $existing = @(az role assignment list --assignee $web.identity.principalId --scope $role.Scope --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing managed-identity roles.' }
    if (-not @($existing | Where-Object { $_.roleDefinitionId -eq $role.DefinitionId -and $_.scope -eq $role.Scope }).Count) {
      az role assignment create --assignee-object-id $web.identity.principalId --assignee-principal-type ServicePrincipal `
        --role $role.DefinitionId --scope $role.Scope --subscription $SubscriptionId --output none --only-show-errors
      if ($LASTEXITCODE -ne 0) { throw "Role assignment failed: $($role.Name)." }
    }
    Write-Host "Scoped role ready: $($role.Name)"
  }
  $phase = 'agent enablement'
  if (-not $AuthenticationOnly) {
  $settings['LabConsole__Sre__Enabled'] = 'true'
  $settings['LabConsole__Foundry__Enabled'] = 'true'
  }
  $null = Invoke-SetupRequest PUT "$arm$webId/config/appsettings?api-version=$version" @{ properties = $settings }
  Write-Host "Console access configured for $($AllowedUserObjectIds.Count) operator(s). Anonymous traffic controls are preserved."
  Write-Host "Sign in at https://$($web.properties.defaultHostName)/.auth/login/aad"
  Write-Host "Sign-in credential expiry: $($settings['LabConsole__SignInCredentialExpiresAt'])."
} catch {
  throw "Hosted agent setup stopped during $phase. $($_.Exception.Message) Reconcile existing resources before retrying."
} finally {
  if ($null -ne $settings) { $settings.Clear() }
  $settingsResponse = $null
  $credential = $null
  $tokens.Clear()
}