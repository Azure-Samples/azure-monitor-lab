$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../../../scripts/write-webapp-console-config.ps1'
$output = Join-Path ([IO.Path]::GetTempPath()) "console-config-$([guid]::NewGuid().ToString('N')).json"
$testState = @{ EmptyInventory = $false; UnsafeGrafana = $false; FailInventory = $false; WorkbookName = 'Azure Monitor Lab - Health Dashboard'; CustomerDependencies = $false; WrongWorker = $false; WrongModel = $false }
$resourceBase = '/subscriptions/test-sub/resourceGroups/test-rg/providers'

function az {
  $global:LASTEXITCODE = 0
  if ($args -notcontains '--subscription' -or $args -notcontains 'test-sub') { throw 'Explicit subscription is missing.' }
  if ($testState.CustomerDependencies) {
    if ($args[0] -eq 'deployment' -and $args[1] -eq 'group' -and $args[2] -eq 'show') {
      return @{ enabled = $true; workerName = 'func-test-orders'; workerId = $(if($testState.WrongWorker) {'/subscriptions/other/providers/Microsoft.Web/sites/other-worker'} else {"$resourceBase/Microsoft.Web/sites/func-test-orders"}) } | ConvertTo-Json
    }
    if ($args[0] -eq 'webapp' -and $args[1] -eq 'show') { return 'app-lab-customer.azurewebsites.net' }
    if ($args[0] -eq 'rest' -and $args -contains 'get') {
      return $(if($testState.WrongModel) {"$resourceBase/Microsoft.Web/sites/unrelated-app"} else {"$resourceBase/Microsoft.Web/sites/app-lab-customer"})
    }
  }
  if ($args[0] -ne 'resource' -or $args[1] -notin @('list', 'show')) { throw 'Only read operations are allowed.' }
  if ($args[1] -eq 'list') {
    if ($testState.FailInventory) { $global:LASTEXITCODE = 1; return '' }
    if ($testState.EmptyInventory) { return '[]' }
    return @(
      @{ type = 'microsoft.insights/components'; name = 'appi-lab'; id = "$resourceBase/Microsoft.Insights/components/appi-lab" },
      @{ type = 'Microsoft.OperationalInsights/workspaces'; name = 'law-lab-central'; id = "$resourceBase/Microsoft.OperationalInsights/workspaces/law-lab-central" },
      @{ type = 'Microsoft.OperationalInsights/workspaces'; name = 'law-lab-appinsights'; id = "$resourceBase/Microsoft.OperationalInsights/workspaces/law-lab-appinsights" },
      @{ type = 'microsoft.insights/workbooks'; name = 'cost'; id = "$resourceBase/Microsoft.Insights/workbooks/cost" },
      @{ type = 'microsoft.insights/workbooks'; name = 'health'; id = "$resourceBase/Microsoft.Insights/workbooks/health" },
      @{ type = 'Microsoft.Dashboard/grafana'; name = 'grafana'; id = "$resourceBase/Microsoft.Dashboard/grafana/grafana" },
      @{ type = 'microsoft.app/agents'; name = 'sre-lab'; id = "$resourceBase/Microsoft.App/agents/sre-lab" },
      @{ type = 'Microsoft.CognitiveServices/accounts/projects'; name = 'foundry/project'; id = "$resourceBase/Microsoft.CognitiveServices/accounts/foundry/projects/project" },
      @{ type = 'Microsoft.Web/sites'; name = 'app-lab'; id = "$resourceBase/Microsoft.Web/sites/app-lab" }
      if ($testState.CustomerDependencies) {
        @{ type = 'Microsoft.Web/sites'; name = 'app-lab-customer'; id = "$resourceBase/Microsoft.Web/sites/app-lab-customer" }
        @{ type = 'Microsoft.Web/sites'; name = 'func-test-orders'; id = "$resourceBase/Microsoft.Web/sites/func-test-orders" }
        @{ type = 'Microsoft.CloudHealth/healthmodels'; name = 'hm-amlab-customer'; id = "$resourceBase/Microsoft.CloudHealth/healthmodels/hm-amlab-customer" }
      }
    ) | ConvertTo-Json
  }
  if ($args -contains 'properties.WorkspaceResourceId') {
    if ($testState.UnsafeGrafana) { return '/subscriptions/other-sub/resourceGroups/other-rg/providers/Microsoft.OperationalInsights/workspaces/other-law' }
    return "$resourceBase/Microsoft.OperationalInsights/workspaces/law-lab-appinsights"
  }
  if ($args -contains 'properties.endpoints') {
    if ($testState.UnsafeGrafana) { return '{"AI Foundry API":"https://attacker.example/api/projects/test"}' }
    return '{"AI Foundry API":"https://foundry.services.ai.azure.com/api/projects/project"}'
  }
  if ($args -contains 'properties.endpoint') {
    if ($testState.UnsafeGrafana) { return 'javascript:alert(1)' }
    return 'https://example.grafana.azure.com/'
  }
  if ($args -contains "$resourceBase/Microsoft.Insights/workbooks/cost") { return 'Lab Cost' }
  return $testState.WorkbookName
}

try {
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output
  $config = Get-Content -Raw $output | ConvertFrom-Json
  if ($config.LabConsole.Links.Workbook -notlike '*/health/workbook') { throw 'Wrong workbook selected.' }
  if ($config.LabConsole.Links.Logs -notlike '*/law-lab-central/logs') { throw 'Wrong workspace selected.' }
  if ($config.LabConsole.Links.ApplicationInsights -notlike '*/appi-lab/overview') { throw 'App Insights missing.' }
  if ($config.LabConsole.Links.Grafana -ne 'https://example.grafana.azure.com/') { throw 'Grafana missing.' }
  if ($config.LabConsole.Links.SreAgent -ne 'https://sre.azure.com/#/agent/test-sub/test-rg/sre-lab') { throw 'SRE link missing.' }
  if ($config.LabConsole.Foundry.ProjectEndpoint -ne 'https://foundry.services.ai.azure.com/api/projects/project') { throw 'Foundry endpoint missing.' }
  if ($config.LabConsole.Foundry.Enabled) { throw 'Billable agent execution enabled by default.' }
  if ($config.LabConsole.Health.Enabled) { throw 'Health reads enabled by default.' }
  if ($config.LabConsole.Operations.Enabled -ne $false) { throw 'Operations must be explicitly disabled in generated configuration.' }
  if ($config.LabConsole.Operations.SubscriptionId -ne 'test-sub') { throw 'Operations subscription context missing.' }
  if ($config.LabConsole.Health.CentralWorkspaceResourceId -ne "$resourceBase/Microsoft.OperationalInsights/workspaces/law-lab-central") { throw 'Central health workspace missing.' }
  if ($config.LabConsole.Health.AppInsightsWorkspaceResourceId -ne "$resourceBase/Microsoft.OperationalInsights/workspaces/law-lab-appinsights") { throw 'Application health workspace association missing.' }
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output -EnableInfrastructureHealth -TenantId test-tenant
  if (-not (Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Health.Enabled) { throw 'Explicit health opt-in ignored.' }
  if ($config.LabConsole.Sre.Enabled) { throw 'SRE execution enabled by default.' }
  if ($config.LabConsole.Sre.AgentName -ne 'sre-lab' -or $config.LabConsole.Sre.SubscriptionId -ne 'test-sub') { throw 'SRE resource scope missing.' }
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output -EnableSreAssistant -TenantId test-tenant -SreMcpExecutable 'mcp/azmcp' -SreModelEndpoint 'https://test.openai.azure.com/' -SreModelDeployment 'gpt-5-mini'
  $sre = (Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Sre
  if (-not $sre.Enabled -or $sre.TenantId -ne 'test-tenant' -or $sre.McpExecutable -ne 'mcp/azmcp') { throw 'Explicit SRE configuration ignored.' }
  if ($sre.ModelEndpoint -ne 'https://test.openai.azure.com/' -or $sre.ModelDeployment -ne 'gpt-5-mini') { throw 'SRE host model settings missing.' }
  $missingRuntimeRejected = $false
  try { & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output -EnableSreConversation } catch { $missingRuntimeRejected = $true }
  if (-not $missingRuntimeRejected) { throw 'SRE opt-in without runtime accepted.' }
  $invalidEndpointRejected = $false
  try { & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output -SreModelEndpoint 'https://attacker.example/' } catch { $invalidEndpointRejected = $true }
  if (-not $invalidEndpointRejected) { throw 'Unsafe model endpoint accepted.' }
  if ($config.LabConsole.AppService -ne 'app-lab') { throw 'App context missing.' }
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output -EnableFoundryPlayground
  if (-not (Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Foundry.Enabled) { throw 'Explicit playground opt-in ignored.' }
  $testState.WorkbookName = 'Azure Monitor Lab - Traffic Lights'
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output
  if ((Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Links.Workbook -notlike '*/health/workbook') { throw 'Legacy workbook missing.' }
  $testState.UnsafeGrafana = $true
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output
  if ((Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Links.Grafana) { throw 'Unsafe Grafana URL accepted.' }
  if ((Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Foundry.ProjectEndpoint) { throw 'Unsafe Foundry endpoint accepted.' }
  if ((Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Health.AppInsightsWorkspaceResourceId) { throw 'Out-of-scope health workspace accepted.' }
  $testState.EmptyInventory = $true
  $testState.CustomerDependencies = $true
  $testState.EmptyInventory = $false
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -WebAppName app-lab -CustomerWebAppName app-lab-customer -OutputPath $output
  $customerConfig = (Get-Content -Raw $output | ConvertFrom-Json).LabConsole
  if ($customerConfig.Operations.CustomerWorkerName -cne 'func-test-orders' -or
      $customerConfig.Operations.CustomerDependenciesEnabled -ne $false -or
      $customerConfig.Links.CustomerHealthModel -notlike '*/hm-amlab-customer/overview') { throw 'Exact dependency worker/model discovery or disabled-until-bootstrap gate failed.' }
  foreach ($failure in @('WrongWorker', 'WrongModel')) {
    $testState[$failure] = $true
    $rejected = $false
    try { & $helper -SubscriptionId test-sub -ResourceGroup test-rg -WebAppName app-lab -CustomerWebAppName app-lab-customer -OutputPath $output } catch { $rejected = $true }
    if (-not $rejected) { throw 'Out-of-scope dependency/model target was accepted.' }
    $testState[$failure] = $false
  }
  $testState.CustomerDependencies = $false
  $testState.EmptyInventory = $true
  & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output
  $empty = (Get-Content -Raw $output | ConvertFrom-Json).LabConsole.Links
  if (@($empty.PSObject.Properties | Where-Object Value).Count -ne 0) { throw 'Empty resource group produced links.' }
  $testState.FailInventory = $true
  $caught = $false
  try { & $helper -SubscriptionId test-sub -ResourceGroup test-rg -OutputPath $output } catch { $caught = $true }
  if (-not $caught) { throw 'Inventory failure was not reported.' }
  Write-Host 'PASS: resource discovery, URL safety, missing resources, and CLI failure handling.'
} finally {
  Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
}