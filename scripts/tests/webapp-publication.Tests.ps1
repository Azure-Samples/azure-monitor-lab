$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$expected = [guid]::NewGuid().ToString('N')
$fixture = @{ Responses = [Collections.Generic.Queue[object]]::new(); Calls = 0; Sleeps = 0 }
function Invoke-WebRequest {
  param($Uri, $Headers, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec)
  if ($Uri -ne "https://app-test.azurewebsites.net/api/console/version?expected=$expected" -or $MaximumRedirection -ne 0 -or $Headers['Cache-Control'] -ne 'no-cache') { throw 'Publication checks must be scoped, uncached and must not follow redirects.' }
  $fixture.Calls++
  $response = $fixture.Responses.Dequeue()
  if ($response -is [Exception]) { throw $response }
  return $response
}
function Start-Sleep { param($Seconds); $fixture.Sleeps++ }
function Response($version) { @{ StatusCode = 200; Content = (@{ deploymentId = $version } | ConvertTo-Json -Compress) } }

$fixture.Responses.Enqueue((Response 'old-version'))
$fixture.Responses.Enqueue((Response $expected))
& (Join-Path $source 'scripts/wait-webapp-publication.ps1') -WebAppHost app-test.azurewebsites.net -DeploymentId $expected -MaxAttempts 3
if ($fixture.Calls -ne 2 -or $fixture.Sleeps -ne 1) { throw 'An old running version was incorrectly accepted as the new deployment.' }
foreach ($invalidResponse in @((Response 'old-version'), (Response ('a' * 32)), @{ StatusCode = 200; Content = '<html>old app</html>' }, @{ StatusCode = 401; Content = '{}' }, [InvalidOperationException]::new('Simulated connection timeout'))) {
  $fixture.Responses.Clear()
  $fixture.Calls = 0
  $fixture.Sleeps = 0
  $fixture.Responses.Enqueue($invalidResponse)
  $fixture.Responses.Enqueue($invalidResponse)
  $rejected = $false
  try { & (Join-Path $source 'scripts/wait-webapp-publication.ps1') -WebAppHost app-test.azurewebsites.net -DeploymentId $expected -MaxAttempts 2 }
  catch {
    $message = $_.Exception.Message
    $rejected = $message -like '*expected application version was not verified*'
    if ($message -notlike "*Expected deployment: $expected*" -or $message -notlike '*Host: app-test.azurewebsites.net*' -or $message -notlike '*Last observation:*') {
      throw 'Publication timeouts must identify the target, expected version, and last observation.'
    }
    if ($invalidResponse -is [Exception] -and $message -notlike '*Simulated connection timeout*') {
      throw 'Publication timeouts must surface request failures.'
    }
    if ($invalidResponse -isnot [Exception] -and $invalidResponse.Content -like '*aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*' -and $message -notlike '*reported deployment: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*') {
      throw 'Publication timeouts must identify a stale running deployment.'
    }
  }
  if (-not $rejected -or $fixture.Calls -ne 2 -or $fixture.Sleeps -ne 1) { throw 'Unverified application publication must stop within its bounded checks.' }
}
Write-Output 'PASS: only the expected running application version is accepted; stale/invalid/unauthorized responses stop within bounded read-only checks.'
