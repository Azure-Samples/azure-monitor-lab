$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('completion-flow-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
Copy-Item -LiteralPath (Join-Path $source 'post-cloud-shell-deploy.ps1') -Destination $directory
$fixture = @{
  Subscription = '11111111-1111-1111-1111-111111111111'; Tenant = '22222222-2222-2222-2222-222222222222'
  Calls = [Collections.Generic.List[string]]::new(); Failure = ''; SliError = ''; FabricParameters = $null
  AiResources = $true
}
$helpers = @(
  'setup-activity-log', 'post-deploy', 'setup-ai-cloud-shell', 'setup-health-model', 'setup-slis',
  'setup-fabric', 'setup-sre-agent', 'setup-observability-agent', 'cleanup-legacy-rbac', 'setup-health-model-demo'
)
foreach ($helper in $helpers) {
  Set-Content -LiteralPath (Join-Path $directory "$helper.ps1") -Value @'
param($SubscriptionId, $TenantId, $ResourceGroup, $NamePrefix, $WorkspaceName,
  $WebAppName, $AksName, $WebAppHost, $CustomerWebAppName, $CustomerDependencyDeploymentName,
  $ApproveCustomerDependencies, $CentralLawName, $AppInsightsConnectionString, $ConsoleOperatorObjectIds,
  [switch] $ObservabilityAgent, [switch] $SkipTraffic)
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$fixture.Calls.Add($name)
if ($name -eq 'setup-ai-cloud-shell' -and (
    $SubscriptionId -ne $fixture.Subscription -or $ResourceGroup -ne 'test-rg' -or
    $NamePrefix -ne 'custom' -or $PSBoundParameters.ContainsKey('SkipTraffic'))) {
  throw 'Automatic AI traffic must preserve the verified target and prefix without skipping traffic.'
}
if ($fixture.Failure -eq $name) { throw "$name failed." }
if ($name -eq 'setup-slis' -and $fixture.SliError) { throw $fixture.SliError }
if ($name -eq 'setup-fabric') { $fixture.FabricParameters = $PSBoundParameters }
'@
}
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'login --tenant' { }
    'account set' { }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'resource list' {
      $resources = @(
        @{ type = 'Microsoft.Web/sites'; name = 'app-custom-test' },
        @{ type = 'Microsoft.ContainerService/managedClusters'; name = 'aks-custom' },
        @{ type = 'Microsoft.OperationalInsights/workspaces'; name = 'law-custom-central-test' },
        @{ type = 'Microsoft.Insights/components'; name = 'appi-custom-test'; id = 'app-insights-id' },
        @{ type = 'Microsoft.Fabric/capacities'; name = 'fabtest' },
        @{ type = 'Microsoft.App/agents'; name = 'sretest' },
        @{ type = 'Microsoft.Monitor/observabilityAgents'; name = 'obstest' },
        @{ type = 'Microsoft.CloudHealth/healthmodels'; name = 'hm-lab-cafe' }
      )
      if ($fixture.AiResources) {
        $resources += @{ type = 'Microsoft.CognitiveServices/accounts/projects'; name = 'aicustomtest/custom-ai-proj' }
      }
      return ConvertTo-Json -InputObject $resources
    }
    'resource show' { return 'offline-app-insights-connection' }
    default { throw "Unexpected Azure call: $args" }
  }
}
function Invoke-Completion {
  param([hashtable] $Options = @{}, [string] $ExpectedFailure = '')
  $fixture.Calls.Clear(); $fixture.FabricParameters = $null
  $messages = [Collections.Generic.List[string]]::new()
  $failure = ''
  try {
    & (Join-Path $directory 'post-cloud-shell-deploy.ps1') -TenantId $fixture.Tenant `
      -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -NamePrefix custom @Options *>&1 |
      ForEach-Object { $messages.Add([string]$_) }
  } catch { $failure = $_.Exception.Message }
  if ($failure -ne $ExpectedFailure) { throw "Expected '$ExpectedFailure', got '$failure'." }
  return $messages -join "`n"
}
try {
  $messages = Invoke-Completion
  if (($fixture.Calls -join ',') -ne ($helpers -join ',')) { throw 'All discovered completion stages must run in order after workloads.' }
  if ($fixture.FabricParameters.ContainsKey('WorkspaceName')) { throw 'Omitted workspace override must leave configuration resolution to Fabric setup.' }
  if ($messages -notlike '*source metrics verified: True*' -or $messages -notlike '*Manual SLI step still required*') {
    throw 'Successful automated verification must still expose manual preview SLI steps.'
  }
  foreach ($selection in @(
    @{ Resources = $false; Options = @{}; Enabled = $false },
    @{ Resources = $true; Options = @{}; Enabled = $true },
    @{ Resources = $true; Options = @{ EnableStageAI = $false }; Enabled = $false },
    @{ Resources = $false; Options = @{ EnableStageAI = $true }; Enabled = $true }
  )) {
    $fixture.AiResources = $selection.Resources
    $null = Invoke-Completion -Options $selection.Options
    $expectedCalls = @($helpers | Where-Object { $_ -ne 'setup-ai-cloud-shell' -or $selection.Enabled })
    if (($fixture.Calls -join ',') -ne ($expectedCalls -join ',')) {
      throw 'Cloud Shell must start AI traffic only when deployed or explicitly enabled, respecting an explicit opt-out.'
    }
  }
  $fixture.AiResources = $true
  $null = Invoke-Completion -Options @{ FabricWorkspaceName = 'unique-lab' }
  if ($fixture.FabricParameters.WorkspaceName -ne 'unique-lab') { throw 'Cloud Shell must hand off the explicit workspace override.' }
  foreach ($helper in @('post-deploy', 'setup-ai-cloud-shell', 'setup-health-model', 'setup-fabric')) {
    $fixture.Failure = $helper
    $messages = Invoke-Completion -ExpectedFailure "$helper failed."
    $expectedCalls = $helpers[0..([Array]::IndexOf($helpers, $helper))]
    if (($fixture.Calls -join ',') -ne ($expectedCalls -join ',') -or $messages -like '*setup completed*') {
      throw "Failure in $helper must stop later stages and cannot report completion."
    }
  }
  $fixture.Failure = ''
  $fixture.SliError = "Cloud Shell's built-in credential cannot request the Azure Monitor Prometheus token audience. Test restriction."
  $messages = Invoke-Completion
  if (($fixture.Calls -join ',') -ne ($helpers -join ',') -or $messages -notlike '*source metrics verified: False*' -or
      $messages -notlike '*verification is still outstanding*') {
    throw 'Only the known Cloud Shell audience restriction may continue, with an explicit unverified result.'
  }
  $fixture.SliError = 'AuthorizationFailed for Prometheus.'
  $null = Invoke-Completion -ExpectedFailure $fixture.SliError
  if ($fixture.Calls[-1] -ne 'setup-slis') { throw 'Other SLI errors must stop before Fabric and later stages.' }

  $deploy = Get-Content -LiteralPath (Join-Path $source 'deploy.ps1') -Raw
  $post = Get-Content -LiteralPath (Join-Path $source 'post-deploy.ps1') -Raw
  $workloadCall = $deploy.IndexOf('& $postDeploy @postDeployParameters')
  $healthCall = $deploy.IndexOf('& $setupHm -ResourceGroup $ResourceGroup')
  $sliCall = $deploy.IndexOf('& $setupSli -SubscriptionId $active.id')
  if ($workloadCall -lt 0 -or $healthCall -le $workloadCall -or $sliCall -le $healthCall -or
      $post -notmatch 'complete-customer-dependencies.ps1') {
    throw 'Local deployment must continue to complete workloads/customer dependencies before service-group and SLI setup.'
  }
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'deploy.ps1'), [ref]$null, [ref]$errors)
  $fabricTry = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
      $node.Body.Extent.Text.Contains('& $setupFabric ')
  }, $true)
  if ($errors.Count -or $fabricTry.Count -ne 1 -or
      $fabricTry[0].CatchClauses[0].Body.Statements[-1] -isnot [Management.Automation.Language.ThrowStatementAst]) {
    throw 'Local Fabric failures must be rethrown, not followed by a successful completion message.'
  }
  Write-Output 'PASS: Cloud Shell invokes all discovered stages in order, honors workspace handoff and fails closed at failed helpers. No cloud calls.'
  Write-Output 'PASS: Cloud Shell starts discovered AI traffic after workload publication, preserves the target/prefix, honors explicit selection and surfaces startup failures.'
  Write-Output 'PASS: only the known Prometheus audience limitation continues with explicit outstanding verification; local workload/service-group order and Fabric failure propagation are preserved.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
