$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('sli-setup-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
foreach ($name in @('setup-slis.ps1', 'setup-health-model.ps1', 'remove-arm-resource.ps1', 'resolve-service-group-id.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source "scripts/$name") -Destination $directory
}
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Principal = [guid]::NewGuid()
  Mode = 'unsupported'; Queries = 0; TokenRequests = 0; Token = [guid]::NewGuid().ToString('N')
  Diagnostic = [guid]::NewGuid().ToString('N'); ExplicitSubscription = $false
  DeleteError = ''; Deletes = [Collections.Generic.List[string]]::new(); Teardown = $false
}

$sliResourceIds = @('sli-aks-pods-running', 'sli-aks-pod-start-latency') |
  ForEach-Object { "/providers/Microsoft.Management/serviceGroups/amlab-workload/providers/Microsoft.Monitor/slis/$_" }
$serviceGroupId = '/providers/Microsoft.Management/serviceGroups/amlab-workload'
$fixture.ServiceGroupResourceId = $serviceGroupId
$memberId = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg"
$deleteApis = @{}
foreach ($resourceId in $sliResourceIds) { $deleteApis[$resourceId] = '2025-03-01-preview' }
$deleteApis[$memberId] = '2023-09-01-preview'
$deleteApis[$serviceGroupId] = '2024-02-01-preview'
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong subscription selected.' }
    }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'group exists' { return 'true' }
    'resource list' { return ConvertTo-Json -InputObject @(@{ id = $memberId }) }
    'rest --method' {
      if ($args[2] -eq 'delete') {
        if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Cleanup deletion lost the verified subscription.' }
        $url = $args[[Array]::IndexOf($args, '--url') + 1]
        $uri = [uri]$url
        if ($uri.Host -ne 'management.azure.com' -or -not $deleteApis.ContainsKey($uri.AbsolutePath) -or $uri.Query -ne "?api-version=$($deleteApis[$uri.AbsolutePath])") {
          throw 'Unexpected cleanup deletion target.'
        }
        $fixture.Deletes.Add($uri.AbsolutePath)
        if ($fixture.DeleteError) {
          $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
          $errorText = $fixture.DeleteError.Replace("'", "''")
          & $shell -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$errorText'); exit 1"
          $global:LASTEXITCODE = $LASTEXITCODE
        }
        return
      }
      if ($args[2] -ne 'get') { throw 'Unexpected service group write.' }
      if ($args[[Array]::IndexOf($args, '--url') + 1] -ne "https://management.azure.com$($fixture.ServiceGroupResourceId)?api-version=2024-02-01-preview") {
        throw 'SLI verification must use the group selected by the RG membership.'
      }
      return '{"properties":{"provisioningState":"Succeeded"}}'
    }
    'identity show' { return @{ id = 'test-identity'; clientId = $fixture.Principal; principalId = $fixture.Principal } | ConvertTo-Json }
    'resource show' {
      if ($args -contains '--ids') {
        if ($args[[Array]::IndexOf($args, '--ids') + 1] -ne $memberId) { throw 'Unexpected membership lookup.' }
        return @{ properties = @{ targetId = $fixture.ServiceGroupResourceId } } | ConvertTo-Json
      }
      return @{
        id = 'test-amw'
        properties = @{
          defaultIngestionSettings = @{ dataCollectionRuleResourceId = 'test-dcr'; dataCollectionEndpointResourceId = 'test-dce' }
          metrics = @{ prometheusQueryEndpoint = 'https://example.com' }
        }
      } | ConvertTo-Json -Depth 4
    }
    'role assignment' {
      if ($args[2] -ne 'list') { throw 'Existing SLI roles must be reused.' }
      return ConvertTo-Json -InputObject @(
        @{ roleDefinitionId = '/roles/43d0d8ad-25c7-4714-9337-8ba259a9fe05' },
        @{ roleDefinitionId = '/roles/3913510d-42f4-4e42-8a64-420c390055eb' }
      )
    }
    'account get-access-token' {
      $fixture.TokenRequests++
      if ($args[[Array]::IndexOf($args, '--resource') + 1] -ne 'https://prometheus.monitor.azure.com') { throw 'The Prometheus token audience must not be changed.' }
      $fixture.ExplicitSubscription = $args -contains '--subscription' -and $args[[Array]::IndexOf($args, '--subscription') + 1] -eq $fixture.Subscription.ToString()
      if ($fixture.Mode -eq 'unsupported-native') {
        $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        & $shell -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('ERROR: Audience https://prometheus.monitor.azure.com is not a supported MSI token audience.'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
        return
      }
      if ($fixture.Mode -eq 'unsupported') {
        $global:LASTEXITCODE = 1
        Write-Error "Audience https://prometheus.monitor.azure.com is not a supported MSI token audience. $($fixture.Diagnostic)" -ErrorAction Continue
        return
      }
      if ($fixture.Mode -eq 'authentication') {
        $global:LASTEXITCODE = 1
        Write-Error "Authentication failed. $($fixture.Diagnostic)" -ErrorAction Continue
        return
      }
      if ($fixture.Mode -eq 'empty') { return '' }
      return $fixture.Token
    }
    default { throw 'Unexpected Azure request, including automatic login/logout.' }
  }
}

function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $TimeoutSec)
  $fixture.Queries++
  if ($Headers.Authorization -ne "Bearer $($fixture.Token)" -or $Method -ne 'Get' -or $Uri -notlike 'https://example.com/api/v1/query?query=*') { throw 'Invalid Prometheus query request.' }
  if ($fixture.Mode -eq 'query-error') { throw 'Prometheus query denied.' }
  $results = if ($fixture.Mode -eq 'missing') { @() } else { @(@{ value = @(0, '1') }) }
  return @{ data = @{ result = $results } }
}

function Start-Sleep {
  param($Seconds)
  if ($fixture.Teardown -and $Seconds -eq 10) { return }
  throw 'Zero-wait regression must not sleep.'
}

function Invoke-TestSliSetup {
  $fixture.Queries = 0
  $fixture.TokenRequests = 0
  $messages = [Collections.Generic.List[string]]::new()
  $failure = ''
  try {
    & (Join-Path $directory 'setup-slis.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -MetricWaitMinutes 0 *>&1 |
      ForEach-Object { $messages.Add([string]$_) }
  } catch { $failure = $_.Exception.Message }
  $text = $messages -join "`n"
  if ($text.Contains($fixture.Token) -or $text.Contains($fixture.Diagnostic) -or $failure.Contains($fixture.Token) -or $failure.Contains($fixture.Diagnostic)) {
    throw 'Token or raw credential diagnostics leaked into output.'
  }
  return @{ Text = $text; Failure = $failure }
}

try {
  $fixture.Teardown = $true
  foreach ($nativePreference in @($true, $false)) {
    foreach ($helper in @(
      @{ Name = 'setup-slis.ps1'; Arguments = @{ SubscriptionId = $fixture.Subscription }; Resources = $sliResourceIds },
      @{ Name = 'setup-health-model.ps1'; Arguments = @{}; Resources = @($memberId, $serviceGroupId) }
    )) {
      foreach ($deleteCase in @(
        @{ Error = 'ERROR: Not Found({"error":{"code":"ResourceNotFound","message":"The resource does not exist."}})'; Absent = $true; Fails = $false },
        @{ Error = ''; Absent = $false; Fails = $false },
        @{ Error = 'ERROR: (NotFound) The resource does not exist.'; Absent = $true; Fails = $false },
        @{ Error = 'ERROR: (ParentResourceNotFound) The parent does not exist.'; Absent = $true; Fails = $false },
        @{ Error = 'ERROR: (ResourceGroupNotFound) The resource group does not exist.'; Absent = $true; Fails = $false },
        @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"NotFound is not the error code.","details":[{"code":"ResourceNotFound"}]}})'; Absent = $false; Fails = $true },
        @{ Error = 'ERROR: (UnsupportedResourceType) This API is not supported.'; Absent = $false; Fails = $true },
        @{ Error = 'ERROR: (Conflict) Resource still has dependencies.'; Absent = $false; Fails = $true },
        @{ Error = 'ERROR: (InternalServerError) Cleanup is unavailable.'; Absent = $false; Fails = $true }
      )) {
        $fixture.DeleteError = $deleteCase.Error
        $fixture.Deletes.Clear()
        & {
          $PSNativeCommandUseErrorActionPreference = $nativePreference
          $failure = ''
          $messages = [Collections.Generic.List[string]]::new()
          $helperArguments = $helper.Arguments
          try {
            & (Join-Path $directory $helper.Name) @helperArguments -ResourceGroup test-rg -Teardown *>&1 |
              ForEach-Object { $messages.Add([string]$_) }
          } catch { $failure = $_.Exception.Message }
          if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'Cleanup changed the caller native-error preference.' }
          if ($deleteCase.Fails) {
            if (-not $failure.Contains($deleteCase.Error) -or -not $failure.Contains($helper.Resources[0]) -or $fixture.Deletes.Count -ne 1) {
              throw "$($helper.Name) must retain Azure diagnostics and stop cleanup on real deletion failures: $failure"
            }
          } elseif ($failure -or ($fixture.Deletes -join ',') -ne ($helper.Resources -join ',')) {
            throw "$($helper.Name) must accept successful deletes or already-missing resources in either native-error mode: $failure"
          }
          if ($deleteCase.Absent -and (($messages -join "`n") -match 'Delete submitted:')) { throw 'An already-absent resource must not be reported as a submitted deletion.' }
        }
      }
    }
  }
  $fixture.Teardown = $false
  Write-Output 'PASS: SLI and Service Group teardown handle native not-found errors idempotently and stop on real deletion failures without changing caller preferences. No Azure calls.'
  foreach ($nativePreference in @($false, $true)) {
    $PSNativeCommandUseErrorActionPreference = $nativePreference
    foreach ($mode in @('unsupported', 'unsupported-native')) {
      $fixture.Mode = $mode
      $result = Invoke-TestSliSetup
      if ($result.Failure -notlike '*Cloud Shell*' -or
          $result.Failure -notlike '*post-deployment wrapper handles this limitation automatically*' -or
          $result.Failure -notlike '*credential supports the Prometheus audience*' -or
          $result.Failure -match 'az login|az account clear' -or $fixture.Queries -or $fixture.TokenRequests -ne 1) {
        throw 'Unsupported Cloud Shell audience must stop standalone verification and direct wrapper users to the automatic fallback.'
      }
      if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'The helper changed its caller native-error preference.' }
    }
  }
  foreach ($mode in @('authentication', 'empty', 'query-error', 'missing')) {
    $fixture.Mode = $mode
    $result = Invoke-TestSliSetup
    if (-not $result.Failure -or $result.Text -match 'All four documented source metrics are currently flowing') { throw 'Unverified metrics must never be reported as ready.' }
    if ($mode -in @('authentication', 'empty') -and $fixture.Queries) { throw 'Token failure must stop before queries.' }
    if ($mode -eq 'authentication' -and $result.Failure -like '*supported MSI token audience*') { throw 'Unrelated authentication failures must not be classified as the Cloud Shell restriction.' }
  }
  $fixture.Mode = 'success'
  foreach ($groupName in @('amlab-workload', 'amlab-workload-123456abcdef', 'custom-lab-group')) {
    $serviceGroupId = "/providers/Microsoft.Management/serviceGroups/$groupName"
    $fixture.ServiceGroupResourceId = $serviceGroupId
    $result = Invoke-TestSliSetup
    if ($result.Failure -or $fixture.Queries -ne 4 -or -not $fixture.ExplicitSubscription -or
        $result.Text -notmatch 'All four documented source metrics are currently flowing' -or
        -not $result.Text.Contains("$serviceGroupId/serviceLevelIndicators")) { throw "Successful SLI verification must use the lab membership and query all four metrics: $($result.Failure)" }
  }
  Write-Output 'PASS: Cloud Shell audience errors direct wrapper users to the automatic fallback without leaking credentials; other failures stop; all four metrics remain required. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}