[CmdletBinding()]
param(
  [ValidateSet('start', 'stop', 'break', 'restore', 'ramp', 'usage', 'cpu', 'logs', 'annotation')] [string] $Operation = $env:OP_OPERATION,
  [ValidatePattern('^[a-f0-9]{32}$')] [string] $RequestId = $env:OP_REQUEST_ID,
  [guid] $SubscriptionId = $env:LAB_SUBSCRIPTION_ID,
  [guid] $TenantId = $env:LAB_TENANT_ID,
  [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup = $env:LAB_RESOURCE_GROUP,
  [ValidateRange(0, 100)] [int] $Count = [int]($env:OP_COUNT ?? '0'),
  [ValidateRange(0, 10)] [int] $Concurrency = [int]($env:OP_CONCURRENCY ?? '0'),
  [ValidateRange(0, 100)] [int] $RepeatUsers = [int]($env:OP_REPEAT_USERS ?? '0'),
  [AllowEmptyString()] [string] $Name = $env:OP_ANNOTATION_NAME ?? '',
  [AllowEmptyString()] [string] $Category = $env:OP_ANNOTATION_CATEGORY ?? '',
  [switch] $ValidateOnly,
  [switch] $CheckAccessOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty -or $ResourceGroup.EndsWith('.')) { throw 'Invalid target identifiers.' }
if (-not $Operation -or -not $RequestId -or $env:LAB_RUNNER_MODE -ne 'ContainerAppsJob') { throw 'An approved Container Apps Job request is required.' }
if ($SubscriptionId.ToString() -cne $env:LAB_SUBSCRIPTION_ID -or $TenantId.ToString() -cne $env:LAB_TENANT_ID -or $ResourceGroup -cne $env:LAB_RESOURCE_GROUP) { throw 'The requested target does not match the deployed runner environment.' }
if ($Operation -eq 'logs') {
  if ($Count -lt 1 -or $Concurrency -ne 0 -or $RepeatUsers -ne 0) { throw 'Custom logs requires 1-100 events and no browser parameters.' }
} elseif ($Operation -eq 'usage') {
  if ($Count -lt 1 -or $Concurrency -lt 1 -or $RepeatUsers -gt $Count) { throw 'Customer traffic requires 1-100 users, concurrency 1-10, and repeat users no greater than users.' }
} elseif ($Count -ne 0 -or $Concurrency -ne 0 -or $RepeatUsers -ne 0) { throw 'Count and browser parameters are not allowed for this operation.' }
if ($Operation -eq 'annotation') {
  if ($Name -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9 ._()-]{0,79}$' -or $Category -cnotin @('Deployment', 'Incident')) { throw 'Invalid release marker parameters.' }
} elseif ($Name -or $Category) { throw 'Marker parameters are only allowed for annotations.' }
$scripts = @{
  start = 'start-the-lab.ps1'; stop = 'stop-the-lab.ps1'; break = 'break-the-lab.ps1'; restore = 'restore-the-lab.ps1'
  ramp = 'start-ramp.ps1'; logs = 'send-custom-logs.ps1'; annotation = 'send-release-annotation.ps1'
  usage = 'generate-usage-traffic.ps1'
  cpu = 'simulate-high-cpu.ps1'
}
if ($ValidateOnly) { Write-Output 'Approved operation parameters validated. No Azure command executed.'; return }

$repository = Split-Path $PSScriptRoot -Parent
$azureExecutable = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$kubernetesExecutable = $null
$kubeloginExecutable = $null
$context = "lab-operations-$RequestId"
$targetFile = Join-Path $repository '.azure-target.json'
if (Test-Path $targetFile) { throw 'The runner checkout must not contain an existing Azure target file.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) $context
$null = New-Item -ItemType Directory -Path $temporary -Force
$env:KUBECONFIG = Join-Path $temporary 'kubeconfig'
$env:TEMP = $temporary
$env:TMP = $temporary
$commandFailure = @{ Name = $null }
$runnerPhase = 'initialization'

function Write-RunnerPhase {
  param(
    [Parameter(Mandatory)] [string] $Phase,
    [Parameter(Mandatory)] [ValidateSet('started', 'retrying', 'succeeded', 'failed')] [string] $State,
    [int] $Attempt = 1
  )
  Write-Information ([ordered]@{ event = 'lab-operation-phase'; requestId = $RequestId; phase = $Phase; state = $State; attempt = $Attempt } | ConvertTo-Json -Compress) -InformationAction Continue
}

function Invoke-ReadOnlyPreflight {
  param(
    [Parameter(Mandatory)] [string] $Phase,
    [Parameter(Mandatory)] [scriptblock] $Action,
    [ValidateRange(1, 3)] [int] $Attempts = 3
  )
  $script:runnerPhase = $Phase
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    Write-RunnerPhase -Phase $Phase -State started -Attempt $attempt
    try {
      $result = & $Action
      Write-RunnerPhase -Phase $Phase -State succeeded -Attempt $attempt
      return $result
    } catch {
      if ($attempt -eq $Attempts) {
        Write-RunnerPhase -Phase $Phase -State failed -Attempt $attempt
        throw
      }
      Write-RunnerPhase -Phase $Phase -State retrying -Attempt $attempt
      Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
    }
  }
}

function az {
  $arguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in $args) { $arguments.Add([string]$argument) }
  $subscriptionIndex = $arguments.IndexOf('--subscription')
  if ($subscriptionIndex -ge 0 -and $arguments[$subscriptionIndex + 1] -ne $SubscriptionId.ToString()) { throw 'Script attempted to change Azure subscription.' }
  foreach ($flag in @('-g', '--resource-group')) {
    $index = $arguments.IndexOf($flag)
    if ($index -ge 0 -and $arguments[$index + 1] -cne $ResourceGroup) { throw 'Script attempted to change resource group.' }
  }
  if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'set' -and $subscriptionIndex -lt 0) { throw 'Account changes require the expected subscription.' }
  if ($subscriptionIndex -lt 0 -and -not ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show')) { $arguments.Add('--subscription'); $arguments.Add($SubscriptionId.ToString()) }
  if ($arguments[0] -eq 'aks' -and $arguments[1] -eq 'get-credentials') {
    $arguments.Add('--file'); $arguments.Add($env:KUBECONFIG)
    $arguments.Add('--context'); $arguments.Add($context)
  }
  if (-not $arguments.Contains('--only-show-errors')) { $arguments.Add('--only-show-errors') }
  $commandFailure.Name = $null
  try {
    $output = & $azureExecutable @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Native command failed.' }
    if ($arguments[0] -eq 'aks' -and $arguments[1] -eq 'get-credentials') {
      if (-not $kubeloginExecutable) { throw 'Kubernetes authentication tooling is unavailable.' }
      $null = & $kubeloginExecutable convert-kubeconfig --login azurecli --kubeconfig $env:KUBECONFIG 2>&1
      if ($LASTEXITCODE -ne 0) { throw 'Kubernetes authentication configuration failed.' }
    }
    $output
  } catch {
    $commandFailure.Name = "$($arguments[0]) $($arguments[1])"
    throw "Azure command '$($commandFailure.Name)' failed. Diagnostic output is suppressed."
  }
}

function kubectl {
  if (-not $kubernetesExecutable) { throw 'No verified Kubernetes context is available.' }
  if ($args -contains '--context' -or $args -contains '--kubeconfig' -or $args -contains '-A' -or $args -contains '--all-namespaces') { throw 'Kubernetes context override is not allowed.' }
  try {
    $output = & $kubernetesExecutable @args --context $context --kubeconfig $env:KUBECONFIG --request-timeout=30s 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Native command failed.' }
    $output
  } catch { throw 'A Kubernetes operation failed. Diagnostic output is suppressed.' }
}

try {
  $runnerPhase = 'managed identity validation'
  Write-RunnerPhase -Phase $runnerPhase -State started
  if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER -or -not $env:AZURE_CLIENT_ID) { throw 'The deployed runner managed identity is unavailable.' }
  Write-RunnerPhase -Phase $runnerPhase -State succeeded
  $null = Invoke-ReadOnlyPreflight -Phase 'managed identity login' -Action {
    $null = & $azureExecutable login --identity --client-id $env:AZURE_CLIENT_ID --output none --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Managed identity login failed.' }
  }
  $account = Invoke-ReadOnlyPreflight -Phase 'account verification' -Action {
    az account set --subscription $SubscriptionId | Out-Null
    az account show --query '{id:id,tenantId:tenantId}' --output json | ConvertFrom-Json
  }
  if ($account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) { throw 'Azure account does not match the approved target.' }
  $resourceGroupExists = Invoke-ReadOnlyPreflight -Phase 'resource group verification' -Action {
    az group exists --name $ResourceGroup --output tsv
  }
  if ($resourceGroupExists -ne 'true') { throw 'The approved resource group does not exist.' }
  @{ expectedSubscriptionId = $SubscriptionId.ToString(); expectedTenantId = $TenantId.ToString() } | ConvertTo-Json | Set-Content -LiteralPath $targetFile

  if ($Operation -in @('break', 'restore', 'ramp')) {
    $runnerPhase = 'Kubernetes preflight'
    $clusters = @(az aks list --resource-group $ResourceGroup --output json | ConvertFrom-Json)
    if ($clusters.Count -ne 1 -or $clusters[0].powerState.code -ne 'Running') { throw 'Exactly one running lab AKS cluster is required.' }
    $apps = @(az webapp list --resource-group $ResourceGroup --output json | ConvertFrom-Json | Where-Object { $_.name -like 'app-*' })
    if ($apps.Count -ne 1) { throw 'Exactly one app-prefixed lab web app is required.' }
    $version = $clusters[0].currentKubernetesVersion
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'AKS did not report a supported Kubernetes client version.' }
    $kubectlPath = Join-Path $temporary 'kubectl'
    $kubelogin = Join-Path $temporary 'kubelogin'
    az aks install-cli --client-version $version --kubelogin-version 'v0.2.19' --install-location $kubectlPath --kubelogin-install-location $kubelogin --output none | Out-Null
    $kubernetesExecutable = (Get-Command $kubectlPath -CommandType Application -ErrorAction Stop).Source
    $kubeloginExecutable = (Get-Command $kubelogin -CommandType Application -ErrorAction Stop).Source
    $env:PATH = $temporary + [IO.Path]::PathSeparator + $env:PATH
    az aks get-credentials --resource-group $ResourceGroup --name $clusters[0].name --overwrite-existing --output none | Out-Null
    kubectl get namespace demo --output name | Out-Null
    foreach ($permission in @(@('get', 'deployments'), @('patch', 'deployments'), @('get', 'configmaps'), @('create', 'configmaps'), @('patch', 'configmaps'), @('get', 'cronjobs'), @('create', 'jobs'), @('patch', 'jobs'))) {
      if ((kubectl auth can-i $permission[0] $permission[1] --namespace demo) -ne 'yes') { throw 'The runner lacks a required demo-namespace permission.' }
    }
    if ($Operation -eq 'ramp') {
      foreach ($kind in @('jobs', 'configmaps')) { if ((kubectl auth can-i delete $kind --namespace demo) -ne 'yes') { throw 'Ramp replacement permission is missing.' } }
    }
    if ($Operation -eq 'restore') {
      foreach ($verb in @('create', 'patch')) { if ((kubectl auth can-i $verb cronjobs --namespace demo) -ne 'yes') { throw 'Load-generator restore permission is missing.' } }
    }
  }
  if ($Operation -in @('annotation', 'break', 'restore')) {
    $runnerPhase = 'annotation preflight'
    $components = @(az resource list --resource-group $ResourceGroup --resource-type Microsoft.Insights/components --output json | ConvertFrom-Json)
    if ($components.Count -ne 1) { throw 'Exactly one Application Insights component is required.' }
  }
  if ($Operation -eq 'logs') {
    $runnerPhase = 'custom-log preflight'
    foreach ($resourceType in @('Microsoft.Insights/dataCollectionRules', 'Microsoft.Insights/dataCollectionEndpoints')) {
      $resources = @(az resource list --resource-group $ResourceGroup --resource-type $resourceType --output json | ConvertFrom-Json | Where-Object { $_.name -like '*customlogs*' })
      if ($resources.Count -ne 1) { throw 'Exactly one custom-logs DCR and endpoint are required.' }
    }
  }
  if ($Operation -eq 'usage') {
    $apps = @(Invoke-ReadOnlyPreflight -Phase 'customer web app discovery' -Action {
      @(az webapp list --resource-group $ResourceGroup --output json | ConvertFrom-Json | Where-Object { $_.name -like 'app-*' })
    })
    if ($apps.Count -ne 1 -or [string]::IsNullOrWhiteSpace($apps[0].defaultHostName)) { throw 'Exactly one app-prefixed lab web app with a default host is required.' }
    $customerUrl = "https://$($apps[0].defaultHostName)/customer/"
    $null = Invoke-ReadOnlyPreflight -Phase 'customer endpoint readiness' -Action {
      $readiness = Invoke-WebRequest -Uri $customerUrl -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 20
      if ([int]$readiness.StatusCode -ne 200) { throw 'The customer journey endpoint is not ready.' }
      $readiness
    }
  }
  if ($CheckAccessOnly) {
    if ($Operation -in @('start', 'stop', 'cpu')) {
      $runnerPhase = "$Operation resource discovery"
      $null = & (Join-Path $PSScriptRoot $scripts[$Operation]) -ResourceGroup $ResourceGroup -WhatIf *>&1
    }
    Write-Output 'Runner prerequisites verified. No lab operation executed.'
    return
  }
  $parameters = if ($Operation -eq 'usage') { @{} } else { @{ ResourceGroup = $ResourceGroup } }
  switch ($Operation) {
    'start' { $parameters.Wait = $true; $parameters.TimeoutMinutes = 20 }
    'ramp' { $parameters.WebAppName = $apps[0].name }
    'usage' {
      $parameters.BaseUrl = "https://$($apps[0].defaultHostName)"
      $parameters.Users = $Count
      $parameters.Concurrency = $Concurrency
      $parameters.RepeatUsers = $RepeatUsers
    }
    'logs' { $parameters.Count = $Count }
    'annotation' { $parameters.Name = $Name; $parameters.Category = $Category }
  }
  $runnerPhase = 'approved script execution'
  Write-RunnerPhase -Phase $runnerPhase -State started
  Write-Output "Approved action '$Operation' is starting."
  $null = & (Join-Path $PSScriptRoot $scripts[$Operation]) @parameters *>&1
  Write-Output "Approved action '$Operation' completed. Azure state and telemetry can take time to settle."
  Write-RunnerPhase -Phase $runnerPhase -State succeeded
} catch {
  Write-RunnerPhase -Phase $runnerPhase -State failed
  $commandDetail = if ($commandFailure.Name) { " Azure command '$($commandFailure.Name)' failed." } else { '' }
  throw "The approved operation failed during $runnerPhase.$commandDetail No automatic rollback or retry was performed. Check the affected lab resources before another operation."
}
finally {
  if (Test-Path $targetFile) { Remove-Item -LiteralPath $targetFile -Force }
  if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}