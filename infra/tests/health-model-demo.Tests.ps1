$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$main = Get-Content (Join-Path $root 'infra\main.json') -Raw | ConvertFrom-Json -AsHashtable
$stage = Get-Content (Join-Path $root 'infra\stages\80-health-model-demo.json') -Raw | ConvertFrom-Json -AsHashtable
function Assert-Demo([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}
$optional = @($main.resources | Where-Object name -eq 'health-model-demo')
Assert-Demo ($main.parameters.enableHealthModelDemo.defaultValue -eq $false -and $optional.Count -eq 1 -and $optional[0].condition -eq "[parameters('enableHealthModelDemo')]") 'Demo must be one default-off conditional deployment.'
Assert-Demo ($main.outputs.Count -le 64) 'Root outputs must stay within the ARM limit.'
foreach ($output in 'healthModelDemoCafeWebAppName', 'healthModelDemoCafeWebAppUrl', 'healthModelDemoCafeModelName', 'healthModelDemoFlowModelName') {
  Assert-Demo (-not $main.outputs.Contains($output) -and $stage.outputs.Contains($output)) "Demo output must remain stage-only to preserve existing root outputs: $output"
}
foreach ($output in 'appServiceRepoUrl', 'rbacSummary', 'vmssAutoscaleName', 'dataExportRuleName') {
  Assert-Demo ($main.outputs.Contains($output)) "Pre-existing public root output must be preserved: $output"
}
$advanced = Get-Content (Join-Path $root 'infra\stages\40-optional-advanced.json') -Raw | ConvertFrom-Json -AsHashtable
$advancedTest = @($advanced.resources | Where-Object name -eq 'availability-test')[0]
Assert-Demo ($stage.parameters.availabilityTestName.defaultValue -eq $advancedTest.properties.parameters.name.value) 'Stage 80 must reference the actual console availability test owned by Stage E.'
Assert-Demo ($optional[0].properties.parameters.availabilityTestName.value -match "availability-test.*outputs.testName") 'One-shot root must override the staged test-name default with its own availability test output.'
$cafe = ($stage.resources | Where-Object name -eq 'health-model-demo-cafe').properties.template
$flow = ($stage.resources | Where-Object name -eq 'health-model-demo-flows').properties.template
Assert-Demo ($main.parameters.healthModelDemoCafeLocation.defaultValue -ceq 'francecentral' -and
  $stage.parameters.location.defaultValue -ceq 'francecentral' -and
  $stage.parameters.healthModelLocation.defaultValue -ceq 'swedencentral') 'Cafe hosting must default to France Central independently of Sweden Central health models.'
Assert-Demo ($main.parameters.healthModelDemoCafePlanSku.defaultValue -ceq 'S1' -and
  $stage.parameters.healthModelDemoCafePlanSku.defaultValue -ceq 'S1' -and
  @($main.parameters.healthModelDemoCafePlanSku.allowedValues).Count -eq 2 -and
  @($main.parameters.healthModelDemoCafePlanSku.allowedValues) -contains 'S2' -and
  $optional[0].properties.parameters.healthModelDemoCafePlanSku.value -ceq "[parameters('healthModelDemoCafePlanSku')]") 'Cafe plan must default to S1 while allowing S2 through the one-shot and staged deployment.'
$ui = Get-Content (Join-Path $root 'infra\createUiDefinition.json') -Raw | ConvertFrom-Json
$cafeRegion = @($ui.parameters.steps | Where-Object name -eq 'stages')[0].elements | Where-Object name -eq 'healthModelDemoCafeLocation'
$cafeSku = @($ui.parameters.steps | Where-Object name -eq 'stages')[0].elements | Where-Object name -eq 'healthModelDemoCafePlanSku'
$demoToggle = @($ui.parameters.steps | Where-Object name -eq 'stages')[0].elements | Where-Object name -eq 'enableHealthModelDemo'
Assert-Demo ($cafeRegion.defaultValue -ceq 'francecentral' -and
  $cafeRegion.visible -eq "[equals(steps('stages').enableHealthModelDemo, true)]" -and
  $ui.parameters.outputs.healthModelDemoCafeLocation -eq "[steps('stages').healthModelDemoCafeLocation]" -and
  @($cafeSku.constraints.allowedValues | Where-Object label -CEQ $cafeSku.defaultValue).Count -eq 1 -and
  @($cafeSku.constraints.allowedValues | Where-Object label -CEQ $cafeSku.defaultValue)[0].value -ceq 'S1' -and
  @($cafeSku.constraints.allowedValues.value) -contains 'S2' -and
  $cafeSku.visible -eq "[equals(steps('stages').enableHealthModelDemo, true)]" -and
  $ui.parameters.outputs.healthModelDemoCafePlanSku -eq "[steps('stages').healthModelDemoCafePlanSku]" -and
  $demoToggle.toolTip -match 'Standard S1') 'Portal must expose the separate Cafe region and S1/S2 plan when the demo is selected.'
foreach ($modelModule in 'health-model-demo-cafe', 'health-model-demo-flows') {
  Assert-Demo (($stage.resources | Where-Object name -eq $modelModule).properties.parameters.location.value -ceq "[parameters('healthModelLocation')]") 'Both health models must use their separate supported region.'
}
$heartbeatQuery = @'
let expectedVmIds = dynamic({0});
Heartbeat
| where _ResourceId in~ (expectedVmIds)
| summarize newest = max(TimeGenerated) by vmId = tolower(_ResourceId)
| summarize reporting = count(), missingCount = countif(newest < ago(10m))
| project value = case(missingCount > 0, todouble(missingCount), reporting < array_length(expectedVmIds), real(null), 0.0)
'@
$heartbeat = ($flow.variables.entities | Where-Object name -eq 'virtual-machines').signalGroups
Assert-Demo ($heartbeat.Replace("''", "'").Replace("`r`n", "`n").Contains($heartbeatQuery.Replace("`r`n", "`n"))) 'Heartbeat query must scope configured VMs, preserve recent faults and return null for missing history.'
Assert-Demo ($heartbeat.Contains("string(parameters('vmIds'))") -and $heartbeat.Contains("'PT2H', 'Count', __bicep.rules('GreaterThan', 0, 1)")) 'Heartbeat query must use the deployed VM list, two-hour window and existing fault thresholds.'
$oneShotFlow = (($optional[0].properties.template.resources | Where-Object name -eq 'health-model-demo-flows').properties.template)
Assert-Demo (($oneShotFlow.variables.entities | Where-Object name -eq 'virtual-machines').signalGroups -ceq $heartbeat) 'One-shot and staged heartbeat signals must match.'

# Contract fixtures model the guarded KQL above; no Log Analytics service is invoked.
foreach ($case in @(
  @{ Name = 'no optional VMs'; Ids = @(); Rows = @(); Expected = 0 }
  @{ Name = 'all reporting'; Ids = @('vm-a', 'vm-b'); Rows = @(@('VM-A', 1), @('vm-b', 2)); Expected = 0 }
  @{ Name = 'ten-minute boundary'; Ids = @('vm-a'); Rows = ,@('vm-a', 10); Expected = 0 }
  @{ Name = 'recent loss'; Ids = @('vm-a'); Rows = ,@('vm-a', 11); Expected = 1 }
  @{ Name = 'two recent losses'; Ids = @('vm-a', 'vm-b'); Rows = @(@('vm-a', 11), @('vm-b', 15)); Expected = 2 }
  @{ Name = 'two-hour boundary'; Ids = @('vm-a'); Rows = ,@('vm-a', 120); Expected = 1 }
  @{ Name = 'prolonged loss'; Ids = @('vm-a'); Rows = ,@('vm-a', 121); Expected = $null }
  @{ Name = 'partial prolonged loss'; Ids = @('vm-a', 'vm-b'); Rows = @(@('vm-a', 1), @('vm-b', 121)); Expected = $null }
  @{ Name = 'never reported'; Ids = @('vm-a'); Rows = @(); Expected = $null }
  @{ Name = 'unrelated VM'; Ids = @('vm-a'); Rows = ,@('other-vm', 1); Expected = $null }
  @{ Name = 'known fault with absent peer'; Ids = @('vm-a', 'vm-b'); Rows = ,@('vm-a', 11); Expected = 1 }
  @{ Name = 'recovery uses newest heartbeat'; Ids = @('vm-a'); Rows = @(@('vm-a', 11), @('vm-a', 1)); Expected = 0 }
)) {
  $newest = @{}
  foreach ($row in $case.Rows) {
    if ($row[0] -in $case.Ids -and $row[1] -le 120 -and
        (-not $newest.ContainsKey($row[0]) -or $row[1] -lt $newest[$row[0]])) {
      $newest[$row[0]] = $row[1]
    }
  }
  $missing = @($newest.Values | Where-Object { $_ -gt 10 }).Count
  $value = if ($missing -gt 0) { $missing } elseif ($newest.Count -lt $case.Ids.Count) { $null } else { 0 }
  Assert-Demo ($value -eq $case.Expected) "Heartbeat contract failed: $($case.Name)"
}
Write-Output 'PASS: heartbeat query contract and 12 fixtures cover prolonged/partial loss, absent/unrelated VMs, thresholds and recovery.'
$workloadModule = ($stage.resources | Where-Object name -eq 'health-model-demo-cafe-workload')
$workload = $workloadModule.properties.template
foreach ($workloadTemplate in @(
  $workload
  ($optional[0].properties.template.resources | Where-Object name -eq 'health-model-demo-cafe-workload').properties.template
)) {
  $plans = @($workloadTemplate.resources | Where-Object type -eq 'Microsoft.Web/serverfarms')
  Assert-Demo ($plans.Count -eq 1 -and $plans[0].sku.name -ceq "[parameters('healthModelDemoCafePlanSku')]" -and
    $plans[0].sku.tier -ceq 'Standard' -and $plans[0].sku.capacity -eq 1 -and
    $plans[0].properties.reserved -eq $true) 'Both deployment routes must use the selected single-instance Linux Standard Cafe plan.'
  $sites = @($workloadTemplate.resources | Where-Object type -eq 'Microsoft.Web/sites')
  Assert-Demo ($sites.Count -eq 1 -and
    $sites[0].properties.siteConfig.ContainsKey('appCommandLine') -and
    $sites[0].properties.siteConfig.appCommandLine -ceq '') 'Both deployment routes must clear the startup override so a fresh Cafe does not crash before publication.'
}
Assert-Demo ($workloadModule.properties.parameters.namePrefix.value -eq 'cafe' -and
  $workloadModule.properties.parameters.tags.value -match "'lab-cafe'" -and
  $workloadModule.properties.parameters.healthModelDemoCafePlanSku.value -ceq "[parameters('healthModelDemoCafePlanSku')]" -and
  $workload.parameters.healthModelDemoCafePlanSku.defaultValue -ceq 'S1') 'Standalone Cafe adoption and plan SKU forwarding contract changed.'
Assert-Demo ($cafe.parameters.healthModelName.defaultValue -eq 'hm-lab-cafe' -and $flow.parameters.healthModelName.defaultValue -eq 'hm-amlab-flows') 'Demo model default names must adopt existing models.'
Assert-Demo ($cafe.variables.entities.Count -eq 12 -and $cafe.variables.edges.Count -eq 12 -and $cafe.variables.definitions.Count -eq 2) 'Cafe must have 12 explicit entities, automatic root, 12 edges and 2 definitions.'
Assert-Demo ($flow.variables.entities.Count -eq 18 -and @($flow.variables.copy | Where-Object name -eq 'vmEntities').Count -eq 1) 'Flow model must retain its 18 entities plus automatic root and optional VM entities (21 with two VMs).'
foreach ($template in $cafe, $flow) {
  foreach ($resource in $template.resources.Values | Where-Object type -like 'Microsoft.CloudHealth/*') {
    Assert-Demo ($resource.apiVersion -eq '2026-11-01') 'All native demo CloudHealth resources must use API 2026-11-01.'
  }
  Assert-Demo ($template.resources.root.name -eq "[format('{0}/{1}', parameters('healthModelName'), parameters('healthModelName'))]") 'Update the service-created root at its existing child ID.'
}
Assert-Demo ($cafe.resources.reporter.properties.parameters.principalId.value -match 'console.*identity.principalId' -and $flow.resources.consoleReporter.properties.parameters.principalId.value -match 'consoleApp.*identity.principalId') 'Reporter assignments must use the core Control Center identity.'
Assert-Demo ($cafe.resources.reporter.properties.parameters.roleDefinitionId.value -eq "[parameters('reporterRoleDefinitionId')]" -and $flow.resources.reporterRole.name -eq "[guid(resourceGroup().id, 'health-model-reporter')]") 'Both models must share the existing RG-owned reporter role.'
$reader = $cafe.resources.reader.properties.template
$readerAssignments = @($reader.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
$readerScopes = @(
  "[resourceId('Microsoft.Web/sites', last(split(parameters('webAppId'), '/')))]"
  "[resourceId('Microsoft.Storage/storageAccounts', last(split(parameters('storageId'), '/')))]"
  "[resourceId('Microsoft.OperationalInsights/workspaces', last(split(parameters('workspaceId'), '/')))]"
)
$defaultReaders = @($readerAssignments | Where-Object condition -eq "[empty(parameters('assignmentName'))]")
Assert-Demo ($readerAssignments.Count -eq 4 -and $defaultReaders.Count -eq 3 -and
  -not (Compare-Object $readerScopes @($defaultReaders.scope))) 'Default Cafe readers must use three exact resource scopes, avoiding standalone CLI RG-assignment conflicts.'
Assert-Demo (@($readerAssignments | Where-Object { $_.name -eq "[parameters('assignmentName')]" -and $_.condition -eq "[not(empty(parameters('assignmentName')))]" }).Count -eq 1) 'An explicitly provided existing RG reader assignment GUID must be adopted without renaming it.'
$role = $flow.resources.reporterRole
Assert-Demo ($role.properties.assignableScopes.Count -eq 1 -and $role.properties.assignableScopes[0] -eq '[resourceGroup().id]' -and $role.properties.permissions[0].actions.Count -eq 5) 'Reporter role must have one exact RG assignable scope and five read/report actions.'
foreach ($template in $cafe, $flow) {
  $assignment = if ($template -eq $cafe) { $template.resources.reporter } else { $template.resources.consoleReporter }
  $assignmentResource = @($assignment.properties.template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0]
  Assert-Demo ($assignmentResource.scope -ceq "[resourceId('Microsoft.CloudHealth/healthmodels', parameters('healthModelName'))]") 'Reporter assignment must be model-scoped.'
}
$site = @($workload.resources | Where-Object type -eq 'Microsoft.Web/sites')[0]
$settings = $site.properties.siteConfig.appSettings
foreach ($entry in @{ ApplicationInsightsAgent_EXTENSION_VERSION = 'disabled'; SCM_DO_BUILD_DURING_DEPLOYMENT = 'true'; ENABLE_ORYX_BUILD = 'true' }.GetEnumerator()) {
  Assert-Demo ((@($settings | Where-Object name -eq $entry.Key)[0].value) -eq $entry.Value) "Cafe setting must be preserved: $($entry.Key)"
}

# Evaluate only pure source data/functions, never the standalone builder's CLI actions.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\build-healthmodel-tutorial.ps1'), [ref] $tokens, [ref] $errors)
foreach ($name in 'New-Rules', 'New-LogSignal') {
  $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Invoke-Expression $function.Extent.Text
}
$webAppName = 'app-cafe-adoption'
$webAppId = '/test/webapp'
$storageName = 'stcafeadoption'
$storageId = '/test/storage'
$HealthModelName = 'hm-lab-cafe'
foreach ($name in 'auth', 'signalDefinitions', 'failureRules', 'entities', 'relationships') {
  $assignment = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $name) }, $true)
  Invoke-Expression $assignment.Extent.Text
}
Assert-Demo ($auth -eq 'auth-system' -and $cafe.resources.auth.name -eq "[format('{0}/{1}', parameters('healthModelName'), '$auth')]") 'Cafe must adopt the standalone auth-system authentication child rather than create a redundant child.'
foreach ($helper in 'logGroup', 'resourceSignals') {
  $group = $cafe.functions[0].members[$helper].output.value
  $actualAuth = if ($helper -eq 'logGroup') { $group.azureLogAnalytics.authenticationSetting } else { $group.azureResource.authenticationSetting }
  Assert-Demo ($actualAuth -eq $auth) "Cafe entity authentication reference must match the standalone child: $helper"
}
foreach ($entity in $entities) {
  $actual = @($cafe.variables.entities | Where-Object name -eq $entity.name)[0]
  Assert-Demo ($null -ne $actual) "Missing source entity: $($entity.name)"
  if ($entity.objective) {
    Assert-Demo ($actual.healthObjective -eq "[json('$($entity.objective)')]") "Health objective differs for $($entity.name)"
  }
  Assert-Demo (($actual.impact ?? 'Standard') -eq ($entity.impact ?? 'Standard')) "Impact differs for $($entity.name)"
  foreach ($signal in $entity.logSignals) {
    $expression = $actual.signalGroups.Replace("''", "'").Replace("`r`n", "`n")
    $query = $signal.'query-text'.Trim().Replace("`r`n", "`n")
    Assert-Demo ($expression.Contains($signal.name) -and $expression.Contains($query) -and $expression.Contains($signal.'data-unit')) "Missing/changed Cafe source signal: $($signal.name)"
  }
  foreach ($state in $entity.alerts.Keys) {
    Assert-Demo ($actual.alerts[$state].severity -eq $entity.alerts[$state].severity -and $actual.alerts[$state].description -eq $entity.alerts[$state].description -and $actual.alerts[$state].actionGroupIds -eq "[variables('actionGroupIds')]") "Alert differs for $($entity.name)/$state"
  }
}
Assert-Demo ($cafe.variables.failureRules -eq "[__bicep.rules('GreaterThan', '0', '2')]") 'Failure rules must remain >0 degraded, >2 unhealthy.'
Assert-Demo ($cafe.variables.definitions[0].evaluationRules -eq "[__bicep.rules('LessThan', '100', '50')]" -and $cafe.variables.definitions[1].evaluationRules -eq "[__bicep.rules('LessThan', '99.9', '99')]") 'Reusable metric thresholds changed.'
Assert-Demo (($cafe.variables.entities | Where-Object name -eq 'order-api').signalGroups -match "rules\('GreaterThan', '1000', '3000'\)") 'Slow order thresholds must remain 1000/3000 ms.'
for ($i = 0; $i -lt $relationships.Count; $i++) {
  Assert-Demo ($cafe.variables.edges[$i].child -eq $relationships[$i].child -and ($i -lt 2 -or $cafe.variables.edges[$i].parent -eq $relationships[$i].parent)) 'Cafe relationship order/topology differs from standalone builder.'
}
$signalHelper = $cafe.functions[0].members.logSignal.output.value
Assert-Demo ($signalHelper.signalKind -eq 'LogAnalyticsQuery' -and $signalHelper.timeGrain -eq 'PT5M' -and $signalHelper.refreshInterval -eq 'PT1M' -and $signalHelper.valueColumnName -eq 'value') 'Cafe log signals must retain their native kind, PT5M window, PT1M refresh and value column.'
foreach ($definition in $signalDefinitions) {
  $actual = @($cafe.variables.definitions | Where-Object name -eq $definition.name)[0]
  Assert-Demo ($actual.displayName -eq $definition.displayName -and $actual.metricName -eq $definition.metric.'metric-name' -and $actual.metricNamespace -eq $definition.metric.'metric-namespace') "Cafe reusable metric differs: $($definition.name)"
}
$metricResource = $cafe.resources.signalDefinitions.properties
Assert-Demo ($metricResource.aggregationType -eq 'Average' -and $metricResource.timeGrain -eq 'PT5M' -and $metricResource.refreshInterval -eq 'PT1M' -and $metricResource.dataUnit -eq 'Percent') 'Reusable metrics must retain their aggregation, window, refresh and units.'
foreach ($entity in $entities | Where-Object resourceId) {
  $actual = @($cafe.variables.entities | Where-Object name -eq $entity.name)[0]
  $parameter = if ($entity.resourceId -eq $webAppId) { 'webAppId' } else { 'storageId' }
  Assert-Demo ($actual.signalGroups -eq "[__bicep.resourceSignals(parameters('$parameter'), '$($entity.definitions[0])')]") "Azure resource/definition binding differs: $($entity.name)"
}
Write-Output 'PASS: optional native Health Model demo defaults, contracts, Cafe source parity, flow reuse, canvas, RBAC and workload settings.'
