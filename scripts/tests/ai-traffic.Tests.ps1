$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('ai-traffic-test-' + [guid]::NewGuid().ToString('N'))
$scriptDirectory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $scriptDirectory -Force
foreach ($name in @('setup-ai.ps1', 'setup-ai-cloud-shell.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source "scripts/$name") -Destination $scriptDirectory
}
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid()
  Events = [Collections.Generic.List[string]]::new(); Fail = ''; State = 'running'
  Conversations = 150; Endpoint = 'https://example.services.ai.azure.com/api/projects/test'; InvalidAccount = ''
}
$environmentNames = @('AZURE_AI_PROJECT_ENDPOINT', 'AZURE_CHAT_DEPLOYMENT', 'AZURE_ROUTER_DEPLOYMENT', 'APPLICATIONINSIGHTS_CONNECTION_STRING')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

function Get-Command {
  param($Name, $ErrorAction)
  if ($Name -notin @('python', 'python3')) { throw 'Unexpected executable lookup.' }
  [pscustomobject]@{ Source = 'Invoke-TestPython' }
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong AI setup subscription.' }
    }
    'account show' {
      $subscription = if ($fixture.InvalidAccount -eq 'subscription') { [guid]::NewGuid() } else { $fixture.Subscription }
      $tenant = if ($fixture.InvalidAccount -eq 'tenant') { '' } else { $fixture.Tenant }
      if ($args -contains 'id') { return $subscription.ToString() }
      return @{ id = $subscription; tenantId = $tenant } | ConvertTo-Json
    }
    'resource list' {
      if ($args -contains 'Microsoft.CognitiveServices/accounts') {
        return ConvertTo-Json -InputObject @(@{ name = 'aiamlabtest'; kind = 'AIServices' })
      }
      if ($args -contains 'Microsoft.Insights/components') { return '{"id":"test-component","name":"appi-amlab-test1"}' }
      throw 'Unexpected resource discovery.'
    }
    'resource show' { return 'test-telemetry' }
    default { throw 'Unexpected Azure request.' }
  }
}

function Invoke-TestPython {
  $global:LASTEXITCODE = 0
  $step = if ($args[0] -eq '-m') { 'dependencies' } else { [IO.Path]::GetFileNameWithoutExtension($args[0]) }
  $fixture.Events.Add($step)
  if ($fixture.Fail -eq $step) { $global:LASTEXITCODE = 1; return }
  if ($step -in @('background_traffic', 'simulate_traffic')) {
    if ($args -contains '--loop' -or $args[[Array]::IndexOf($args, '--conversations') + 1] -ne $fixture.Conversations) { throw 'Traffic must remain a finite batch with the requested conversation count.' }
    if ($env:AZURE_AI_PROJECT_ENDPOINT -ne $fixture.Endpoint -or $env:APPLICATIONINSIGHTS_CONNECTION_STRING -ne 'test-telemetry') { throw 'Traffic lost its configured environment.' }
  }
  if ($step -eq 'background_traffic') {
    return @{ processId = 4321; state = $fixture.State; logPath = 'test-traffic.log'; statusPath = 'test-status.json' } | ConvertTo-Json
  }
}

try {
  $parameters = @{
    SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; NamePrefix = 'amlab'
    ProjectEndpoint = 'https://example.services.ai.azure.com/api/projects/test'; AppInsightsConnectionString = 'test-telemetry'
  }
  foreach ($mode in @(@{}, @{ SkipTraffic = $true }, @{ BackgroundTraffic = $true }, @{ BackgroundTraffic = $false })) {
    $fixture.Events.Clear()
    & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters @mode | Out-Null
    $expected = if ($mode.SkipTraffic) { 'dependencies,create_agents' } else { 'dependencies,create_agents,background_traffic' }
    if (($fixture.Events -join ',') -ne $expected) { throw 'AI setup must always start traffic in the background unless SkipTraffic is supplied.' }
  }
  foreach ($failure in @('dependencies', 'create_agents', 'background_traffic')) {
    $fixture.Fail = $failure
    $fixture.Events.Clear()
    $rejected = $false
    try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -BackgroundTraffic | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.Events[$fixture.Events.Count - 1] -ne $failure) { throw 'Failed AI setup continued or reported a successful launch.' }
  }
  $fixture.Fail = ''
  $fixture.State = 'failed'
  $rejected = $false
  try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -BackgroundTraffic | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw 'A failed worker must not be reported as running.' }
  $fixture.Events.Clear()
  $rejected = $false
  try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -SkipTraffic -BackgroundTraffic | Out-Null } catch { $rejected = $true }
  if (-not $rejected -or $fixture.Events.Count) { throw 'Conflicting traffic modes must fail before setup.' }
  $fixture.State = 'running'
  $fixture.Endpoint = 'https://aiamlabtest.services.ai.azure.com/api/projects/amlab-ai-proj'
  @{ expectedSubscriptionId = [guid]::NewGuid(); expectedTenantId = [guid]::NewGuid() } | ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')
  foreach ($mode in @(@{}, @{ Conversations = 7 }, @{ SkipTraffic = $true }, @{ NamePrefix = '' })) {
    $fixture.Conversations = if ($mode.Conversations) { $mode.Conversations } else { 150 }
    $fixture.Events.Clear()
    & (Join-Path $scriptDirectory 'setup-ai-cloud-shell.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg @mode | Out-Null
    $expected = if ($mode.SkipTraffic) { 'dependencies,create_agents' } else { 'dependencies,create_agents,background_traffic' }
    if (($fixture.Events -join ',') -ne $expected) { throw 'Cloud Shell must preserve verified account context, background traffic, and SkipTraffic.' }
  }
  foreach ($invalidAccount in @('subscription', 'tenant')) {
    $fixture.InvalidAccount = $invalidAccount
    $fixture.Events.Clear()
    $rejected = $false
    try { & (Join-Path $scriptDirectory 'setup-ai-cloud-shell.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.Events.Count) { throw 'Cloud Shell must verify subscription and tenant before running Python.' }
  }
  Write-Output 'PASS: AI setup always launches finite background traffic unless skipped and reports startup failures. No Azure calls.'
  Write-Output 'PASS: Cloud Shell forwards verified account context despite a stale local target, preserves custom batch sizes, and rejects invalid accounts. No Azure calls.'
} finally {
  foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
  Remove-Item -LiteralPath $root -Recurse -Force
}