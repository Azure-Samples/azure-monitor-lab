$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('console-bootstrap-test-' + [guid]::NewGuid().ToString('N'))
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach ($templatePath in @('infra/main.json', 'infra/stages/10-workloads.json')) {
  $template = Get-Content -LiteralPath (Join-Path $source $templatePath) -Raw | ConvertFrom-Json
  $appModule = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'appservice' })
  if ($appModule.Count -ne 1) { throw "$templatePath must contain one App Service module." }
  $appTemplate = $appModule[0].properties.template
  $site = @($appTemplate.resources | Where-Object type -eq 'Microsoft.Web/sites')
  if ($site.Count -ne 1 -or $site[0].properties.siteConfig.PSObject.Properties.Name -contains 'appSettings') {
    throw "$templatePath must not replace existing authentication or console settings inline."
  }
  $settingsModule = @($appTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'app-settings' })
  $siteDependency = "[resourceId('Microsoft.Web/sites', parameters('webAppName'))]"
  if ($settingsModule.Count -ne 1 -or $settingsModule[0].dependsOn -notcontains $siteDependency) { throw "$templatePath must wait for the site before reading its settings, including on first deployment." }
  $settingsTemplate = $settingsModule[0].properties.template
  $settingsResource = @($settingsTemplate.resources | Where-Object type -eq 'Microsoft.Web/sites/config')
  if ($settingsResource.Count -ne 1) { throw "$templatePath must contain exactly one app-settings resource." }
  if ($settingsResource[0].properties -match '\blist\(') {
    throw "$templatePath must not list app settings from the resource being updated; ARM treats that as a circular dependency."
  }
  if ($settingsTemplate.parameters.appSettings.type -ne 'secureObject' -or $settingsTemplate.parameters.existingAppSettings.type -ne 'secureObject' -or $settingsTemplate.outputs) {
    throw 'Existing and intended app settings must be secure inputs and must not be exposed as deployment outputs.'
  }
  $existingSettings = $settingsModule[0].properties.parameters.existingAppSettings.value
  if ($existingSettings -notmatch "^\[list\(.+/config/appsettings.+\.properties\]$") {
    throw "$templatePath must read the existing app settings in the parent deployment after the web app exists."
  }
  if ($settingsResource[0].properties -cne "[union(parameters('existingAppSettings'), parameters('appSettings'))]") {
    throw "$templatePath must preserve the existing settings snapshot and overlay only the intended telemetry settings."
  }
  $intendedSettings = $settingsModule[0].properties.parameters.appSettings.value
  if ($intendedSettings.PSObject.Properties.Name -match '^LabConsole__|^MICROSOFT_PROVIDER_AUTHENTICATION_SECRET$') { throw 'Infrastructure must not replace runtime-owned console or sign-in values.' }
  Write-Output "PASS: $templatePath securely merges app settings without a resource self-reference."
  $platformModule = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'lab-console-platform' })
  $cpuParameter = $platformModule[0].properties.parameters.cpuVmNames
  $cpuExpression = if ($cpuParameter -is [string]) { $cpuParameter } else { $cpuParameter.value }
  if ($platformModule.Count -ne 1 -or $cpuExpression -notmatch "and\(parameters\('deployLinuxVm'\), parameters\('deployWindowsVm'\)\)") { throw "$templatePath must grant CPU guest access only when both demo VMs are deployed." }
}
$platformTemplate = Get-Content -LiteralPath (Join-Path $source 'infra/modules/lab-console-platform.json') -Raw | ConvertFrom-Json
$runnerRole = @($platformTemplate.resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleDefinitions' -and
    $_.properties.permissions.actions -contains 'Microsoft.Compute/virtualMachines/deallocate/action'
  })
$requiredStopActions = @(
  'Microsoft.Compute/virtualMachines/deallocate/action',
  'Microsoft.Compute/virtualMachineScaleSets/deallocate/action',
  'Microsoft.ContainerService/managedClusters/stop/action',
  'Microsoft.Web/sites/stop/action'
)
if ($runnerRole.Count -ne 1 -or @($requiredStopActions | Where-Object { $_ -notin $runnerRole[0].properties.permissions.actions }).Count) {
  throw 'The Lab Operations runner role must include every Stop Lab action.'
}
$cpuRole = @($platformTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleDefinitions' -and $_.properties.permissions.actions -contains 'Microsoft.Compute/virtualMachines/runCommand/action' })
if ($cpuRole.Count -ne 1 -or @($cpuRole[0].properties.permissions.actions).Count -ne 1) { throw 'CPU guest execution requires a separate, narrowly scoped role.' }
$cpuAssignments = @($platformTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.roleDefinitionId -like '*lab-console-cpu-run-command-role*' })
if ($cpuAssignments.Count -ne 1 -or $cpuAssignments[0].scope -notmatch 'Microsoft.Compute/virtualMachines/' -or $cpuAssignments[0].copy.count -cne "[length(parameters('cpuVmNames'))]" -or $cpuAssignments[0].properties.principalType -ne 'ServicePrincipal') { throw 'CPU role assignments must target only the selected individual VMs.' }
if ($platformTemplate.parameters.cpuVmNames.maxLength -ne 2 -or @($platformTemplate.parameters.cpuVmNames.defaultValue).Count -ne 0) { throw 'CPU execution access must default to no VM and allow at most the demo pair.' }
foreach ($templatePath in @('infra/modules/lab-console-platform.json', 'infra/modules/lab-console-job.json')) {
  $runnerTemplate = Get-Content -LiteralPath (Join-Path $source $templatePath) -Raw | ConvertFrom-Json
  foreach ($runnerModule in @($runnerTemplate.resources | Where-Object { $_.name -in @('console-runner-identity', 'console-runner-registry', 'console-runner-environment', 'console-runner-job') })) {
    $tagExpression = $runnerModule.properties.parameters.tags.value
    if ($tagExpression -notmatch '^\[union\(' -or $tagExpression -notmatch "parameters\('existingResourceTags'\)" -or $tagExpression -notmatch "parameters\('tags'\)") {
      throw "$templatePath must preserve existing runner tags and apply the selected lab tags."
    }
  }
}
$environmentModule = @($platformTemplate.resources | Where-Object { $_.name -eq 'console-runner-environment' })
if ($environmentModule.Count -ne 1 -or $environmentModule[0].properties.parameters.zoneRedundant.value -ne $false) {
  throw 'The runner environment must explicitly disable zone redundancy when no infrastructure subnet is configured.'
}
$registryModule = @($platformTemplate.resources | Where-Object { $_.name -eq 'console-runner-registry' })
if ($registryModule.Count -ne 1 -or $registryModule[0].properties.parameters.acrSku.value -ne 'Basic' -or
    $registryModule[0].properties.parameters.networkRuleSetDefaultAction.value -ne 'Allow' -or
    $registryModule[0].properties.parameters.acrAdminUserEnabled.value -ne $false -or
    $registryModule[0].properties.parameters.anonymousPullEnabled.value -ne $false) {
  throw 'Basic ACR must use authenticated public access without unsupported network rules.'
}
$scriptDirectory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $scriptDirectory -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts/initialize-webapp-console.ps1') -Destination $scriptDirectory
foreach ($directory in @('workloads/k8s', 'workloads/operations', 'infra/modules')) { $null = New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force }
foreach ($file in @('scripts/invoke-lab-operation.ps1', 'scripts/start-the-lab.ps1', 'scripts/stop-the-lab.ps1', 'scripts/break-the-lab.ps1', 'scripts/restore-the-lab.ps1', 'scripts/start-ramp.ps1', 'scripts/simulate-high-cpu.ps1', 'scripts/send-custom-logs.ps1', 'scripts/send-release-annotation.ps1', 'workloads/k8s/02-loadgen.yaml', 'workloads/k8s/03-loadgen-ramp.yaml', 'workloads/operations/Dockerfile', 'infra/modules/lab-console-job.bicep')) {
  Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $root $file)
}
$runnerDockerfile = Get-Content -LiteralPath (Join-Path $root 'workloads/operations/Dockerfile') -Raw
if ($runnerDockerfile -notmatch 'Acquire::Retries=5' -or $runnerDockerfile -notmatch '(?s)rm -rf /var/lib/apt/lists/\*.+apt-get -o Acquire::Retries=5 update') {
  throw 'Runner package installation must retry downloads and refresh a stale APT index.'
}
@'
param($SubscriptionId, $TenantId, $ResourceGroup, $WebAppName, $AllowedUserObjectIds, [switch]$AuthenticationOnly)
if (-not $AuthenticationOnly -or $AllowedUserObjectIds.Count -ne 1) { throw 'Unexpected automatic sign-in inputs.' }
$fixture.AuthCalls++
$fixture.Settings['LabConsole__AllowedPrincipalIds__0'] = $AllowedUserObjectIds[0].ToString()
if ($fixture.FailAuth) { throw 'Tenant policy blocks registration.' }
'@ | Set-Content (Join-Path $scriptDirectory 'setup-webapp-agent-access.ps1')
@'
param($ResourceGroup, $NamePrefix, $SubscriptionId, $TenantId, $ProjectEndpoint, $AppInsightsConnectionString, $ChatDeployment, [switch]$SkipTraffic)
if (-not $SkipTraffic -or $ProjectEndpoint -ne "https://testfoundry.services.ai.azure.com/api/projects/amlab-ai-proj" -or $ChatDeployment -ne 'chat-lab' -or $TenantId.ToString() -ne $fixture.Tenant) { throw 'Unexpected automatic AI inputs.' }
if ($fixture.Settings['LabConsole__Operations__Enabled'] -ne 'false') { throw 'Console was enabled before agent setup.' }
$fixture.AiCalls++
if ($fixture.FailAi) { throw 'Agent creation failed.' }
'@ | Set-Content (Join-Path $scriptDirectory 'setup-ai.ps1')
$fixture = @{
  Subscription = [guid]::NewGuid().ToString(); Tenant = [guid]::NewGuid().ToString(); Operator = [guid]::NewGuid().ToString()
  AppIdentity = [guid]::NewGuid().ToString(); RunnerIdentity = [guid]::NewGuid().ToString(); Client = [guid]::NewGuid().ToString()
  Settings = @{ Existing = 'preserve-me' }; Writes = @(); Calls = @(); Roles = @(); Definitions = @{}; AuthCalls = 0; FailAuth = $false; FailBuild = $false; BadTenant = $false; MissingLogs = $false; LogsDeployments = 0
  WithAi = $false; FailAi = $false; AiCalls = 0
  DeletePreview = $false; LastPreview = ''; Deployments = 0
  ExistingTags = $true; FailTagRead = $false
  NoCpuPair = $false; FailCpuInventory = $false; CpuScopeEscape = $false
}
$scope = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg"
$fixture.ResourceBase = $scope
$workspace = "$scope/providers/Microsoft.OperationalInsights/workspaces/central"
$jobId = "$scope/providers/Microsoft.App/jobs/job-test"
$path = Join-Path $root 'lab-console.json'
function Reset-Configuration {
  @{ LabConsole = @{ ResourceGroup = 'test-rg'; Health = @{ Enabled = $false; SubscriptionId = $fixture.Subscription; CentralWorkspaceResourceId = $workspace }; Foundry = @{}; Sre = @{} } } |
    ConvertTo-Json -Depth 8 | Set-Content $path
}
function az {
  $global:LASTEXITCODE = 0
  $fixture.Calls += ,@($args)
  if ($args -notcontains '--subscription' -and -not ($args[0] -eq 'account' -and $args[1] -eq 'show')) { throw 'Missing explicit subscription.' }
  switch ($args[0..1] -join ' ') {
    'account set' { return }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid().ToString() } else { $fixture.Tenant }) } | ConvertTo-Json }
    'account get-access-token' { if ($args -contains '--tenant') { throw 'Incompatible token flags.' }; return 'test-setup-token' }
    'provider register' { if ($args -notcontains '--wait') { throw 'Provider registration was not awaited.' }; return }
    'deployment group' {
      $deploymentName = $args[[Array]::IndexOf($args, '--name') + 1]
      if ($deploymentName -in @('lab-console-platform', 'lab-console-job')) {
        $parameterFiles = @($args | Where-Object { $_ -is [string] -and $_.StartsWith('@') })
        if ($parameterFiles.Count -ne 1) { throw 'Runner deployments must carry explicit tag parameters.' }
        $tagParameters = (Get-Content -LiteralPath $parameterFiles[0].Substring(1) -Raw | ConvertFrom-Json -AsHashtable).parameters
        if ($tagParameters.tags.value.owner -ne 'lab-owner' -or $tagParameters.tags.value.costCenter -ne 'test-center') { throw 'Runner deployment lost lab tags.' }
        if ($fixture.ExistingTags -and $tagParameters.existingResourceTags.value.acrlabtest.custom -ne 'keep-me') { throw 'Runner deployment lost resource-specific tags.' }
        if (-not $fixture.ExistingTags -and $tagParameters.existingResourceTags.value.Count) { throw 'First-time setup invented existing tags.' }
        if ($deploymentName -eq 'lab-console-platform') {
          $expectedCpuNames = if ($fixture.NoCpuPair) { @() } else { @('vm-test-lin', 'vmwintest') }
          if (@($tagParameters.cpuVmNames.value).Count -ne $expectedCpuNames.Count -or @($tagParameters.cpuVmNames.value | Where-Object { $_ -notin $expectedCpuNames }).Count) { throw 'CPU role target selection is incorrect.' }
        } elseif ($tagParameters.ContainsKey('cpuVmNames')) { throw 'VM role parameters must not leak into the job deployment schema.' }
      }
      if ($args[2] -eq 'what-if') {
        $fixture.LastPreview = $deploymentName
        return @{ status = 'Succeeded'; changes = @(@{ changeType = $(if ($fixture.DeletePreview) { 'Delete' } else { 'Create' }) }) } | ConvertTo-Json -Depth 5
      }
      if ($fixture.LastPreview -ne $deploymentName) { throw 'Deployment was not previewed first.' }
      $fixture.Deployments++
      if ($args[2] -eq 'create' -and $args -contains 'custom-logs') { $fixture.MissingLogs = $false; $fixture.LogsDeployments++; return }
      if ($args[2] -eq 'create' -and $args -contains 'lab-console-platform') {
        return @{ registryName = @{ value = 'acrlabtest' }; registryId = @{ value = "$scope/providers/Microsoft.ContainerRegistry/registries/acrlabtest" }; environmentId = @{ value = "$scope/providers/Microsoft.App/managedEnvironments/cae-test" }; runnerIdentityId = @{ value = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test" }; jobName = @{ value = 'job-test' } } | ConvertTo-Json
      }
      if ($args[2] -ne 'create' -or $args -notcontains 'lab-console-job') { throw 'Unexpected deployment operation.' }
      return @{ jobId = @{ value = $jobId } } | ConvertTo-Json
    }
    'identity show' { return @{ id = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"; principalId = $fixture.RunnerIdentity; clientId = $fixture.Client } | ConvertTo-Json }
    'resource show' { return '{"location":"westeurope"}' }
    'vm list' {
      if ($fixture.FailCpuInventory) { $global:LASTEXITCODE = 1; return '[]' }
      $vms = @(
        @{ name = 'vm-test-lin'; id = "$scope/providers/Microsoft.Compute/virtualMachines/vm-test-lin"; tags = @{ purpose = 'azure-monitor-lab' }; storageProfile = @{ osDisk = @{ osType = 'Linux' } } }
        @{ name = 'vmwintest'; id = "$scope/providers/Microsoft.Compute/virtualMachines/vmwintest"; tags = @{ purpose = 'azure-monitor-lab' }; storageProfile = @{ osDisk = @{ osType = 'Windows' } } }
        @{ name = 'unrelated'; tags = @{ purpose = 'other' } }
      )
      if ($fixture.NoCpuPair) { $vms = @($vms | Where-Object name -ne 'vmwintest') }
      if ($fixture.CpuScopeEscape) { $vms[0].id = '/subscriptions/other/resourceGroups/other/providers/Microsoft.Compute/virtualMachines/vm-test-lin' }
      return ConvertTo-Json -InputObject $vms -Depth 5
    }
    'resource list' {
      if ($fixture.FailTagRead) { $global:LASTEXITCODE = 1; return '[]' }
      $resources = @()
      if ($fixture.ExistingTags) {
        $resources += @{ type = 'Microsoft.ContainerRegistry/registries'; name = 'acrlabtest'; id = "$scope/providers/Microsoft.ContainerRegistry/registries/acrlabtest"; tags = @{ custom = 'keep-me'; owner = 'old-owner' } }
      }
      if (-not $fixture.MissingLogs) { $resources += @{ type = 'Microsoft.Insights/dataCollectionRules'; name = 'dcr-customlogs'; id = "$scope/providers/Microsoft.Insights/dataCollectionRules/dcr-customlogs" } }
      if ($fixture.WithAi) {
        $resources += @{ type = 'Microsoft.CognitiveServices/accounts/projects'; id = "$scope/providers/Microsoft.CognitiveServices/accounts/testfoundry/projects/amlab-ai-proj" }
        $resources += @{ type = 'Microsoft.Insights/components'; id = "$scope/providers/Microsoft.Insights/components/appi-test" }
      }
      return ConvertTo-Json -InputObject $resources
    }
    'cognitiveservices account' { return '[{"name":"chat-lab","properties":{"model":{"name":"gpt-5-mini"}}}]' }
    'acr build' {
      if ($args -notcontains '--no-logs') { throw 'Build output must not dump protected data.' }
      $build = $args[[Array]::IndexOf($args, '--no-logs') + 1]
      if (Test-Path (Join-Path $build 'lab-console.json')) { throw 'Build context includes local configuration.' }
      if (@(Get-ChildItem $build -File -Recurse).Count -ne 12 -or
          -not (Test-Path (Join-Path $build 'scripts/simulate-high-cpu.ps1')) -or
          -not (Test-Path (Join-Path $build 'scripts/stop-the-lab.ps1'))) {
        throw 'Unexpected runner build context or missing operation script.'
      }
      if ($fixture.FailBuild) { $global:LASTEXITCODE = 1 }
      return
    }
    'acr repository' { return ('sha256:' + ('a' * 64)) }
    'acr show' { return 'acrlabtest.azurecr.io' }
    'role definition' {
      $name = $args[[Array]::IndexOf($args, '--name') + 1]
      if (-not $fixture.Definitions.ContainsKey($name)) { $fixture.Definitions[$name] = "/providers/Microsoft.Authorization/roleDefinitions/$([guid]::NewGuid())" }
      return ConvertTo-Json -InputObject @($fixture.Definitions[$name])
    }
    'role assignment' {
      if ($args[2] -eq 'list') { return ConvertTo-Json -InputObject @($fixture.Roles) }
      $roleScope = $args[[Array]::IndexOf($args, '--scope') + 1]
      if (-not $roleScope.StartsWith("$($fixture.ResourceBase)/providers/")) { throw 'Bootstrap role scope is too broad.' }
      $fixture.Roles += @{ scope = $roleScope; principalId = $args[[Array]::IndexOf($args, '--assignee-object-id') + 1]; roleDefinitionId = $args[[Array]::IndexOf($args, '--role') + 1] }
      return
    }
    default { throw 'Unexpected Azure operation in bootstrap.' }
  }
}
function Invoke-RestMethod {
  [CmdletBinding()]
  param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
  if ($Uri -like 'https://graph.microsoft.com/v1.0/me*') { return @{ id = $fixture.Operator } }
  if ($Uri -like "https://management.azure.com$workspace*") { return @{ name = 'law-amlab-central-test'; location = 'northeurope' } }
  if ($Uri -like "https://management.azure.com$scope/providers/Microsoft.Insights/components/*") { return @{ properties = @{ ConnectionString = 'test-connection' } } }
  if ($Uri -notlike "https://management.azure.com$scope/providers/Microsoft.Web/sites/test-app*") { throw 'Unexpected setup target.' }
  if ($Uri -match '/config/appsettings/list') { return (@{ properties = $fixture.Settings } | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
  if ($Uri -match '/config/appsettings\?') {
    $fixture.Settings = ($Body | ConvertFrom-Json -AsHashtable).properties
    $fixture.Writes += $fixture.Settings.Clone()
    return @{}
  }
  return @{ location = 'westeurope'; identity = @{ principalId = $fixture.AppIdentity }; tags = @{ owner = 'lab-owner'; purpose = 'azure-monitor-lab'; costCenter = 'test-center' } }
}
try {
  Reset-Configuration
  $parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; WebAppName = 'test-app'; ConsoleConfigPath = $path }
  $output = & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters 6>&1 | Out-String
  if ($output.Contains('test-setup-token')) { throw 'Setup token leaked.' }
  $config = (Get-Content $path -Raw | ConvertFrom-Json).LabConsole
  if (-not $config.Operations.Enabled -or -not $config.Health.Enabled -or $config.Operations.JobResourceId -ne $jobId) { throw 'Successful deployment did not enable the console automatically.' }
  if ($config.Operations.Image -notmatch '@sha256:[a-f0-9]{64}$') { throw 'Runner image is not immutable.' }
  if ($fixture.AuthCalls -ne 1 -or $fixture.Settings.Existing -ne 'preserve-me' -or $fixture.Roles.Count -ne 2) { throw 'Automatic access setup or settings preservation failed.' }
  if ($fixture.Writes[0]['LabConsole__Operations__Enabled'] -ne 'false' -or $fixture.Writes[-1]['LabConsole__Operations__Enabled'] -ne 'True') { throw 'Operations enablement is not gated on setup completion.' }
  Reset-Configuration
  $fixture.ExistingTags = $false
  & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters | Out-Null
  $fixture.ExistingTags = $true
  Reset-Configuration
  $fixture.NoCpuPair = $true
  & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters | Out-Null
  $fixture.NoCpuPair = $false
  Reset-Configuration
  $fixture.MissingLogs = $true
  & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters | Out-Null
  if ($fixture.LogsDeployments -ne 1 -or $fixture.MissingLogs) { throw 'Existing labs did not automatically acquire missing custom-log prerequisites.' }
  Reset-Configuration
  $fixture.WithAi = $true
  & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters | Out-Null
  if ($fixture.AiCalls -ne 1 -or $fixture.Settings['LabConsole__Foundry__Enabled'] -ne 'True') { throw 'Optional Foundry setup was not automatic.' }
  foreach ($failure in @('FailAuth', 'FailBuild', 'BadTenant', 'FailAi', 'DeletePreview', 'FailTagRead', 'FailCpuInventory', 'CpuScopeEscape')) {
    Reset-Configuration
    $fixture[$failure] = $true
    $before = $fixture.Writes.Count
    $beforeDeployments = $fixture.Deployments
    $caught = $false
    try { & (Join-Path $scriptDirectory 'initialize-webapp-console.ps1') @parameters | Out-Null } catch { $caught = $true }
    if (-not $caught) { throw "Deployment failure was hidden: $failure" }
    if ($failure -eq 'BadTenant') { if ($fixture.Writes.Count -ne $before) { throw 'Tenant mismatch caused writes.' } }
    elseif ($fixture.Settings['LabConsole__Operations__Enabled'] -ne 'false') { throw 'Setup failure left operations enabled.' }
    if ($failure -eq 'DeletePreview' -and $fixture.Deployments -ne $beforeDeployments) { throw 'A destructive preview did not block deployment.' }
    if ($failure -eq 'FailTagRead' -and $fixture.Deployments -ne $beforeDeployments) { throw 'Failed tag discovery must stop before redeploying runner resources.' }
    if ($failure -in @('FailCpuInventory', 'CpuScopeEscape') -and $fixture.Deployments -ne $beforeDeployments) { throw 'Invalid CPU discovery must stop before guest execution access is granted.' }
    $fixture[$failure] = $false
  }
  Write-Output 'PASS: automatic sign-in, isolated cloud build, digest pinning, scoped access, ordered enablement, and fail-closed deployment. No live Azure calls.'
} finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }