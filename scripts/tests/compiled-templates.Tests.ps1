[CmdletBinding()]
param([string] $BicepExecutable)

$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainTemplate = Get-Content -LiteralPath (Join-Path $source 'infra/main.json') -Raw | ConvertFrom-Json
if ($mainTemplate.variables.appInsightsName -ne "[format('appi-{0}-{1}', parameters('namePrefix'), take(variables('suffix'), 5))]") {
  throw 'Application Insights must use the generated five-character deployment suffix.'
}
$appInsightsObservability = @($mainTemplate.resources | Where-Object name -eq 'appinsights-observability')
if ($appInsightsObservability.Count -ne 1) { throw 'The main template must deploy the Application Insights investigation query pack and workbook.' }
$agentTaskAvailability = @($mainTemplate.resources | Where-Object name -eq 'agent-task-availability-test')
if ($agentTaskAvailability.Count -ne 1 -or $agentTaskAvailability[0].properties.parameters.testUrl.value -notmatch '/api/agent-task-availability') {
  throw 'The main template must deploy the task-level agent availability test.'
}
$alertsModule = @($mainTemplate.resources | Where-Object name -eq 'alerts')
$agentAlerts = @($alertsModule[0].properties.template.resources | Where-Object name -in @('alert-agent-task-failures', 'alert-agent-efficiency-regression'))
if ($alertsModule.Count -ne 1 -or $agentAlerts.Count -ne 2) { throw 'The main template must contain task correctness and efficiency alerts.' }
Write-Output 'PASS: suffixed Application Insights, investigation content, task availability, and agent alerts are compiled.'
$vmModules = @($mainTemplate.resources | Where-Object name -in @('vm-linux', 'vm-windows'))
if ($vmModules.Count -ne 2) { throw 'The main template must contain both demo VM modules.' }
foreach ($vmModule in $vmModules) {
  $shutdown = @($vmModule.properties.template.resources | Where-Object type -eq 'Microsoft.DevTestLab/schedules')
  if ($shutdown.Count -ne 1 -or $shutdown[0].properties.status -ne 'Enabled' -or $shutdown[0].properties.taskType -ne 'ComputeVmShutdownTask' -or
      $shutdown[0].properties.dailyRecurrence.time -ne '2300' -or $shutdown[0].properties.timeZoneId -ne 'Romance Standard Time' -or
      $shutdown[0].properties.notificationSettings.status -ne 'Disabled') {
    throw "The $($vmModule.name) module must automatically shut down its VM at 23:00 CET/CEST."
  }
}
Write-Output 'PASS: both demo VMs use DST-aware 23:00 automatic shutdown schedules.'
$alertProcessingModule = @($mainTemplate.resources | Where-Object name -eq 'alert-processing-rules')
$nightlyVmRule = @($alertProcessingModule[0].properties.template.resources | Where-Object {
  $_.type -eq 'Microsoft.AlertsManagement/actionRules' -and
  @($_.properties.conditions | Where-Object { $_.field -eq 'TargetResourceType' -and $_.values -contains 'Microsoft.Compute/virtualMachines' }).Count -eq 1
})
if ($alertProcessingModule.Count -ne 1 -or $nightlyVmRule.Count -ne 1) { throw 'The main template must contain one VM shutdown alert processing rule.' }
$nightlyVmProperties = $nightlyVmRule[0].properties
$vmTypeCondition = @($nightlyVmProperties.conditions | Where-Object { $_.field -eq 'TargetResourceType' -and $_.operator -eq 'Equals' -and $_.values -contains 'Microsoft.Compute/virtualMachines' })
$dailyWindow = @($nightlyVmProperties.schedule.recurrences | Where-Object { $_.recurrenceType -eq 'Daily' -and $_.startTime -eq '23:00:00' -and $_.endTime -eq '07:00:00' })
if ($nightlyVmProperties.schedule.timeZone -ne 'Romance Standard Time' -or $vmTypeCondition.Count -ne 1 -or $dailyWindow.Count -ne 1 -or
    @($nightlyVmProperties.actions | Where-Object actionType -eq 'RemoveAllActionGroups').Count -ne 1) {
  throw 'The nightly rule must suppress only VM alert actions from 23:00 through 07:00 CET/CEST.'
}
Write-Output 'PASS: VM alert actions are suppressed only during the DST-aware 23:00-07:00 shutdown window.'
$cpuAlerts = @($mainTemplate.resources | Where-Object name -eq 'alert-vm-cpu-dynamic')
if ($cpuAlerts.Count -ne 1 -or $cpuAlerts[0].type -ne 'Microsoft.Insights/metricAlerts') { throw 'The main template must contain exactly one dynamic VM CPU metric alert.' }
$cpuAlert = $cpuAlerts[0].properties
if ($cpuAlert.evaluationFrequency -ne 'PT5M' -or $cpuAlert.windowSize -ne 'PT15M') { throw 'The dynamic VM CPU alert must check every 5 minutes with a 15-minute lookback.' }
$cpuCriteria = @($cpuAlert.criteria.allOf)
if ($cpuCriteria.Count -ne 1) { throw 'The dynamic VM CPU alert must have exactly one metric condition.' }
$cpuCriterion = $cpuCriteria[0]
if ($cpuCriterion.criterionType -ne 'DynamicThresholdCriterion' -or $cpuCriterion.metricNamespace -ne 'Microsoft.Compute/virtualMachines' -or $cpuCriterion.metricName -ne 'Percentage CPU' -or
    $cpuCriterion.operator -ne 'GreaterThan' -or $cpuCriterion.timeAggregation -ne 'Average' -or $cpuCriterion.alertSensitivity -ne 'Medium') {
  throw 'The dynamic VM CPU alert must detect above-baseline average Percentage CPU with medium sensitivity.'
}
if ($cpuCriterion.failingPeriods.numberOfEvaluationPeriods -ne 1 -or $cpuCriterion.failingPeriods.minFailingPeriodsToAlert -ne 1) { throw 'The dynamic VM CPU alert must require one violation out of one aggregated point.' }
if ($cpuCriterion.PSObject.Properties.Name -contains 'ignoreDataBefore') { throw 'The dynamic VM CPU alert must not discard its metric history by default.' }
Write-Output 'PASS: dynamic VM CPU alert defaults use a 5-minute check, 15-minute lookback, and one upper-threshold violation.'
if (-not $BicepExecutable) {
  $binary = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
  $BicepExecutable = Join-Path $HOME ".azure/bin/$binary"
}
$version = & $BicepExecutable --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Bicep CLI version 0\.37\.4\b') { throw 'Compile templates with Bicep 0.37.4 to match the checked-in artifacts.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('amlab-template-check-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
  foreach ($relative in @('infra/main', 'infra/stages/00-foundation', 'infra/stages/10-workloads', 'infra/stages/20-alerting', 'infra/stages/40-optional-advanced', 'infra/stages/41-sentinel-content', 'infra/stages/50-ai', 'infra/stages/60-sre-agent', 'infra/stages/70-observability-agent', 'infra/modules/lab-console-platform', 'infra/modules/lab-console-job')) {
    $compiled = Join-Path $temporary ([IO.Path]::GetFileName($relative) + '.json')
    $messages = @(& $BicepExecutable build (Join-Path $source "$relative.bicep") --outfile $compiled 2>&1)
    if ($LASTEXITCODE -ne 0) { $messages; throw "Bicep compilation failed: $relative" }
    $actual = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    $expected = Get-Content -LiteralPath (Join-Path $source "$relative.json") -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    if ($actual -cne $expected) { throw "$relative.json differs from its Bicep source. Regenerate it before publishing." }
    Write-Output "PASS: $relative.json matches its Bicep source."
  }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
