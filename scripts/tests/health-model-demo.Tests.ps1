$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) "health-model-demo-$([guid]::NewGuid())"
$scripts = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $scripts
Copy-Item -LiteralPath (Join-Path $repo 'scripts\setup-health-model-demo.ps1') -Destination $scripts
@'
param($SubscriptionId, $ResourceGroup, $WebAppName)
if ($SubscriptionId -ne $fixture.Subscription -or $ResourceGroup -ne 'rg-demo' -or $WebAppName -ne 'app-cafe-abcdefghijklm') {
  throw 'Publication lost the scoped Cafe target.'
}
$fixture.Published++
'@ | Set-Content -LiteralPath (Join-Path $scripts 'publish-healthmodel-cafe.ps1')
$fixture = @{
  Subscription = [guid]::NewGuid().ToString()
  Tenant = [guid]::NewGuid().ToString()
  Published = 0
  Settings = @()
  NoTelemetry = $false
  FailQuery = $false
  Posts = 0
}
$inventory = @(
  @{ type = 'Microsoft.Web/sites'; name = 'app-cafe-abcdefghijklm' },
  @{ type = 'Microsoft.Web/sites'; name = 'app-demo-suffix' },
  @{ type = 'Microsoft.Web/sites'; name = 'app-demo-suffix-customer' },
  @{ type = 'Microsoft.OperationalInsights/workspaces'; name = 'law-cafe-suffix'; id = '/workspace' },
  @{ type = 'Microsoft.CloudHealth/healthmodels'; name = 'hm-lab-cafe' },
  @{ type = 'Microsoft.CloudHealth/healthmodels'; name = 'hm-amlab-flows' }
)
function az {
  $global:LASTEXITCODE = 0
  $key = $args[0..1] -join ' '
  switch ($key) {
    'account show' { @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'account get-access-token' { '{"accessToken":"fixture-token"}' }
    'resource list' { ConvertTo-Json -InputObject $inventory }
    'resource show' {
      if ($args -contains 'properties.provisioningState') { return 'Succeeded' }
      'workspace-guid'
    }
    'webapp config' { $fixture.Settings = $args }
    default { throw "Unexpected command: $args" }
  }
}
function Invoke-RestMethod {
  param($Uri, $Method, $Body, $ContentType, $Headers, $TimeoutSec)
  switch -Regex ($Uri) {
    '/api/menu$' {
      ,@([pscustomobject]@{ id = 'edited-menu-item' }, [pscustomobject]@{ id = 'second-item' })
      break
    }
    '/api/orders$' {
      if (($Body | ConvertFrom-Json).item -ne 'edited-menu-item') { throw 'Completion must respect the deployed menu.' }
      $fixture.Posts++
      [pscustomobject]@{ id = 'verified-order' }
      break
    }
    '/api/orders/verified-order$' { [pscustomobject]@{ id = 'verified-order' }; break }
    '/v1/workspaces/workspace-guid/query$' {
      if ($fixture.FailQuery) { throw 'Forbidden telemetry query' }
      $rows = if ($fixture.NoTelemetry) { @() } else { @(@('AppRequests', 2), @('AppDependencies', 3)) }
      if (($Body | ConvertFrom-Json).query -notmatch 'TimeGenerated >= datetime\(') {
        throw 'Verification must require new telemetry, not records from a previous deployment.'
      }
      [pscustomobject]@{ tables = @([pscustomobject]@{
        columns = @(@{ name = 'Source' }, @{ name = 'Records' }); rows = $rows
      }) }
      break
    }
    default { throw "Unexpected request: $Uri" }
  }
}
function Start-Sleep { param($Seconds) [Threading.Thread]::Sleep(1100) }
function Invoke-Completion {
  & (Join-Path $scripts 'setup-health-model-demo.ps1') `
    -SubscriptionId $fixture.Subscription -ResourceGroup rg-demo -NamePrefix demo -VerificationTimeoutSeconds 1
}
function Assert-Fails([string] $Pattern) {
  $rejected = $false
  try { Invoke-Completion } catch {
    if ($_.Exception.Message -notmatch $Pattern) { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw "Expected failure: $Pattern" }
}
try {
  Invoke-Completion
  Invoke-Completion
  if ($fixture.Published -ne 2 -or $fixture.Posts -ne 2 -or
      'LabConsole__HealthModels__1__ResourceGroup=rg-demo' -notin $fixture.Settings -or
      'LabConsole__HealthModels__0__DefaultEntity=shop-demo' -notin $fixture.Settings) {
    throw 'Completion/rerun did not connect both models and verify real stored orders.'
  }
  $saved = $inventory
  $inventory = @($inventory | Where-Object name -ne 'hm-amlab-flows')
  Assert-Fails 'Required model'
  if ($fixture.Published -ne 2) { throw 'Missing models must fail before publication.' }
  $inventory = $saved
  $fixture.FailQuery = $true
  Assert-Fails 'Forbidden telemetry query'
  $fixture.FailQuery = $false
  $fixture.NoTelemetry = $true
  Assert-Fails 'telemetry did not arrive'
  @{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = [guid]::NewGuid().ToString() } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')
  $before = $fixture.Published
  Assert-Fails 'BLOCKED'
  if ($fixture.Published -ne $before) { throw 'Wrong tenant must fail before mutation.' }
  $publicationRoot = Join-Path $root 'publication'
  $publicationScripts = Join-Path $publicationRoot 'scripts'
  $cafeFiles = Join-Path $publicationRoot 'workloads\cafe'
  $null = New-Item -ItemType Directory -Path $publicationScripts, $cafeFiles
  Copy-Item -LiteralPath (Join-Path $repo 'scripts\publish-healthmodel-cafe.ps1') -Destination $publicationScripts
  foreach ($name in @('server.js', 'package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $repo "workloads\cafe\$name") -Destination $cafeFiles
  }
  Set-Content -LiteralPath (Join-Path $cafeFiles 'not-for-publication.txt') -Value 'fixture'
  $publication = @{ Calls = 0; Sleeps = 0; Failures = 1; Error = 'SCM container restart'; Zip = '' }
  function Start-Sleep {
    param($Seconds)
    if ($Seconds -ne 60) { throw 'Unexpected publication retry delay.' }
    $publication.Sleeps++
  }
  function az {
    if (($args[0..4] -join ' ') -ne 'webapp deployment source config-zip --subscription' -or
        $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription) {
      throw 'Publication lost the scoped ZipDeploy command.'
    }
    $publication.Calls++
    $publication.Zip = $args[[Array]::IndexOf($args, '--src') + 1]
    $archive = [IO.Compression.ZipFile]::OpenRead($publication.Zip)
    try {
      if (($archive.Entries.Name | Sort-Object) -join ',' -cne 'package-lock.json,package.json,server.js') {
        throw 'Publication ZIP must contain only the locked Cafe source.'
      }
    } finally { $archive.Dispose() }
    if ($publication.Failures -gt 0) {
      $publication.Failures--
      $global:LASTEXITCODE = 1
      return $publication.Error
    }
    $global:LASTEXITCODE = 0
  }
  $publisher = Join-Path $publicationScripts 'publish-healthmodel-cafe.ps1'
  & $publisher -SubscriptionId $fixture.Subscription -ResourceGroup rg-demo -WebAppName app-cafe-suffix
  if ($publication.Calls -ne 2 -or $publication.Sleeps -ne 1 -or (Test-Path $publication.Zip)) {
    throw 'Recognized SCM restart must retry once and clean up its ZIP.'
  }
  $publication.Calls = 0
  $publication.Sleeps = 0
  $publication.Failures = 1
  $publication.Error = 'Unauthorized deployment'
  $rejected = $false
  try { & $publisher -SubscriptionId $fixture.Subscription -ResourceGroup rg-demo -WebAppName app-cafe-suffix }
  catch { $rejected = $_.Exception.Message -match 'Unauthorized deployment' }
  if (-not $rejected -or $publication.Calls -ne 1 -or $publication.Sleeps -ne 0 -or (Test-Path $publication.Zip)) {
    throw 'Unrecognized publication failures must not retry or leave a ZIP behind.'
  }
  $optimizationScript = Join-Path $publicationScripts 'trigger-code-optimization.ps1'
  Copy-Item -LiteralPath (Join-Path $repo 'scripts\trigger-code-optimization.ps1') -Destination $optimizationScript
  $apps = @(
    @{ name = 'app-cafe-abcdefghijklm' }
    @{ name = 'app-demo-suffix-customer' }
    @{ name = 'app-demo-suffix' }
  )
  function az {
    $global:LASTEXITCODE = 0
    if (($args[0..1] -join ' ') -eq 'webapp list') { return ConvertTo-Json -InputObject $apps }
    if (($args[0..1] -join ' ') -eq 'webapp show') {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne 'app-demo-suffix') {
        throw 'Optimization targeted a non-console app.'
      }
      throw 'Verified console target; stop before publication or load.'
    }
    throw "Unexpected optimization command: $args"
  }
  $rejected = $false
  try { & $optimizationScript -ResourceGroup rg-demo -SkipPublish -DurationMinutes 0 }
  catch { $rejected = $_.Exception.Message -match 'Verified console target' }
  if (-not $rejected) { throw 'Code optimization failed to isolate the console from Cafe/customer apps.' }
  $apps += @{ name = 'app-unrelated' }
  $rejected = $false
  try { & $optimizationScript -ResourceGroup rg-demo -SkipPublish -DurationMinutes 0 }
  catch { $rejected = $_.Exception.Message -match 'Exactly one Control Center' }
  if (-not $rejected) { throw 'Code optimization must reject ambiguous apps before publishing or generating load.' }
  Write-Host 'PASS: scoped completion, safe reruns, edited menus, required resources, telemetry failures, and target guards.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
}
