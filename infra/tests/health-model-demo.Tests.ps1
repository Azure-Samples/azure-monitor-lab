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
$workloadModule = ($stage.resources | Where-Object name -eq 'health-model-demo-cafe-workload')
$workload = $workloadModule.properties.template
Assert-Demo ($workloadModule.properties.parameters.namePrefix.value -eq 'cafe' -and $workloadModule.properties.parameters.tags.value -match "'lab-cafe'") 'Standalone Cafe naming/tag adoption contract changed.'
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
Assert-Demo ($readerAssignments.Count -eq 4 -and @($readerAssignments | Where-Object { $_.condition -eq "[empty(parameters('assignmentName'))]" -and $_.scope -match '(Microsoft.Web/sites|Microsoft.Storage/storageAccounts|Microsoft.OperationalInsights/workspaces)/' }).Count -eq 3) 'Default Cafe readers must use three exact resource scopes, avoiding standalone CLI RG-assignment conflicts.'
Assert-Demo (@($readerAssignments | Where-Object { $_.name -eq "[parameters('assignmentName')]" -and $_.condition -eq "[not(empty(parameters('assignmentName')))]" }).Count -eq 1) 'An explicitly provided existing RG reader assignment GUID must be adopted without renaming it.'
$role = $flow.resources.reporterRole
Assert-Demo ($role.properties.assignableScopes.Count -eq 1 -and $role.properties.assignableScopes[0] -eq '[resourceGroup().id]' -and $role.properties.permissions[0].actions.Count -eq 5) 'Reporter role must have one exact RG assignable scope and five read/report actions.'
foreach ($template in $cafe, $flow) {
  $assignment = if ($template -eq $cafe) { $template.resources.reporter } else { $template.resources.consoleReporter }
  $assignmentResource = @($assignment.properties.template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0]
  Assert-Demo ($assignmentResource.scope -match 'Microsoft.CloudHealth/healthmodels/') 'Reporter assignment must be model-scoped.'
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
