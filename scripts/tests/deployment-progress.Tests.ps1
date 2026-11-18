$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
. (Join-Path $PSScriptRoot '..\deployment-slot-recovery.ps1')
$fixture = @{}
function Reset-Fixture {
  $fixture.Clear()
  $fixture.Code = 0
  $fixture.Mode = ''
  $fixture.Polls = 0
  $fixture.Stopped = 0
  $fixture.Removed = 0
  $fixture.Progress = [Collections.Generic.List[string]]::new()
  $fixture.Output = [Collections.Generic.List[string]]::new()
}
function Write-Host { param($Object, $ForegroundColor) $fixture.Output.Add("$ForegroundColor|$Object") }
function Write-Progress {
  param($Id, $Activity, $Status, $CurrentOperation, [switch]$Completed)
  if ($Id -ne 73) { throw 'Progress must use its own stable ID.' }
  $fixture.Progress.Add($(if ($Completed) { 'completed' } else { $Status }))
}
function Start-Sleep {
  param($Milliseconds)
  if ($Milliseconds -ne 200) { throw 'Spinner refresh interval changed.' }
}
function Start-Job {
  param($ScriptBlock, $ArgumentList)
  if ($ArgumentList[0] -isnot [array] -or ($ArgumentList[0] -join ' ') -ne 'version --only-show-errors' -or
      $ArgumentList[1] -ne $PWD.Path) { throw 'Runner must preserve native argument boundaries and working directory.' }
  $fixture.Job = [pscustomobject]@{ State = 'Running'; HasMoreData = $true }
  return $fixture.Job
}
function Receive-Job {
  param($Job, $ErrorAction)
  $fixture.Polls++
  if ($fixture.Mode -eq 'worker-error') { throw 'Worker failed.' }
  if ($fixture.Polls -eq 1) { return [pscustomobject]@{ Kind = 'Diagnostic'; Text = 'Azure diagnostic remains visible.' } }
  if ($fixture.Polls -eq 3) {
    $Job.State = 'Completed'
    $Job.HasMoreData = $false
    if ($fixture.Mode -ne 'missing-exit') { return [pscustomobject]@{ Kind = 'Exit'; Code = $fixture.Code } }
  }
}
function Stop-Job { param($Job) $fixture.Stopped++; $Job.State = 'Stopped' }
function Remove-Job { param($Job) $fixture.Removed++ }
try {
  foreach ($code in @(0, 1)) {
    Reset-Fixture
    $fixture.Code = $code
    Invoke-LabDeploymentCommand -Arguments @('version', '--only-show-errors') -DeploymentName 'test-deployment'
    if ($global:LASTEXITCODE -ne $code -or $fixture.Removed -ne 1 -or $fixture.Stopped -ne 0 -or
        $fixture.Progress[-1] -ne 'completed' -or $fixture.Progress[0] -eq $fixture.Progress[1]) {
      throw 'Runner must animate progress, preserve exit codes, clear display and remove completed jobs.'
    }
    $expected = if ($code -eq 0) { 'Green|  [OK]' } else { 'Red|  [FAIL]' }
    if (-not $fixture.Output[-1].StartsWith($expected) -or
        $fixture.Output -notcontains '|Azure diagnostic remains visible.') { throw 'Completion status or diagnostics were hidden.' }
  }
  foreach ($mode in @('worker-error', 'missing-exit')) {
    Reset-Fixture
    $fixture.Mode = $mode
    $caught = $false
    try { Invoke-LabDeploymentCommand -Arguments @('version', '--only-show-errors') -DeploymentName 'test-deployment' }
    catch { $caught = $true }
    if (-not $caught -or $global:LASTEXITCODE -eq 0 -or $fixture.Removed -ne 1 -or
        $fixture.Progress[-1] -ne 'completed' -or ($mode -eq 'worker-error' -and $fixture.Stopped -ne 1)) {
      throw 'Unknown outcomes must fail explicitly and clean up the progress display and runner.'
    }
  }
  Write-Output 'PASS: animated deployment progress, success/failure summaries, diagnostic/exit-code preservation and job cleanup. No Azure calls.'
} finally { $global:LASTEXITCODE = $previousExitCode }
