$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('console-entry-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Operator = [guid]::NewGuid()
  Events = [Collections.Generic.List[string]]::new(); FailSetup = $false; BadTenant = $false; Uploads = 0
  OperatorRoles = 0; DeploymentWrites = 0
  DefaultOperator = $false; CurrentUserLookups = 0; ExistingOperatorRole = $false; CurrentUserUnavailable = $false
  AiSetupFails = $false; SreSetupFails = $false
  StageEResources = $false; ServiceGroupCalls = 0; SliCalls = 0; SliUnsupportedAudience = $false
  DeploymentId = ''; VersionChecks = 0
  SreResources = $false; ResourceDiscoveryFails = $false
  ActivityDiagnosticCreates = 0; ExistingActivityWorkspace = ''
  UploadFailure = ''; UploadFailuresRemaining = 0
  WebAppQuotaExceeded = $false; WebAppConfigWrites = 0
  ObservabilityEnabled = $false; ObservabilityResources = $false; RbacMigrations = 0
  PublicationMode = ''; AksCredentialRequests = 0
  Packages = [Collections.Generic.List[string]]::new()
}
foreach ($name in @('deploy.ps1', 'deploy-webapp.ps1', 'post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1', 'setup-activity-log.ps1', 'wait-webapp-publication.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source "scripts/$name") -Destination $directory
}
@{ expectedSubscriptionId = [guid]::NewGuid(); expectedTenantId = [guid]::NewGuid() } | ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')
@'
param($PublishDirectory, $ResourceGroup, $SubscriptionId, $TenantId, $CentralLawName, $SreModelEndpoint, $SreModelDeployment, $CustomerWebAppName, [switch]$BundleSreMcp)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant) { throw 'Wrong package target.' }
'{}' | Set-Content (Join-Path $PublishDirectory 'lab-console.json')
$fixture.Events.Add('package')
'@ | Set-Content (Join-Path $directory 'prepare-webapp-package.ps1')
@'
param($SubscriptionId, $TenantId, $ResourceGroup, $WebAppName, $CustomerWebAppName, $ConsoleConfigPath, $AllowedUserObjectIds)
$operatorsMatch = if ($fixture.DefaultOperator) { -not $AllowedUserObjectIds } else { $AllowedUserObjectIds[0] -eq $fixture.Operator }
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or -not $operatorsMatch -or -not (Test-Path $ConsoleConfigPath)) { throw 'Wrong automatic setup inputs.' }
$fixture.Events.Add('initialize')
if ($fixture.FailSetup) { throw 'Bootstrap failed.' }
'@ | Set-Content (Join-Path $directory 'initialize-webapp-console.ps1')
@'
param($SubscriptionId, $ResourceGroup, $WebAppName, $ArchivePath, $DeploymentId)
if ($SubscriptionId -ne $fixture.Subscription -or -not (Test-Path -LiteralPath $ArchivePath) -or $DeploymentId -ne $fixture.DeploymentId) { throw 'Wrong broken-slot publication inputs.' }
'@ | Set-Content (Join-Path $directory 'prepare-broken-slot.ps1')
@'
param([guid]$SubscriptionId, [guid]$TenantId, $ResourceGroup, $WebAppName, $CustomerWebAppName, $AksName, $WebAppHost, $CentralLawName, $ConsoleOperatorObjectIds, $AppInsightsConnectionString)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or $ConsoleOperatorObjectIds[0] -ne $fixture.Operator -or $CustomerWebAppName -ne 'app-amlab-test-customer') { throw 'Deployment wrapper lost the verified target, customer app, or operator inputs.' }
$fixture.Events.Add('post-deploy')
'@ | Set-Content (Join-Path $directory 'post-deploy.ps1')
@'
param([guid]$SubscriptionId, $ResourceGroup)
if ($SubscriptionId -ne $fixture.Subscription -or $ResourceGroup -ne 'test-rg') { throw 'SRE setup lost the verified target.' }
$fixture.Events.Add('sre')
if ($fixture.SreSetupFails) { throw 'SRE verification failed.' }
'@ | Set-Content (Join-Path $directory 'setup-sre-agent.ps1')
@'
param([guid]$SubscriptionId, $ResourceGroup)
if ($SubscriptionId -ne $fixture.Subscription -or $ResourceGroup -ne 'test-rg') { throw 'Observability Agent setup lost the verified target.' }
$fixture.Events.Add('observability-agent')
'@ | Set-Content (Join-Path $directory 'setup-observability-agent.ps1')
@'
param([guid]$SubscriptionId, $ResourceGroup, [switch]$AutoMitigation, [switch]$ObservabilityAgent)
if ($SubscriptionId -ne $fixture.Subscription -or $ResourceGroup -ne 'test-rg' -or (-not $AutoMitigation -and -not $ObservabilityAgent)) { throw 'RBAC migration lost its verified target or intent.' }
$fixture.RbacMigrations++
'@ | Set-Content (Join-Path $directory 'cleanup-legacy-rbac.ps1')
@'
param($ResourceGroup, $SubscriptionId)
$fixture.ServiceGroupCalls++
'@ | Set-Content (Join-Path $directory 'setup-health-model.ps1')
@'
param($ResourceGroup, $SubscriptionId)
$fixture.SliCalls++
if ($fixture.SliUnsupportedAudience) { throw "Cloud Shell's built-in credential cannot request the Azure Monitor Prometheus token audience. Source metrics have not been verified." }
'@ | Set-Content (Join-Path $directory 'setup-slis.ps1')
foreach ($name in @('create-summary-rule.ps1', 'send-release-annotation.ps1')) {
  'param($ResourceGroup, $WorkspaceName, $Name, $Category)' | Set-Content (Join-Path $directory $name)
}
$null = New-Item -ItemType Directory -Path (Join-Path $root 'workloads') -Force
Copy-Item -LiteralPath (Join-Path $source 'workloads/k8s') -Destination (Join-Path $root 'workloads') -Recurse

function dotnet {
  $global:LASTEXITCODE = 0
  if ($args[0] -ne 'publish') { throw 'Unexpected dotnet command.' }
  $versionArgument = @($args | Where-Object { $_ -match '^-p:InformationalVersion=[a-f0-9]{32}$' })
  if ($versionArgument.Count -ne 1 -or $args -notcontains '-p:IncludeSourceRevisionInInformationalVersion=false') { throw 'Publishing must embed a unique application version.' }
  $fixture.DeploymentId = $versionArgument[0].Split('=', 2)[1]
  $fixture.VersionChecks = 0
  $publish = $args[[Array]::IndexOf($args, '-o') + 1]
  $fixture.Packages.Add($publish)
  $null = New-Item -ItemType Directory -Path (Join-Path $publish 'wwwroot') -Force
  'offline-package' | Set-Content (Join-Path $publish 'AmlabHello.dll')
  'offline-page' | Set-Content (Join-Path $publish 'wwwroot/index.html')
  $fixture.Events.Add('publish')
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'login --tenant' {
      if ($args[2] -ne $fixture.Tenant.ToString() -or $args -notcontains '--use-device-code' -or $args -notcontains '--scope' -or $args -notcontains 'https://prometheus.monitor.azure.com/.default') {
        throw 'Cloud Shell login did not target the tenant and Managed Prometheus scope.'
      }
      $fixture.Events.Add('login')
      return '[]'
    }
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'A stale local target overrode the selected subscription.' }
      return
    }
    'account show' {
      if ($args -contains 'id' -and $args -contains 'tsv') { return $fixture.Subscription.ToString() }
      return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json
    }
    'group create' { $fixture.DeploymentWrites++; return '{}' }
    'provider show' { return 'Registered' }
    'deployment group' {
      if ($args[2] -eq 'create') { $fixture.DeploymentWrites++; return }
      if ($args[2] -ne 'show') { throw 'Unexpected deployment command.' }
      return @{
        webAppName = @{ value = 'app-amlab-test' }; webAppDefaultHost = @{ value = 'app-amlab-test.azurewebsites.net' }
        customerWebAppName = @{ value = 'app-amlab-test-customer' }
        aksName = @{ value = 'aks-amlab' }; centralLawName = @{ value = 'law-amlab-central-test' }
        grafanaEndpoint = @{ value = 'https://example.com' }; workbookId = @{ value = 'test-workbook' }
        linuxVmNameOut = @{ value = 'vm-amlab-lin' }; windowsVmNameOut = @{ value = 'vm-amlab-win' }
        observabilityAgentEnabled = @{ value = $fixture.ObservabilityEnabled }
      } | ConvertTo-Json -Depth 3
    }
    'monitor log-analytics' {
      if (($args[2..3] -join ' ') -ne 'workspace show') { throw 'Unexpected workspace command.' }
      return "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central-test"
    }
    'monitor diagnostic-settings' {
      if (($args[2..3] -join ' ') -eq 'subscription list') { return $fixture.ExistingActivityWorkspace }
      if (($args[2..3] -join ' ') -ne 'subscription create') { throw 'Unexpected Activity Log command.' }
      $fixture.ActivityDiagnosticCreates++
      $fixture.DeploymentWrites++
      return
    }
    'webapp show' {
      $nameIndex = [Array]::IndexOf($args, '--name')
      $name = if ($nameIndex -ge 0) { $args[$nameIndex + 1] } else { 'app-amlab-test' }
      return @{
        kind = 'app,linux'; host = "$name.azurewebsites.net"; defaultHostName = "$name.azurewebsites.net"
        state = $(if ($fixture.WebAppQuotaExceeded) { 'QuotaExceeded' } else { 'Running' })
        usageState = $(if ($fixture.WebAppQuotaExceeded) { 'Exceeded' } else { 'Normal' })
      } | ConvertTo-Json
    }
    'webapp config' {
      if ($args[2] -eq 'show') { return 'DOTNETCORE|8.0' }
      if ($args -notcontains '--subscription') { throw 'An app write did not specify its subscription.' }
      $fixture.WebAppConfigWrites++
      return
    }
    'webapp deploy' {
      if (($fixture.Events -join ',') -ne 'publish,package,initialize') { throw 'Code was deployed before automatic console setup.' }
      if (-not (Test-Path $args[[Array]::IndexOf($args, '--src-path') + 1])) { throw 'The app package was not created.' }
      if ($args[[Array]::IndexOf($args, '--async') + 1] -ne 'true') { throw 'App Service ZIP deployments must not wait synchronously on the SCM endpoint.' }
      $fixture.Uploads++
      if ($fixture.UploadFailuresRemaining -gt 0) {
        $fixture.UploadFailuresRemaining--
        $failureText = $fixture.UploadFailure.Replace("'", "''")
        & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$failureText'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
      }
      return
    }
    'resource list' {
      if ($fixture.ResourceDiscoveryFails) { $global:LASTEXITCODE = 1; return '[]' }
      if ($args -contains 'Microsoft.Insights/dataCollectionRules') { return '[{"id":"test-dcr","name":"dcr-amlab-customlogs"}]' }
      if ($args -contains '[0].id') { return 'test-component' }
      $resources = @(
        @{ name = 'app-amlab-test'; type = 'Microsoft.Web/sites' },
        @{ name = 'app-amlab-test-customer'; type = 'Microsoft.Web/sites' },
        @{ name = 'aks-amlab'; type = 'Microsoft.ContainerService/managedClusters' },
        @{ name = 'law-amlab-central-test'; type = 'Microsoft.OperationalInsights/workspaces' },
        @{ name = 'appi-amlab-test1'; id = 'test-component'; type = 'Microsoft.Insights/components' }
      )
      if ($fixture.StageEResources) { $resources += @{ name = 'id-sli-amlab'; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' } }
      if ($fixture.SreResources) { $resources += @{ name = 'sre-amlab-test'; type = 'Microsoft.App/agents' } }
      if ($fixture.ObservabilityResources) { $resources += @{ name = 'obs-amlab-test'; type = 'Microsoft.Monitor/observabilityAgents' } }
      return ConvertTo-Json -InputObject $resources
    }
    'resource show' { return 'offline-connection' }
    'aks get-credentials' {
      if ($args -notcontains '--subscription') { throw 'Kubernetes discovery lost its subscription.' }
      $fixture.AksCredentialRequests++
      return
    }
    'role assignment' {
      if ($args -notcontains '--subscription') { throw 'Operator access lost its subscription.' }
      if ($args[2] -eq 'list') {
        $assignments = @(@{ principalId = [guid]::NewGuid().ToString(); scope = 'test-dcr' })
        if ($fixture.ExistingOperatorRole) { $assignments += @{ principalId = $fixture.Operator.ToString(); scope = 'test-dcr' } }
        return ConvertTo-Json -InputObject $assignments -Compress
      }
      if ($args[[Array]::IndexOf($args, '--assignee-object-id') + 1] -ne $fixture.Operator.ToString() -or $args -notcontains 'User') { throw 'Operator access targeted the deployment service principal.' }
      $fixture.OperatorRoles++
      return
    }
    'rest --method' {
      if ($args[2] -ne 'get' -or $args -notcontains 'https://graph.microsoft.com/v1.0/me?$select=id' -or $args -notcontains '--subscription') { throw 'Unexpected operator discovery request.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Operator discovery lost the verified subscription.' }
      $fixture.CurrentUserLookups++
      if ($fixture.CurrentUserUnavailable) { $global:LASTEXITCODE = 1; return '{}' }
      return @{ id = $fixture.Operator.ToString() } | ConvertTo-Json
    }
    default { throw 'Unexpected native Azure call.' }
  }
}

function Start-Sleep { }
function Invoke-WebRequest {
  param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $Headers, $MaximumRedirection)
  if ($Uri -like '*/api/console/version*') {
    $fixture.VersionChecks++
    if ($fixture.PublicationMode -eq 'unreachable') { throw 'The application hostname could not be resolved.' }
    if ($fixture.PublicationMode -eq 'unauthorized') { return @{ StatusCode = 401; Content = (@{ deploymentId = $fixture.DeploymentId } | ConvertTo-Json -Compress) } }
    if ($fixture.PublicationMode -eq 'malformed') { return @{ StatusCode = 200; Content = '<html>Unavailable</html>' } }
    $version = if ($fixture.VersionChecks -eq 1 -or $fixture.PublicationMode -eq 'stale') { 'old-version' } else { $fixture.DeploymentId }
    return @{ StatusCode = 200; Content = (@{ deploymentId = $version } | ConvertTo-Json -Compress) }
  }
  return @{ StatusCode = 200 }
}
function kubectl { $global:LASTEXITCODE = 0; if ($args[0] -eq 'get') { return '203.0.113.10' } }

try {
  $parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; WebAppName = 'app-amlab-test'; ConsoleOperatorObjectIds = @($fixture.Operator) }
  & (Join-Path $directory 'deploy-webapp.ps1') @parameters -WhatIf
  if ($fixture.Events.Count -or $fixture.Uploads) { throw 'WhatIf performed deployment work.' }
  & (Join-Path $directory 'deploy-webapp.ps1') @parameters | Out-Null
  if ($fixture.Uploads -ne 1 -or $fixture.VersionChecks -ne 2) { throw 'Successful app deployment did not upload and verify the new package.' }
  $fixture.Events.Clear()
  $fixture.UploadFailure = 'ERROR: 504 GatewayTimeout from app-amlab-test.scm.azurewebsites.net/api/deployments/latest'
  $fixture.UploadFailuresRemaining = 1
  $uploadsBefore = $fixture.Uploads
  $fixture.VersionChecks = 0
  & (Join-Path $directory 'deploy-webapp.ps1') @parameters | Out-Null
  if ($fixture.Uploads -ne $uploadsBefore + 1 -or $fixture.VersionChecks -ne 2) {
    throw 'An ambiguous SCM timeout must reconcile the exact published application version without retrying the upload.'
  }
  $fixture.Uploads = 1
  $fixture.UploadFailure = ''
  $fixture.UploadFailuresRemaining = 0
  $fixture.VersionChecks = 0
  foreach ($failure in @('FailSetup', 'BadTenant')) {
    $fixture.Events.Clear()
    $fixture[$failure] = $true
    $rejected = $false
    try { & (Join-Path $directory 'deploy-webapp.ps1') @parameters | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.Uploads -ne 1) { throw 'An incomplete console was published.' }
    $fixture[$failure] = $false
  }
  foreach ($name in @('post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
    $fixture.Events.Clear()
    $fixture.ServiceGroupCalls = 0
    $wrapperArguments = if ($name -eq 'post-cloud-shell-deploy.ps1') { @{ TenantId = $fixture.Tenant } } else { @{} }
    & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @wrapperArguments | Out-Null
    $expectedEvents = if ($name -eq 'post-cloud-shell-deploy.ps1') { 'login,post-deploy' } else { 'post-deploy' }
    if (($fixture.Events -join ',') -ne $expectedEvents) { throw 'Deployment completion did not invoke the expected login and shared console path.' }
    $expectedServiceGroups = if ($name -eq 'post-staged-deploy.ps1') { 0 } else { 1 }
    if ($fixture.ServiceGroupCalls -ne $expectedServiceGroups) { throw 'Staged deployment must not enable Service Group setup implicitly.' }
  }
  if ($fixture.ActivityDiagnosticCreates -ne 2) { throw 'Portal and staged completion must configure Activity Log routing.' }
  $fixture.ExistingActivityWorkspace = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central-test"
  & (Join-Path $directory 'setup-activity-log.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -WorkspaceName law-amlab-central-test | Out-Null
  if ($fixture.ActivityDiagnosticCreates -ne 2) { throw 'Matching Activity Log routing must be idempotent.' }
  $fixture.ExistingActivityWorkspace = ''
  foreach ($name in @('post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
    foreach ($selection in @(
      @{ Resources = $false; Config = $true; Explicit = @{}; Expected = 'post-deploy' },
      @{ Resources = $true; Config = $false; Explicit = @{}; Expected = 'post-deploy,sre' },
      @{ Resources = $true; Config = $true; Explicit = @{ EnableStageSreAgent = $false }; Expected = 'post-deploy' },
      @{ Resources = $true; Config = $false; Explicit = @{ EnableStageSreAgent = $true }; Expected = 'post-deploy,sre' }
    )) {
      @{ stageToggles = @{ enableStageSreAgent = $selection.Config } } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'lab.config.json')
      $fixture.SreResources = $selection.Resources
      $fixture.Events.Clear()
      $selectionArguments = $selection.Explicit
      if ($name -eq 'post-cloud-shell-deploy.ps1') { $selectionArguments.TenantId = $fixture.Tenant }
      & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @selectionArguments | Out-Null
      $expectedSelectionEvents = if ($name -eq 'post-cloud-shell-deploy.ps1') { "login,$($selection.Expected)" } else { $selection.Expected }
      if (($fixture.Events -join ',') -ne $expectedSelectionEvents) { throw "$name must follow explicit SRE selection or deployed resources, not stale config." }
    }
    $fixture.SreSetupFails = $true
    $rejected = $false
    $failureArguments = if ($name -eq 'post-cloud-shell-deploy.ps1') { @{ TenantId = $fixture.Tenant } } else { @{} }
    try { & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @failureArguments | Out-Null }
    catch { $rejected = $_.Exception.Message -eq 'SRE verification failed.' }
    if (-not $rejected) { throw "$name hid a failed SRE validation." }
    $fixture.SreSetupFails = $false
    $fixture.ResourceDiscoveryFails = $true
    $fixture.Events.Clear()
    $rejected = $false
    try { & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @failureArguments | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*resource discovery failed.' }
    $expectedFailureEvents = if ($name -eq 'post-cloud-shell-deploy.ps1') { 'login' } else { '' }
    if (-not $rejected -or ($fixture.Events -join ',') -ne $expectedFailureEvents) { throw "$name must stop before completion when resource discovery fails." }
    $fixture.ResourceDiscoveryFails = $false
  }
  $fixture.ObservabilityResources = $true
  $fixture.SreResources = $false
  foreach ($name in @('post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
    $fixture.Events.Clear()
    $migrationsBefore = $fixture.RbacMigrations
    $wrapperArguments = if ($name -eq 'post-cloud-shell-deploy.ps1') { @{ TenantId = $fixture.Tenant } } else { @{} }
    & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @wrapperArguments | Out-Null
    $expectedEvents = if ($name -eq 'post-cloud-shell-deploy.ps1') { 'login,post-deploy,observability-agent' } else { 'post-deploy,observability-agent' }
    if (($fixture.Events -join ',') -ne $expectedEvents -or $fixture.RbacMigrations -ne $migrationsBefore + 1) {
      throw "$name did not verify and migrate the discovered Observability Agent RBAC (events: $($fixture.Events -join ','), migrations: $($fixture.RbacMigrations - $migrationsBefore))."
    }
  }
  $fixture.ObservabilityResources = $false
  $fixture.SliUnsupportedAudience = $true
  $fixture.SreResources = $true
  $fixture.Events.Clear()
  $messages = & (Join-Path $directory 'post-cloud-shell-deploy.ps1') -TenantId $fixture.Tenant -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) *>&1 | Out-String
  if (($fixture.Events -join ',') -ne 'login,post-deploy,sre' -or $messages -notmatch 'Continuing post-deployment' -or $messages -notmatch 'Managed Prometheus source metrics verified: False') {
    throw 'Cloud Shell must continue remaining setup when only its Prometheus MSI audience is unsupported.'
  }
  $fixture.SliUnsupportedAudience = $false
  $fixture.SreResources = $false
  Remove-Item -LiteralPath (Join-Path $root 'lab.config.json')
  foreach ($selection in @(
    @{ Config = $false; Explicit = @{}; Expected = 0 },
    @{ Config = $true; Explicit = @{}; Expected = 1 },
    @{ Config = $true; Explicit = @{ EnableStageE = $false }; Expected = 0 },
    @{ Config = $false; Explicit = @{ EnableStageE = $true }; Expected = 1 }
  )) {
    @{ stageToggles = @{ enableStageE = $selection.Config } } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'lab.config.json')
    $fixture.StageEResources = $true
    $fixture.Events.Clear()
    $fixture.ServiceGroupCalls = 0
    $fixture.SliCalls = 0
    $selectionArguments = $selection.Explicit
    & (Join-Path $directory 'post-staged-deploy.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) @selectionArguments | Out-Null
    if ($fixture.ServiceGroupCalls -ne $selection.Expected -or $fixture.SliCalls -ne $selection.Expected) { throw 'Stage E selection or explicit override was not respected.' }
  }
  $fixture.StageEResources = $false
  Remove-Item -LiteralPath (Join-Path $root 'lab.config.json')
  $terraformConsole = Get-Content -LiteralPath (Join-Path $source 'terraform/console.tf') -Raw
  if ($terraformConsole -notmatch 'LAB_ENABLE_STAGE_E\s*=\s*tostring\(var\.enable_stage_e\)' -or
      $terraformConsole -notmatch '-EnableStageE \(\[bool\]::Parse\(\$env:LAB_ENABLE_STAGE_E\)\)' -or
      $terraformConsole -notmatch 'LAB_ENABLE_STAGE_SRE_AGENT\s*=\s*tostring\(var\.enable_stage_sre_agent\)' -or
      $terraformConsole -notmatch '-EnableStageSreAgent \(\[bool\]::Parse\(\$env:LAB_ENABLE_STAGE_SRE_AGENT\)\)' -or
      $terraformConsole -notmatch 'scripts/setup-activity-log\.ps1' -or
      $terraformConsole -notmatch 'scripts/wait-webapp-publication\.ps1') {
    throw 'Terraform must explicitly pass its Stage E/SRE selections and track publication-verifier changes.'
  }
  @{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } | ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')
  @'
param($ResourceGroup, [guid]$SubscriptionId)
if ($SubscriptionId -ne $fixture.Subscription) { throw 'One-shot SLI setup lost the verified subscription.' }
'@ | Set-Content (Join-Path $directory 'setup-slis.ps1')
  foreach ($inheritedAccount in @($null, [pscustomobject]@{ id = [guid]::NewGuid(); tenantId = [guid]::NewGuid() })) {
    $active = $inheritedAccount
    $fixture.Events.Clear()
    $fixture.DeploymentWrites = 0
    & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) | Out-Null
    if (($fixture.Events -join ',') -ne 'post-deploy' -or $fixture.DeploymentWrites -ne 3) { throw 'One-shot deployment did not complete its verified account handoff.' }
  }
  $fixture.BadTenant = $true
  $fixture.Events.Clear()
  $fixture.DeploymentWrites = 0
  $rejected = $false
  try { & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.DeploymentWrites -or $fixture.Events.Count) { throw 'One-shot account mismatch did not stop before deployment.' }
  $fixture.BadTenant = $false
  'param()' | Set-Content (Join-Path $directory 'sync-config.ps1')
  @'
param([guid]$SubscriptionId, [guid]$TenantId, $ResourceGroup, [switch]$BackgroundTraffic)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or $ResourceGroup -ne 'test-rg') { throw 'AI setup lost the verified target.' }
if (-not $BackgroundTraffic) { throw 'AI traffic must not block one-shot deployment.' }
$fixture.Events.Add('ai')
if ($fixture.AiSetupFails) { throw 'Traffic startup failed.' }
'@ | Set-Content (Join-Path $directory 'setup-ai.ps1')
  @{
    subscriptionId = $fixture.Subscription
    stageToggles = @{ enableStageAI = $true; enableStageSreAgent = $true }
  } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'lab.config.json')
  foreach ($aiSetupFails in @($false, $true)) {
    $fixture.AiSetupFails = $aiSetupFails
    $fixture.Events.Clear()
    $messages = & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) 6>&1 | Out-String
    if (($fixture.Events -join ',') -ne 'post-deploy,sre,ai') { throw 'AI setup must run last, after SRE verification.' }
    if ($messages -notmatch 'Lab setup complete\.') { throw 'One-shot deployment did not report setup completion.' }
    if (($messages -match 'Agent traffic started in the background\.') -eq $aiSetupFails) { throw 'Traffic startup reporting did not reflect whether launch succeeded.' }
  }
  $fixture.AiSetupFails = $false
  $fixture.SreSetupFails = $true
  $fixture.Events.Clear()
  $rejected = $false
  try { & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) | Out-Null }
  catch { $rejected = $_.Exception.Message -eq 'SRE verification failed.' }
  if (-not $rejected -or ($fixture.Events -join ',') -ne 'post-deploy,sre') { throw 'AI traffic must not start after failed SRE verification.' }
  $fixture.SreSetupFails = $false
  foreach ($selection in @(
    @{ Ai = $false; Sre = $true; Events = 'post-deploy,sre' },
    @{ Ai = $true; Sre = $false; Events = 'post-deploy,ai' },
    @{ Ai = $false; Sre = $false; Events = 'post-deploy' }
  )) {
    @{
      subscriptionId = $fixture.Subscription
      stageToggles = @{ enableStageAI = $selection.Ai; enableStageSreAgent = $selection.Sre }
    } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'lab.config.json')
    $fixture.Events.Clear()
    $messages = & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) 6>&1 | Out-String
    if (($fixture.Events -join ',') -ne $selection.Events -or ($messages -match 'Agent traffic started in the background\.') -ne $selection.Ai) { throw 'Optional AI/SRE selection was not respected.' }
  }
  $fixture.ObservabilityEnabled = $true
  @{
    subscriptionId = $fixture.Subscription
    stageToggles = @{ enableStageObservabilityAgent = $true }
  } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'lab.config.json')
  $migrationsBefore = $fixture.RbacMigrations
  $fixture.Events.Clear()
  & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) | Out-Null
  if ($fixture.RbacMigrations -ne $migrationsBefore + 1 -or
      ($fixture.Events -join ',') -ne 'post-deploy,observability-agent') {
    throw 'One-shot deployment did not migrate and validate the optional Observability Agent RBAC.'
  }
  $fixture.ObservabilityEnabled = $false
  Remove-Item -LiteralPath (Join-Path $root 'lab.config.json')
  $postDeploy = Get-Content -LiteralPath (Join-Path $source 'scripts/post-deploy.ps1') -Raw
  if ($postDeploy.IndexOf("'initialize-webapp-console.ps1'") -lt 0 -or $postDeploy.IndexOf("'initialize-webapp-console.ps1'") -gt $postDeploy.IndexOf('Compress-Archive')) { throw 'Shared publication does not wait for automatic console setup.' }
  foreach ($wrapperName in @('post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
    $wrapper = Get-Content -LiteralPath (Join-Path $source "scripts/$wrapperName") -Raw
    if ($wrapper -notmatch 'name -notmatch .*customer' -or
        $wrapper -notmatch 'CustomerWebAppName\s+\$customerWebAppName') {
      throw "$wrapperName must select the Control Center separately and pass the dedicated customer Web App."
    }
  }
  $fixture.Events.Clear()
  Copy-Item -LiteralPath (Join-Path $source 'scripts/post-deploy.ps1') -Destination $directory -Force
  & (Join-Path $directory 'post-deploy.ps1') @parameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null
  if ($fixture.Uploads -ne 2 -or $fixture.VersionChecks -ne 2 -or $fixture.OperatorRoles -ne 1 -or $fixture.CurrentUserLookups) { throw 'Shared deployment did not verify its publication and configure the supplied operator without interactive-user lookup.' }
  $fixture.WebAppQuotaExceeded = $true
  $fixture.Events.Clear()
  $configWritesBefore = $fixture.WebAppConfigWrites
  $rejected = $false
  try { & (Join-Path $directory 'post-deploy.ps1') @parameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net | Out-Null }
  catch { $rejected = $_.Exception.Message -like '*quota-blocked*QuotaExceeded*' }
  if (-not $rejected -or $fixture.Events.Count -or $fixture.Uploads -ne 2 -or $fixture.WebAppConfigWrites -ne $configWritesBefore) {
    throw 'A quota-blocked Web App must stop before configuration, build, bootstrap, or upload.'
  }
  $fixture.WebAppQuotaExceeded = $false
  Write-Output 'PASS: a quota-blocked Web App stops with actionable diagnostics before any app changes. No Azure calls.'
  foreach ($nativeErrorPreference in @($true, $false)) {
    foreach ($uploadCase in @(
      @{ Message = 'SCM container restart'; Failures = 1; Attempts = 2; Success = $true },
      @{ Message = 'Zip deployment failed. Status Code: 502'; Failures = 1; Attempts = 2; Success = $true },
      @{ Message = 'SCM container restart'; Failures = 5; Attempts = 3; Success = $false },
      @{ Message = 'AuthorizationFailed: upload was denied'; Failures = 1; Attempts = 1; Success = $false },
      @{ Message = 'ERROR: NameResolutionError: app-amlab-test.scm.azurewebsites.net /api/publish getaddrinfo failed'; Failures = 1; Attempts = 1; Success = $false },
      @{ Message = 'ERROR: AuthorizationFailed: app-amlab-test.scm.azurewebsites.net /api/deployments/latest'; Failures = 1; Attempts = 1; Success = $false }
    )) {
      $fixture.Events.Clear()
      $fixture.UploadFailure = $uploadCase.Message
      $fixture.UploadFailuresRemaining = $uploadCase.Failures
      $fixture.VersionChecks = 0
      $uploadsBefore = $fixture.Uploads
      & {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
        $failureMessage = ''
        try {
          & (Join-Path $directory 'post-deploy.ps1') @parameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null
        } catch { $failureMessage = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativeErrorPreference) { throw 'Upload handling changed the caller native-error preference.' }
        if ($uploadCase.Success) {
          if ($failureMessage -or $fixture.VersionChecks -ne 2) { throw "A transient upload failure bypassed retry/publication verification: $failureMessage" }
        } elseif ($failureMessage -notlike 'App Service ZIP upload failed*' -or
                  -not $failureMessage.Contains($uploadCase.Message) -or $fixture.VersionChecks -ne 0) {
          throw "A failed upload must preserve CLI diagnostics and stop before publication verification (messageMatch=$($failureMessage.Contains($uploadCase.Message)), versionChecks=$($fixture.VersionChecks)): $failureMessage"
        }
      }
      if ($fixture.Uploads - $uploadsBefore -ne $uploadCase.Attempts) { throw 'ZIP upload retries did not respect the known error and retry bound.' }
    }
  }
  foreach ($nativeErrorPreference in @($true, $false)) {
    foreach ($publicationMode in @('served', 'stale', 'unreachable', 'unauthorized', 'malformed')) {
      $fixture.PublicationMode = $publicationMode
      $fixture.Events.Clear()
      $fixture.UploadFailure = "ERROR: HTTPSConnectionPool(host='app-amlab-test.scm.azurewebsites.net'): Max retries exceeded with url: /api/deployments/latest (Caused by NameResolutionError('getaddrinfo failed'))"
      $fixture.UploadFailuresRemaining = 1
      $uploadsBefore = $fixture.Uploads
      $aksBefore = $fixture.AksCredentialRequests
      & {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
        $failureMessage = ''
        try {
          & (Join-Path $directory 'post-deploy.ps1') @parameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null
        } catch { $failureMessage = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativeErrorPreference) { throw 'Status reconciliation changed the caller native-error preference.' }
        if ($publicationMode -eq 'served') {
          if ($failureMessage -or $fixture.VersionChecks -ne 2 -or $fixture.AksCredentialRequests -ne $aksBefore + 1) {
            throw "A DNS failure during deployment status must reconcile the exact published version: $failureMessage"
          }
        } elseif ($failureMessage -notlike '*expected application version*could not be verified*' -or
                  -not $failureMessage.Contains($fixture.DeploymentId) -or
                  -not $failureMessage.Contains($fixture.UploadFailure) -or
                  $fixture.VersionChecks -ne 90 -or $fixture.AksCredentialRequests -ne $aksBefore -or
                  -not (Test-Path -LiteralPath "$($fixture.Packages[$fixture.Packages.Count - 1]).zip")) {
          throw "Unverified publication must retain the package and diagnostics and stop before AKS setup: $failureMessage"
        }
      }
      if ($fixture.Uploads -ne $uploadsBefore + 1) { throw 'An ambiguous deployment status must not cause another ZIP upload.' }
    }
  }
  $fixture.PublicationMode = ''
  $fixture.UploadFailuresRemaining = 0
  Write-Output 'PASS: deployment-status DNS failures use exact-version read-only reconciliation; stale/unreachable responses stop without another upload. No Azure calls.'
  Write-Output 'PASS: native upload errors preserve diagnostics, retry only known transient failures, and respect both native-error preferences. No Azure calls.'
  $defaultParameters = $parameters.Clone()
  $defaultParameters.Remove('ConsoleOperatorObjectIds')
  $fixture.DefaultOperator = $true
  foreach ($operatorInput in @(@{}, @{ ConsoleOperatorObjectIds = $null }, @{ ConsoleOperatorObjectIds = @() })) {
    foreach ($existingOperatorRole in @($false, $true)) {
      $fixture.ExistingOperatorRole = $existingOperatorRole
      $fixture.Events.Clear()
      $fixture.CurrentUserLookups = 0
      $fixture.OperatorRoles = 0
      $fixture.DeploymentWrites = 0
      & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight @operatorInput | Out-Null
      $expectedRoleWrites = if ($existingOperatorRole) { 0 } else { 1 }
      if ($fixture.CurrentUserLookups -ne 1 -or $fixture.OperatorRoles -ne $expectedRoleWrites -or $fixture.DeploymentWrites -ne 3) { throw 'One-shot default operator discovery did not preserve idempotent custom-log access.' }
    }
  }
  $fixture.CurrentUserUnavailable = $true
  $fixture.Events.Clear()
  $fixture.CurrentUserLookups = 0
  $fixture.OperatorRoles = 0
  $rejected = $false
  try { & (Join-Path $directory 'post-deploy.ps1') @defaultParameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null }
  catch { $rejected = $_.Exception.Message -eq 'Specify console operator IDs for a noninteractive deployment.' }
  if (-not $rejected -or $fixture.OperatorRoles -or $fixture.CurrentUserLookups -ne 1) { throw 'Failed user discovery must stop without assigning custom-log access.' }
  Write-Output 'PASS: omitted, null, and empty one-shot operator lists resolve the signed-in user; existing roles are reused; failed user discovery stops without role writes.'
  Write-Output 'PASS: one-shot, app, staged, and Cloud Shell handoffs preserve account/operator inputs, bootstrap before publication, and stop on setup failures. No Azure calls.'
} finally {
  foreach ($package in $fixture.Packages) {
    Remove-Item -LiteralPath $package, "$package.zip" -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}