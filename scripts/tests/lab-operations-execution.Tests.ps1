$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('lab-runner-test-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
$scriptDirectory = Join-Path $repo 'scripts'
$null = New-Item -ItemType Directory -Path $scriptDirectory -Force
$source = Split-Path $PSScriptRoot -Parent
foreach ($name in @('invoke-lab-operation.ps1', 'start-the-lab.ps1', 'stop-the-lab.ps1', 'break-the-lab.ps1', 'restore-the-lab.ps1', 'start-ramp.ps1', 'simulate-high-cpu.ps1', 'send-custom-logs.ps1', 'send-release-annotation.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination $scriptDirectory
}
@'
param([string] $BaseUrl, [int] $Users, [int] $Concurrency, [int] $RepeatUsers)
@{ BaseUrl = $BaseUrl; Users = $Users; Concurrency = $Concurrency; RepeatUsers = $RepeatUsers } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'usage-parameters.json')
'@ | Set-Content -LiteralPath (Join-Path $scriptDirectory 'generate-usage-traffic.ps1')
$workloads = Join-Path $repo 'workloads/k8s'
$null = New-Item -ItemType Directory -Path $workloads -Force
foreach ($name in @('02-loadgen.yaml', '03-loadgen-ramp.yaml')) { Copy-Item -LiteralPath (Join-Path $source "../workloads/k8s/$name") -Destination $workloads }
$fixture = @{
  Subscription = [guid]::NewGuid().ToString(); Tenant = [guid]::NewGuid().ToString(); Revision = ('a' * 40)
  Calls = [Collections.Generic.List[object]]::new(); Http = [Collections.Generic.List[object]]::new(); Credentials = 0; Conversions = 0
  BadTenant = $false; DenyKubernetes = $false; FailVmStart = $false; FailKubernetes = $false; ObservedTarget = $false
  FailLogin = $false; VmssStopped = $false; AllResourcesStopped = $false; FailVmInventory = $false
  WebAppFailures = 0; CustomerFailures = 0; Sleeps = [Collections.Generic.List[int]]::new()
  CpuMode = $false; CpuMissingWindows = $false; CpuExtraVm = $false; CpuStoppedWindows = $false; CpuAgentUnavailable = $false
  CpuWrongScope = $false; CpuSecondSubmissionFails = $false; CpuCommands = [Collections.Generic.List[object]]::new()
}
$envValues = @{
  LAB_RUNNER_MODE = 'ContainerAppsJob'; IDENTITY_ENDPOINT = 'http://localhost/identity'; IDENTITY_HEADER = 'test-header'; AZURE_CLIENT_ID = [guid]::NewGuid().ToString()
  LAB_SUBSCRIPTION_ID = $fixture.Subscription; LAB_TENANT_ID = $fixture.Tenant; LAB_RESOURCE_GROUP = 'test-rg'
  RUNNER_TEMP = $root; AZURE_CORE_OUTPUT = 'none'; KUBECONFIG = $env:KUBECONFIG; TEMP = $env:TEMP; TMP = $env:TMP; PATH = $env:PATH
}
$previous = @{}
foreach ($name in $envValues.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envValues[$name]) }
$parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; RequestId = ('b' * 32) }

function git { $global:LASTEXITCODE = 0; return $fixture.Revision }
function Get-Command {
  [CmdletBinding()]
  param([string] $Name, [string] $CommandType)
  $tool = Split-Path $Name -Leaf
  $mock = switch ($tool) { az { 'Invoke-FakeAzure' }; kubectl { 'Invoke-FakeKubectl' }; kubelogin { 'Invoke-FakeKubelogin' }; default { throw 'Unexpected executable lookup.' } }
  if ($tool -eq 'az') { return @([pscustomobject]@{ Source = $mock }, [pscustomobject]@{ Source = 'Invoke-DuplicateAzure' }) }
  return [pscustomobject]@{ Source = $mock }
}
function Invoke-FakeAzure {
  $global:LASTEXITCODE = 0
  $fixture.Calls.Add(@{ Tool = 'az'; Arguments = @($args) })
  if ($args[0] -eq 'login') {
    if ($args -notcontains '--identity') { throw 'Runner login must use managed identity.' }
    if ($fixture.FailLogin) { $global:LASTEXITCODE = 9; return 'private diagnostic output' }
    return
  }
  if (-not ($args[0] -eq 'account' -and $args[1] -eq 'show')) {
    $index = [Array]::IndexOf($args, '--subscription')
    if ($index -lt 0 -or $args[$index + 1] -ne $fixture.Subscription) { throw 'Missing pinned subscription.' }
  }
  $command = $args[0..1] -join ' '
  switch ($command) {
    'account set' { return }
    'account show' {
      if ($args -contains 'id') { return $fixture.Subscription }
      return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid().ToString() } else { $fixture.Tenant }) } | ConvertTo-Json
    }
    'account get-access-token' {
      if ($args -contains 'accessToken') { return 'fake-session-token' }
      return '{"accessToken":"fake-session-token"}'
    }
    'group exists' { return 'true' }
    'vm list' {
      if ($fixture.FailVmInventory) { $global:LASTEXITCODE = 3; return 'private diagnostic output' }
      if ($fixture.CpuMode) {
        $cpuVms = @(
          @{ name = 'vm-test-lin'; id = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/vm-test-lin"; tags = @{ purpose = 'azure-monitor-lab' }; storageProfile = @{ osDisk = @{ osType = 'Linux' } } }
          @{ name = 'vmwintest'; id = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/vmwintest"; tags = @{ purpose = 'azure-monitor-lab' }; storageProfile = @{ osDisk = @{ osType = 'Windows' } } }
          @{ name = 'unrelated-vm'; tags = @{ purpose = 'other' }; storageProfile = @{ osDisk = @{ osType = 'Linux' } } }
        )
        if ($fixture.CpuMissingWindows) { $cpuVms = @($cpuVms | Where-Object name -ne 'vmwintest') }
        if ($fixture.CpuExtraVm) { $cpuVms += $cpuVms[0] }
        if ($fixture.CpuWrongScope) { $cpuVms[1].id = '/subscriptions/other/resourceGroups/other/providers/Microsoft.Compute/virtualMachines/vmwintest' }
        return ConvertTo-Json -InputObject $cpuVms -Depth 6
      }
      if ($args -contains '[].name') { return 'test-vm' }
      if ($fixture.AllResourcesStopped) { return '[{"name":"test-vm","power":"VM deallocated"}]' }
      return '[{"name":"test-vm","power":"VM running"}]'
    }
    'vm start' {
      if ($fixture.FailVmStart) { $global:LASTEXITCODE = 7; return 'private diagnostic output' }
      return
    }
    'vm deallocate' { return }
    'vm get-instance-view' {
      if ($fixture.CpuMode) {
        $power = if ($fixture.CpuStoppedWindows -and $args -contains 'vmwintest') { 'PowerState/deallocated' } else { 'PowerState/running' }
        $agent = if ($fixture.CpuAgentUnavailable) { 'ProvisioningState/failed' } else { 'ProvisioningState/succeeded' }
        return @{ statuses = @(@{ code = $power }); vmAgent = @{ statuses = @(@{ code = $agent }) } } | ConvertTo-Json -Depth 5
      }
      return 'VM running'
    }
    'vm run-command' {
      if (-not $fixture.CpuMode -or $args[2] -ne 'invoke' -or $args -notcontains '--no-wait') { throw 'Unexpected VM guest command.' }
      $scriptPath = $args[[Array]::IndexOf($args, '--scripts') + 1]
      if (-not $scriptPath.StartsWith('@')) { throw 'Guest command must use a fixed script file.' }
      $fixture.CpuCommands.Add(@{ Name = $args[[Array]::IndexOf($args, '--name') + 1]; CommandId = $args[[Array]::IndexOf($args, '--command-id') + 1]; Script = Get-Content -LiteralPath $scriptPath.Substring(1) -Raw; Path = $scriptPath.Substring(1) })
      if ($fixture.CpuSecondSubmissionFails -and $args -contains 'vmwintest') { $global:LASTEXITCODE = 7; return 'private diagnostic output' }
      return
    }
    'vmss list' { return 'test-vmss' }
    'vmss list-instances' {
      if ($args -contains '-d') { $global:LASTEXITCODE = 2; return 'private diagnostic: unrecognized VMSS argument' }
      if ($args -notcontains '--expand' -or $args -notcontains 'instanceView' -or ($args -join ' ') -notmatch 'instanceView.statuses') { throw 'VMSS power state must come from expanded instance view.' }
      if (($args -join ' ') -match 'length') { return '0' }
      if ($fixture.VmssStopped -or $fixture.AllResourcesStopped) { return '[{"power":"PowerState/deallocated"}]' }
      return '[{"power":"PowerState/running"}]'
    }
    'vmss start' {
      if ($args -notcontains '--no-wait') { throw 'VMSS start must be asynchronous.' }
      $fixture.VmssStopped = $false
      return
    }
    'vmss deallocate' { return }
    'aks list' {
      if ($args -contains '[0].name') { return 'test-aks' }
      if ($fixture.AllResourcesStopped) { return '[{"name":"test-aks","power":"Stopped"}]' }
      return '[{"name":"test-aks","power":"Running","powerState":{"code":"Running"},"currentKubernetesVersion":"1.33.5"}]'
    }
    'aks install-cli' { return }
    'aks stop' { return }
    'aks get-credentials' {
      if ($args -notcontains '--file' -or $args -notcontains '--context') { throw 'AKS credentials are not isolated.' }
      $fixture.Credentials++
      return
    }
    'webapp list' {
      if ($fixture.WebAppFailures -gt 0) { $fixture.WebAppFailures--; $global:LASTEXITCODE = 4; return 'private diagnostic output' }
      if (($args -join ' ') -match 'defaultHostName' -and $args -contains 'tsv') { return 'app-test.azurewebsites.net' }
      if (($args -join ' ') -match '\[0\]\.name') { return 'app-test' }
      if ($fixture.AllResourcesStopped) { return '[{"name":"app-test","state":"Stopped"}]' }
      return '[{"name":"app-test","state":"Running","defaultHostName":"app-test.azurewebsites.net"}]'
    }
    'webapp show' { return 'app-test.azurewebsites.net' }
    'webapp stop' { return }
    'resource list' {
      if ($args -contains 'Microsoft.Insights/components') {
        if ($args -contains '[0].name') { return 'appi-test' }
        return '[{"name":"appi-test"}]'
      }
      if ($args -contains 'Microsoft.Insights/dataCollectionRules') { return '[{"name":"dcr-customlogs"}]' }
      if ($args -contains 'Microsoft.Insights/dataCollectionEndpoints') { return '[{"name":"dce-customlogs"}]' }
      throw 'Unexpected resource type.'
    }
    'resource show' {
      if ($args -notcontains 'properties' -or $args -notcontains '2023-03-11') { throw 'Custom-log discovery must use core ARM properties.' }
      if ($args -contains 'Microsoft.Insights/dataCollectionEndpoints') { return '{"logsIngestion":{"endpoint":"https://test.ingest.monitor.azure.com"}}' }
      return '{"immutableId":"dcr-test"}'
    }
    default { throw "Unexpected command: $command" }
  }
}
function Invoke-FakeKubelogin {
  $global:LASTEXITCODE = 0
  if ($args -notcontains 'azurecli' -or $args -notcontains $env:KUBECONFIG) { throw 'Noninteractive AKS login missing.' }
  $fixture.Conversions++
}
function Invoke-FakeKubectl {
  $global:LASTEXITCODE = 0
  $fixture.Calls.Add(@{ Tool = 'kubectl'; Arguments = @($args) })
  if ($fixture.Credentials -ne $fixture.Conversions) { throw 'A renewed kubeconfig was not converted for noninteractive login.' }
  if ($args -notcontains '--context' -or $args -notcontains '--kubeconfig' -or $args -notcontains $env:KUBECONFIG) { throw 'Kubernetes scope not isolated.' }
  if ($args[0] -eq 'auth') { return $(if ($fixture.DenyKubernetes) { 'no' } else { 'yes' }) }
  if ($fixture.FailKubernetes -and $args -contains 'set') { $global:LASTEXITCODE = 8; return 'private Kubernetes diagnostic' }
  return 'ok'
}
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $Body)
  if (-not $Uri.StartsWith("https://management.azure.com/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/")) { throw 'Annotation target escaped the lab.' }
  $fixture.Http.Add(@{ Method = $Method; Uri = $Uri; Body = $Body | ConvertFrom-Json })
  return @{}
}
function Invoke-WebRequest {
  param($Method, $Uri, $Headers, $Body, $MaximumRedirection, $TimeoutSec, [switch] $SkipHttpErrorCheck)
  if ($Method -eq 'Get' -and $Uri -eq 'https://app-test.azurewebsites.net/customer/') {
    if ($fixture.CustomerFailures -gt 0) { $fixture.CustomerFailures--; return @{ StatusCode = 503 } }
    $fixture.Http.Add(@{ Method = $Method; Uri = $Uri })
    return @{ StatusCode = 200 }
  }
  if (-not $Uri.StartsWith('https://test.ingest.monitor.azure.com/')) { throw 'Unexpected ingestion endpoint.' }
  $fixture.Http.Add(@{ Method = $Method; Uri = $Uri; Body = $Body | ConvertFrom-Json })
  return @{ StatusCode = 204 }
}
function Start-Sleep {
  param([int] $Seconds)
  $fixture.Sleeps.Add($Seconds)
}

try {
  $fixture.AllResourcesStopped = $true
  $accessOutput = & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation start -CheckAccessOnly | Out-String
  $allowedReads = @('login --identity', 'account set', 'account show', 'group exists', 'vm list', 'vmss list', 'vmss list-instances', 'aks list', 'webapp list')
  if ($accessOutput -notmatch 'Runner prerequisites verified' -or $fixture.Http.Count -ne 0 -or
      @($fixture.Calls | Where-Object { $_.Tool -ne 'az' -or ($_.Arguments[0..1] -join ' ') -notin $allowedReads }).Count) {
    throw 'Read-only preflight executed a workload operation.'
  }
  foreach ($expectedRead in @('vm list', 'vmss list-instances', 'aks list', 'webapp list')) {
    if (-not @($fixture.Calls | Where-Object { ($_.Arguments[0..1] -join ' ') -eq $expectedRead }).Count) { throw 'Access-only mode missed part of Start Lab resource discovery.' }
  }
  $stopReadStart = $fixture.Calls.Count
  $stopAccessOutput = & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation stop -CheckAccessOnly | Out-String
  if ($stopAccessOutput -notmatch 'Runner prerequisites verified' -or
      @($fixture.Calls | Select-Object -Skip $stopReadStart | Where-Object { $_.Tool -ne 'az' -or ($_.Arguments[0..1] -join ' ') -notin $allowedReads }).Count) {
    throw 'Stop Lab access-only mode executed a write operation.'
  }
  $fixture.AllResourcesStopped = $false
  $fixture.FailVmInventory = $true
  $discoveryRejected = $false
  try { & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation start -CheckAccessOnly | Out-Null }
  catch {
    $discoveryRejected = $true
    if ($_.Exception.Message -notmatch "start resource discovery.*Azure command 'vm list'" -or $_.Exception.Message -match 'private diagnostic|fake-session-token') { throw 'Discovery failure lost its safe command name or leaked protected output.' }
  }
  if (-not $discoveryRejected) { throw 'Access-only mode ignored an inventory failure.' }
  $fixture.FailVmInventory = $false
  $fixture.CpuMode = $true
  $cpuReadStart = $fixture.Calls.Count
  & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation cpu -CheckAccessOnly | Out-Null
  if ($fixture.CpuCommands.Count -ne 0 -or @($fixture.Calls | Select-Object -Skip $cpuReadStart | Where-Object { ($_.Arguments[0..1] -join ' ') -notin @('login --identity', 'account set', 'account show', 'group exists', 'vm list', 'vm get-instance-view') }).Count) { throw 'CPU access-only mode was not read-only and independent of AKS.' }
  foreach ($failure in @('CpuMissingWindows', 'CpuExtraVm', 'CpuStoppedWindows', 'CpuAgentUnavailable', 'CpuWrongScope', 'FailVmInventory', 'BadTenant')) {
    $fixture[$failure] = $true
    $rejected = $false
    try { & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation cpu | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.CpuCommands.Count -ne 0) { throw "CPU simulation submitted load despite $failure." }
    $fixture[$failure] = $false
  }
  $cpuOutput = & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation cpu | Out-String
  if ($fixture.CpuCommands.Count -ne 2 -or $cpuOutput -notmatch "Approved action 'cpu' completed") { throw 'Both VM commands were not submitted.' }
  $linuxCpu = $fixture.CpuCommands[0]
  $windowsCpu = $fixture.CpuCommands[1]
  if ($linuxCpu.Name -ne 'vm-test-lin' -or $linuxCpu.CommandId -ne 'RunShellScript' -or $linuxCpu.Script -notmatch 'timeout --signal=TERM --kill-after=5s 600s' -or $linuxCpu.Script -notmatch 'flock -n 9' -or $linuxCpu.Script -notmatch 'trap cleanup EXIT' -or $linuxCpu.Script -notmatch '_NPROCESSORS_ONLN') { throw 'Linux CPU lifetime, scope, lock, or worker contract is missing.' }
  if ($windowsCpu.Name -ne 'vmwintest' -or $windowsCpu.CommandId -ne 'RunPowerShellScript' -or $windowsCpu.Script -notmatch 'clock.Elapsed.TotalSeconds < 600' -or $windowsCpu.Script -notmatch 'guard.WaitOne\(0\)' -or $windowsCpu.Script -notmatch 'worker.IsBackground = true' -or $windowsCpu.Script -notmatch 'Environment.ProcessorCount') { throw 'Windows CPU lifetime, scope, lock, or worker contract is missing.' }
  $parseErrors = $null
  $null = [Management.Automation.Language.Parser]::ParseInput($windowsCpu.Script, [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'Windows guest script is not valid PowerShell.' }
  if (@($fixture.CpuCommands | Where-Object { Test-Path -LiteralPath $_.Path }).Count) { throw 'Guest script files were not cleaned up.' }
  $fixture.CpuCommands.Clear()
  $fixture.CpuSecondSubmissionFails = $true
  $rejected = $false
  try { & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation cpu | Out-Null } catch { $rejected = $true }
  if (-not $rejected -or $fixture.CpuCommands.Count -ne 2) { throw 'A partial CPU submission was ignored or retried.' }
  if (@($fixture.CpuCommands | Where-Object { Test-Path -LiteralPath $_.Path }).Count) { throw 'Failed guest submission leaked temporary files.' }
  $fixture.CpuSecondSubmissionFails = $false
  $fixture.CpuMode = $false
  $fixture.WebAppFailures = 1
  $fixture.CustomerFailures = 1
  $retryStart = $fixture.Calls.Count
  $retryOutput = & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation usage -Count 1 -Concurrency 1 -CheckAccessOnly 6>&1 | Out-String
  if ($retryOutput -notmatch '"phase":"customer web app discovery","state":"retrying"' -or
      $retryOutput -notmatch '"phase":"customer endpoint readiness","state":"retrying"' -or
      @($fixture.Calls | Select-Object -Skip $retryStart | Where-Object { ($_.Arguments[0..1] -join ' ') -eq 'webapp list' }).Count -ne 2 -or
      @($fixture.Http | Where-Object { $_.Method -eq 'Get' }).Count -ne 1 -or
      ($fixture.Sleeps -join ',') -notmatch '2,2') {
    throw 'Customer preflight did not retry transient read-only failures with safe phase diagnostics.'
  }
  foreach ($operation in @('start', 'stop', 'break', 'restore', 'ramp', 'usage', 'logs', 'annotation')) {
    $arguments = $parameters.Clone()
    $arguments.Operation = $operation
    if ($operation -eq 'logs') { $arguments.Count = 12 }
    if ($operation -eq 'usage') { $arguments.Count = 24; $arguments.Concurrency = 4; $arguments.RepeatUsers = 6 }
    if ($operation -eq 'annotation') { $arguments.Name = 'Release 1.2'; $arguments.Category = 'Incident' }
    try { $output = & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @arguments 6>&1 | Out-String }
    catch { throw "Offline $operation failed: $(($Error | Select-Object -First 4 | ForEach-Object { $_.Exception.Message }) -join ' / ')" }
    if ($output -notmatch "Approved action '$operation' completed") { throw "The $operation script was not completed." }
    if ($output -match 'fake-session-token|private diagnostic') { throw 'Raw command output leaked.' }
    if (Test-Path (Join-Path $repo '.azure-target.json')) { throw 'Runner target file was not cleaned up.' }
  }
  if ($fixture.Credentials -ne $fixture.Conversions -or $fixture.Credentials -lt 4) { throw 'Repeated AKS credentials were not isolated and converted.' }
  if (@($fixture.Http | Where-Object { $_.Method -eq 'POST' })[0].Body.Count -ne 12) { throw 'Custom log count was not passed to the existing script.' }
  $usageParameters = Get-Content -LiteralPath (Join-Path $root 'usage-parameters.json') -Raw | ConvertFrom-Json
  if ($usageParameters.BaseUrl -ne 'https://app-test.azurewebsites.net' -or $usageParameters.Users -ne 24 -or $usageParameters.Concurrency -ne 4 -or $usageParameters.RepeatUsers -ne 6) {
    throw 'Customer traffic parameters were not passed to the bounded browser generator.'
  }
  if ($fixture.Http[-1].Body.AnnotationName -ne 'Release 1.2') { throw 'Marker parameters were not passed to the existing script.' }
  if (@($fixture.Calls | Where-Object { $_.Tool -eq 'az' -and ($_.Arguments[0..1] -join ' ') -eq 'vmss start' }).Count) { throw 'An already-running VMSS was started.' }
  $fixture.VmssStopped = $true
  & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation start | Out-Null
  if (@($fixture.Calls | Where-Object { $_.Tool -eq 'az' -and ($_.Arguments[0..1] -join ' ') -eq 'vmss start' }).Count -ne 1 -or
      -not @($fixture.Calls | Where-Object { $_.Tool -eq 'az' -and ($_.Arguments[0..1] -join ' ') -eq 'vmss list-instances' -and ($_.Arguments -join ' ') -match 'length' }).Count) {
    throw 'A stopped VMSS was not started and verified through expanded instance view.'
  }
  foreach ($failure in @('BadTenant', 'DenyKubernetes', 'FailVmStart', 'FailKubernetes', 'FailLogin')) {
    $fixture[$failure] = $true
    if ($failure -eq 'FailVmStart') { $fixture.AllResourcesStopped = $true }
    $operation = if ($failure -in @('DenyKubernetes', 'FailKubernetes')) { 'break' } else { 'start' }
    $rejected = $false
    try { & (Join-Path $scriptDirectory 'invoke-lab-operation.ps1') @parameters -Operation $operation | Out-Null }
    catch {
      $rejected = $true
      $expectedPhase = switch ($failure) { BadTenant { 'account verification' }; DenyKubernetes { 'Kubernetes preflight' }; FailLogin { 'managed identity login' }; default { 'approved script execution' } }
      if ($_.Exception.Message -notmatch [regex]::Escape($expectedPhase) -or $_.Exception.Message -match 'private diagnostic|fake-session-token') { throw 'Runner failure phase was lost or leaked protected output.' }
      if ($failure -eq 'FailVmStart' -and $_.Exception.Message -notmatch "Azure command 'vm start'") { throw 'The failed native command was not identified.' }
    }
    if (-not $rejected) { throw "Runner did not stop for $failure." }
    $fixture[$failure] = $false
    $fixture.AllResourcesStopped = $false
  }
  foreach ($expectedStop in @('vm deallocate', 'vmss deallocate', 'aks stop', 'webapp stop')) {
    if (-not @($fixture.Calls | Where-Object { $_.Tool -eq 'az' -and ($_.Arguments[0..1] -join ' ') -eq $expectedStop }).Count) {
      throw "Stop Lab did not issue '$expectedStop'."
    }
  }
  Write-Output 'PASS: all nine scripts execute only through fake scoped commands; Stop Lab cost controls, bounded customer traffic, read-only preflight retries, safe phase diagnostics, bounded dual-VM CPU submission, preflight failures, repeated AKS login, parameters, and cleanup verified. No Azure calls, browser traffic, or CPU load executed.'
} finally {
  foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}