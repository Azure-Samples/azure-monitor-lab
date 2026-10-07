[CmdletBinding()]
param([string] $RepoRoot = (Join-Path $PSScriptRoot '../..'))

$ErrorActionPreference = 'Stop'

function Assert-Contract([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

$expectedMetrics = @(
  'system.cpu.time', 'system.memory.usage', 'system.disk.io', 'system.disk.operations',
  'system.disk.operation_time', 'system.filesystem.usage', 'system.network.io',
  'system.network.dropped', 'system.network.errors', 'system.uptime'
)
$enableExpression = "[and(parameters('enableVmOtelMetrics'), or(parameters('deployLinuxVm'), parameters('deployWindowsVm')))]"
$otelIdExpression = "[if(variables('deployVmOtelMetrics'), createObject('value', reference(resourceId('Microsoft.Resources/deployments', 'vm-otel-metrics'), '2022-09-01').outputs.id.value), createObject('value', ''))]"

foreach ($path in @('infra/main.json', 'infra/stages/10-workloads.json')) {
  $template = Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw | ConvertFrom-Json -AsHashtable
  Assert-Contract ($template.parameters.enableVmOtelMetrics.type -eq 'bool' -and
    $template.parameters.enableVmOtelMetrics.defaultValue -ceq $true) "$path must default OTel metrics on."
  Assert-Contract ($template.variables.deployVmOtelMetrics -ceq $enableExpression) "$path must create OTel resources only when enabled and at least one VM is selected."

  $modules = @($template.resources | Where-Object name -eq 'vm-otel-metrics')
  Assert-Contract ($modules.Count -eq 1) "$path must contain one shared OTel DCR module."
  $module = $modules[0]
  Assert-Contract ($module.condition -ceq "[variables('deployVmOtelMetrics')]") "$path lost its OTel enablement condition."
  Assert-Contract ($module.properties.parameters.name.value -ceq "[format('MSVMOtel-{0}-{1}', parameters('location'), parameters('namePrefix'))]") "$path must use the enhanced-monitoring OTel DCR naming convention."
  Assert-Contract ($module.properties.parameters.location.value -ceq "[parameters('location')]") "$path must co-locate the OTel DCR with the existing workspace."
  $expectedAccount = if ($path -eq 'infra/main.json') {
    "[reference(resourceId('Microsoft.Resources/deployments', 'amw'), '2022-09-01').outputs.id.value]"
  } else {
    "[resourceId('Microsoft.Monitor/accounts', variables('amwName'))]"
  }
  Assert-Contract ($module.properties.parameters.monitoringAccountId.value -ceq $expectedAccount) "$path must reuse the existing lab Azure Monitor workspace."
  $nested = $module.properties.template
  Assert-Contract (@($nested.resources).Count -eq 1) "$path must not add another workspace, agent or RBAC grants for OTel collection."
  $dcr = $nested.resources[0]
  Assert-Contract ($dcr.type -eq 'Microsoft.Insights/dataCollectionRules' -and $dcr.apiVersion -eq '2024-03-11' -and
    -not $dcr.ContainsKey('kind')) "$path must use the cross-OS OTel DCR API without restricting its OS kind."
  $sources = @($dcr.properties.dataSources.performanceCountersOTel)
  Assert-Contract ($sources.Count -eq 1 -and $dcr.properties.dataSources.Count -eq 1) "$path must collect OTel counters, not additional log or process streams."
  $source = $sources[0]
  Assert-Contract ($source.name -ceq 'OtelPerfCounters' -and $source.samplingFrequencyInSeconds -eq 60 -and
    ($source.streams -join ',') -ceq 'Microsoft-OtelPerfMetrics') "$path must use the documented OTel stream at 60-second sampling."
  Assert-Contract ($source.counterSpecifiers.Count -eq 10 -and
    -not (Compare-Object $expectedMetrics @($source.counterSpecifiers))) "$path must collect exactly the ten default metrics, without paid extra counters."
  $destinations = @($dcr.properties.destinations.monitoringAccounts)
  Assert-Contract ($destinations.Count -eq 1 -and $dcr.properties.destinations.Count -eq 1 -and
    $destinations[0].name -ceq 'MonitoringAccount' -and
    $destinations[0].accountResourceId -ceq "[parameters('monitoringAccountId')]") "$path must use the documented destination contract and send OTel metrics only to the selected AMW."
  $flows = @($dcr.properties.dataFlows)
  Assert-Contract ($flows.Count -eq 1 -and ($flows[0].streams -join ',') -ceq 'Microsoft-OtelPerfMetrics' -and
    ($flows[0].destinations -join ',') -ceq $destinations[0].name) "$path must route the OTel stream to its declared destination."

  foreach ($os in @('linux', 'windows')) {
    $vmModules = @($template.resources | Where-Object name -eq "vm-$os")
    Assert-Contract ($vmModules.Count -eq 1) "$path must preserve the $os VM module."
    $vmModule = $vmModules[0]
    $vmFlag = if ($os -eq 'linux') { 'deployLinuxVm' } else { 'deployWindowsVm' }
    Assert-Contract ($vmModule.condition -ceq "[parameters('$vmFlag')]") "$path must still honor $vmFlag independently of metrics."
    Assert-Contract ($vmModule.properties.parameters.otelDcrId -ceq $otelIdExpression -and
      $vmModule.properties.parameters.dcrId.value -ceq "[resourceId('Microsoft.Insights/dataCollectionRules', variables('dcrVmInsightsName'))]") "$path must add the optional DCR without replacing classic collection."
    $vmTemplate = $vmModule.properties.template
    Assert-Contract ($vmTemplate.parameters.otelDcrId.defaultValue -ceq '') "$path $os VM must support existing callers without OTel."
    $classic = @($vmTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRuleAssociations' -and $_.name -eq 'vminsights-association' })
    Assert-Contract ($classic.Count -eq 1 -and -not $classic[0].ContainsKey('condition') -and
      $classic[0].properties.dataCollectionRuleId -ceq "[parameters('dcrId')]") "$path $os VM must retain its unconditional classic association."
    $otel = @($vmTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRuleAssociations' -and $_.name -eq 'vm-otel-metrics-association' })
    Assert-Contract ($otel.Count -eq 1 -and $otel[0].condition -ceq "[not(empty(parameters('otelDcrId')))]" -and
      $otel[0].properties.dataCollectionRuleId -ceq "[parameters('otelDcrId')]" -and
      $otel[0].scope -ceq "[format('Microsoft.Compute/virtualMachines/{0}', parameters('vmName'))]") "$path $os VM must conditionally associate only its own OTel DCR."
    $amaType = if ($os -eq 'linux') { 'AzureMonitorLinuxAgent' } else { 'AzureMonitorWindowsAgent' }
    $agents = @($vmTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines/extensions' -and $_.properties.type -eq $amaType })
    Assert-Contract ($agents.Count -eq 1 -and $agents[0].properties.autoUpgradeMinorVersion -eq $true -and
      $agents[0].properties.enableAutomaticUpgrade -eq $true -and
      ($otel[0].dependsOn -join ',').Contains($amaType)) "$path $os VM must reuse and wait for its auto-upgrading AMA."
  }
  $vmss = @($template.resources | Where-Object name -eq 'vmss')
  if ($vmss.Count) {
    Assert-Contract (($vmss | ConvertTo-Json -Depth 100 -Compress) -notmatch 'OtelPerfMetrics|otelDcrId|vm-otel-metrics') "$path must not enable unsupported VMSS OTel collection."
  }
  Write-Output "PASS: $path keeps classic monitoring and gates cross-OS default OTel metrics, workspace reuse and VM associations."
}

foreach ($path in @('infra/main.json', 'infra/stages/00-foundation.json')) {
  $template = Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw | ConvertFrom-Json -AsHashtable
  $classic = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and $_.name -eq "[variables('dcrVmInsightsName')]" })
  Assert-Contract ($classic.Count -eq 1 -and -not $classic[0].ContainsKey('condition')) "$path must retain the classic DCR regardless of the OTel option."
  $counter = $classic[0].properties.dataSources.performanceCounters[0]
  Assert-Contract (($counter.streams -join ',') -ceq 'Microsoft-InsightsMetrics' -and
    ($counter.counterSpecifiers -join ',') -ceq '\VmInsights\DetailedMetrics' -and
    $counter.samplingFrequencyInSeconds -eq 60 -and
    @($classic[0].properties.destinations.logAnalytics).Count -eq 1) "$path must preserve classic counters and Log Analytics ingestion."
}
Write-Output 'PASS: one-shot and staged classic VM Insights DCRs remain enabled and unchanged in purpose. No Azure calls.'
