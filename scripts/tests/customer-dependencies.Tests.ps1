[CmdletBinding()]
param([string] $CompiledDirectory = (Join-Path $PSScriptRoot '..\..\infra'))
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..'
. (Join-Path $root 'scripts\customer-dependency-helpers.ps1')
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
  $failed = $false
  try { & $Action } catch { $failed = $true }
  Assert-True $failed $Message
}
function Assert-ProcessorStorageContract([object] $DependencyTemplate) {
  $resources = if ($DependencyTemplate.resources -is [array]) {
    $DependencyTemplate.resources
  } else {
    $DependencyTemplate.resources.PSObject.Properties.Value
  }
  $storage = @($resources | Where-Object name -eq 'orders-processor-storage')
  Assert-True ($storage.Count -eq 1 -and
    $storage[0].properties.parameters.publicNetworkAccess.value -ceq 'Disabled') 'Processor host/deployment storage must be policy-compliant with public connectivity disabled.'
  Assert-True ($storage[0].properties.parameters.allowSharedKeyAccess.value -eq $false -and
    $storage[0].properties.parameters.allowBlobPublicAccess.value -eq $false) 'Public storage connectivity must not enable shared keys or anonymous blob access.'
  Assert-True ($storage[0].properties.parameters.networkAcls.value.defaultAction -ceq 'Deny' -and
    $storage[0].properties.parameters.networkAcls.value.bypass -ceq 'None') 'Processor storage must retain the approved network rules without additional exceptions.'
  Assert-True (@($DependencyTemplate.variables.storageSubresources).Count -eq 2 -and
    $DependencyTemplate.variables.storageSubresources -contains 'blob' -and
    $DependencyTemplate.variables.storageSubresources -contains 'queue') 'Flex storage needs exactly Blob and Queue private endpoints, not Azure Files.'
  $endpoints = @($resources | Where-Object { $_.name -match 'customer-storage-.*-private-endpoint' })
  $dns = @($resources | Where-Object { $_.name -match 'customer-storage-.*-dns' })
  Assert-True ($endpoints.Count -eq 1 -and $dns.Count -eq 1 -and
    $endpoints[0].copy.count -match "length\(variables\('storageSubresources'\)\)" -and
    $dns[0].copy.count -match "length\(variables\('storageSubresources'\)\)") 'Disabled-public storage must have matching two-service private-endpoint and DNS deployment loops.'
  Assert-True ($endpoints[0].properties.parameters.subnetResourceId.value -match '/subnets/private-endpoints' -and
    $dns[0].properties.parameters.name.value -match 'privatelink.*core\.windows\.net') 'Storage private endpoints and DNS must use the existing private subnet and official storage zones.'
  $connections = $endpoints[0].properties.parameters.privateLinkServiceConnections.value | ConvertTo-Json -Depth 20 -Compress
  $zoneGroup = $endpoints[0].properties.parameters.privateDnsZoneGroup.value | ConvertTo-Json -Depth 20 -Compress
  $links = $dns[0].properties.parameters.virtualNetworkLinks.value | ConvertTo-Json -Depth 20 -Compress
  Assert-True ($connections -match 'groupIds.*storageSubresources' -and
    $connections -match 'privateLinkServiceId.*storage' -and
    $zoneGroup -match 'privateDnsZoneResourceId.*storageDns' -and
    $links -match 'network.*registrationEnabled.*false') 'Storage subresource connections, matching DNS zone groups and non-registering VNet links must be wired.'
  $sql = @($resources | Where-Object type -eq 'Microsoft.Sql/servers')
  Assert-True ($sql.Count -eq 1 -and $sql[0].properties.publicNetworkAccess -ceq 'Disabled') 'SQL must use policy-compliant private access rather than temporary public firewall exceptions.'
  $processor = @($resources | Where-Object name -eq 'customer-orders-processor')
  Assert-True ($processor.Count -eq 1 -and
    $processor[0].properties.parameters.appSettings.value.CustomerOrdersQueueName -ceq 'orders' -and
    $processor[0].properties.parameters.appSettings.value.CustomerDependencies__QueueName -ceq 'orders') 'Worker flat Functions binding key and hierarchical queue setting must both use canonical orders.'
}
$source = Get-Content (Join-Path $root 'infra\modules\customer-dependencies.bicep') -Raw
$functionSource = Get-Content (Join-Path $root 'infra\modules\customer-functions.bicep') -Raw
$customerSource = Get-Content (Join-Path $root 'infra\modules\customer-webapp.bicep') -Raw
Assert-True ($source -notmatch 'administratorLogin' -and $source -match 'azureADOnlyAuthentication: true') 'SQL infrastructure must never contain SQL password/login properties.'
Assert-True ($source -match "sku: \{ name: 'Basic'" -and $source -match 'maxSizeBytes: 2147483648') 'SQL must stay bounded Basic/2GB.'
foreach ($required in @('requiresDuplicateDetection: true','maxDeliveryCount: 5','maxSizeInMegabytes: 1024',"duplicateDetectionHistoryTimeWindow: 'PT10M'","defaultMessageTimeToLive: 'PT1H'","skuObject: { name: 'Standard'","disableLocalAuth: true",'allowSharedKeyAccess: false')) {
  Assert-True ($source.Contains($required)) "Missing dependency security/cost bound: $required"
}
Assert-True ($source -match '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' -and
  $source -match '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' -and
  $source -notmatch '4f6f6a3e-6ca9-46f0-8f9e-3f925a769d3a') 'Queue must use the authoritative Service Bus Data Sender and Data Receiver built-in role IDs.'
Assert-True ($functionSource -match "runtime: \{ name: 'dotnet-isolated', version: '8.0' \}" -and $functionSource -match 'maximumInstanceCount: 40') 'Processor must use bounded .NET8 isolated Flex.'
foreach ($required in @('AzureWebJobsStorage__accountName','AzureWebJobsStorage__credential','AzureWebJobsStorage__clientId')) {
  Assert-True ($functionSource.Contains($required)) "Identity-based Functions host storage missing $required"
}
foreach ($required in @('OrdersBus__fullyQualifiedNamespace','OrdersBus__credential','OrdersBus__clientId')) {
  Assert-True ($source.Contains($required)) "Identity-based Service Bus trigger missing $required"
}
Assert-True ($source.Contains("CustomerOrdersQueueName: 'orders'") -and
  $source.Contains("CustomerDependencies__QueueName: 'orders'")) 'Worker requires the flat host binding setting alongside the unchanged hierarchical application setting.'
Assert-True ([regex]::Matches($customerSource, 'userAssignedResourceIds: empty\(customerIdentityId\)').Count -eq 2) 'Customer and broken slot must share the same dependency UAMI.'
Assert-True ($customerSource -match "module appSettings[\s\S]+?dependsOn:\s*\[site\]") 'Customer app settings must wait for the AVM site deployment to prevent first-deployment ResourceNotFound races.'
Assert-True ($source -match 'privateEndpointNetworkPolicies' -and $source -notmatch 'startIpAddress.*0\.0\.0\.0') 'SQL runtime access must use private networking, not a blanket Azure firewall.'

foreach ($entry in @('main','10-workloads')) {
  $compiledFile = Join-Path $CompiledDirectory "$entry.json"
  if (-not (Test-Path $compiledFile)) { $compiledFile = Join-Path $CompiledDirectory "stages\$entry.json" }
  $template = Get-Content $compiledFile -Raw | ConvertFrom-Json
  Assert-True ($template.parameters.enableCustomerDependencies.defaultValue -eq $false) "$entry must default dependencies off."
  $module = @($template.resources | Where-Object name -eq 'customer-dependencies')
  Assert-True ($module.Count -eq 1 -and $module[0].condition -match "and\(parameters\('enableCustomerDependencies'\), parameters\('enableSlotFailureScenario'\)\)") "$entry must gate every nested dependency behind both feature switches."
  Assert-ProcessorStorageContract $module[0].properties.template
  $appService = @($template.resources | Where-Object name -eq 'appservice')
  $customerSite = @($template.resources | Where-Object name -eq 'customer-webapp')
  Assert-True ($template.parameters.appServiceLocation.defaultValue -eq 'westeurope' -and
    $module[0].properties.parameters.location.value -eq "[parameters('appServiceLocation')]" -and
    $module[0].properties.parameters.location.value -eq $appService[0].properties.parameters.location.value -and
    $module[0].properties.parameters.location.value -eq $customerSite[0].properties.parameters.location.value) "$entry customer dependencies/VNet must stay co-located with the configured App Service region, independent of lab location."
  Assert-True (@($template.resources | Where-Object { $_.type -match 'Microsoft.Sql/servers|Microsoft.ServiceBus/namespaces' }).Count -eq 0) 'Disabled root must not instantiate SQL or Service Bus outside the conditional module.'
  Assert-True (@($template.outputs.PSObject.Properties).Count -le 64) 'ARM output limit exceeded.'
  $compiled = $module[0].properties.template | ConvertTo-Json -Depth 100
  Assert-True ($compiled -notmatch '"administratorLogin' -and $compiled -notmatch '"administratorLoginPassword') 'Compiled SQL must remain Entra-only.'
  Assert-True ($compiled -match '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' -and
    $compiled -notmatch '4f6f6a3e-6ca9-46f0-8f9e-3f925a769d3a') 'Compiled queue receiver assignment must use the authoritative built-in role ID.'
}
$health = Get-Content (Join-Path $root 'infra\modules\customer-health-model.bicep') -Raw
Assert-True ($health -match 'customerEdges' -and $health -match 'processor-errors' -and $health -match 'FunctionAppLogs' -and $health -match 'scope: customerLaw') 'Separate customer health graph must include real edges, processor error logs and scoped LAW reader.'
Assert-True ($health.Contains("{ parent: 'customer-webapp', child: 'customer-appservice-plan' }") -and
  $health -match "namespace: 'Microsoft.Web/serverfarms', metric: 'CpuPercentage'" -and
  $health -match 'Orders queue runtime \(Service Bus\)') 'Customer graph must expose its direct shared-plan dependency and identify the underlying queue runtime.'
Assert-True ($health -match "'hm-\$\{namePrefix\}-customer'" -and $health -match "metricName: 'Http5xx'" -and
  $health -notmatch 'OnDemandFunctionExecutionCount|scope: resourceGroup\(\)|db_owner' -and
  $health -match 'where Samples > 0' -and $health -match 'ignoreUnknown: false') 'Separate model must monitor customer failures, avoid broad grants/load-as-health, and retain unknown for unobserved hosts.'
Assert-True ($health.Contains("name: replace(item.metric, '_', '-')") -and
  $health.Contains('metricName: item.metric')) 'Logical signal names must normalize underscores without changing Azure metric names.'
$workloadHealth = Get-Content (Join-Path $root 'infra\modules\health-model.bicep') -Raw
Assert-True ($workloadHealth -notmatch 'customerWebAppId|customerEdges|customerLogReader|enableCustomerDependencies') 'Existing workload model must not contain customer extensions.'
foreach ($entry in @('main','stages\40-optional-advanced','customer-application')) {
  $template = Get-Content (Join-Path $root "infra\$entry.json") -Raw | ConvertFrom-Json
  $customerModel = @($template.resources | Where-Object name -eq 'customer-health-model')
  $workloadModel = @($template.resources | Where-Object name -eq 'health-model')
  Assert-True ($customerModel.Count -eq 1 -and $customerModel[0].condition -match 'enableCustomerDependencies') 'Dedicated customer model must be conditional.'
  foreach ($component in $customerModel[0].properties.template.variables.metricComponents) {
    Assert-True (($component.metric.Replace('_','-')) -cmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{1,258}[a-zA-Z0-9]$') "Invalid customer metric signal logical name: $($component.metric)"
  }
  $sqlMetric = @($customerModel[0].properties.template.variables.metricComponents | Where-Object key -eq 'customer-sql')
  Assert-True ($sqlMetric.Count -eq 1 -and $sqlMetric[0].metric -ceq 'dtu_consumption_percent') 'SQL Azure metric name must retain underscores.'
  if ($entry -eq 'customer-application') {
    $dependencies = @($template.resources | Where-Object name -eq 'customer-dependencies')
    Assert-ProcessorStorageContract $dependencies[0].properties.template
    Assert-True ($workloadModel.Count -eq 0 -and @($template.resources).Count -eq 2 -and
      @($template.resources | Where-Object type -ne 'Microsoft.Resources/deployments').Count -eq 0) 'Scoped wrapper must deploy only dependencies and dedicated customer model, never existing sites/plans or workload model.'
    Assert-True (@($template.resources | Where-Object { $_.condition -ne "[parameters('enableCustomerDependencies')]" }).Count -eq 0 -and
      $customerModel[0].dependsOn -match 'customer-dependencies') 'Both scoped modules must be conditional, with model creation ordered after dependency infrastructure.'
    Assert-True ($customerModel[0].properties.parameters.location.value -eq 'swedencentral' -and
      $customerModel[0].properties.parameters.customerWebAppId.value -match 'Microsoft.Web/sites' -and
      $customerModel[0].properties.parameters.customerAppServicePlanId.value -match 'Microsoft.Web/serverfarms') 'Scoped customer model must reference actual existing site/plan IDs and the supported preview region.'
    foreach ($parameter in @('customerSqlDatabaseId','customerServiceBusId','customerWorkerId','customerWorkerStorageId')) {
      Assert-True ($customerModel[0].properties.parameters.$parameter.value -match "customer-dependencies.*outputs") "Scoped customer model must take $parameter from dependency outputs."
    }
    Assert-True ($customerModel[0].properties.parameters.customerCentralLawId.value -eq "[parameters('centralLawId')]") 'Scoped model must use the explicitly selected central workspace.'
    foreach ($output in @('healthModelName','healthModelId','healthModelPrincipalId')) {
      Assert-True ($template.outputs.customerDependencies.value -match $output) "Scoped dependency context must include $output."
    }
    Assert-True ($template.outputs.customerDependencies.value -match 'union\(' -and
      $template.outputs.customerDependencies.value -match "createObject\('enabled', false\(\)\)") 'Scoped output must preserve existing dependency fields and disabled fallback.'
  } else {
    Assert-True ($workloadModel[0].properties.parameters.PSObject.Properties.Name -notcontains 'customerWebAppId') 'Workload model wiring must remain isolated.'
  }
  $roles = @($customerModel[0].properties.template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
  Assert-True ($roles.Count -eq 7 -and @($roles | Where-Object { $_.scope -notmatch 'Microsoft\.' }).Count -eq 0) 'Customer model must grant six component-scoped metric readers and one workspace log reader.'
  Assert-True ($customerModel[0].properties.template.variables.monitoringReader -eq '43d0d8ad-25c7-4714-9337-8ba259a9fe05' -and
    @($roles | Where-Object { $_.properties.roleDefinitionId -match "variables\('monitoringReader'\)" }).Count -eq 6) 'Each actual customer component must have Monitoring Reader.'
  Assert-True ($customerModel[0].properties.template.variables.logReader -eq '73c42c96-874c-492b-b04d-ab87d138a893' -and
    @($roles | Where-Object { $_.properties.roleDefinitionId -match "variables\('logReader'\)" }).Count -eq 1) 'Workspace Log Analytics Reader must be the only additional customer-model role.'
  if ($entry -ne 'customer-application') {
    $baseline = git -C $root show "HEAD:infra/$($entry.Replace('\','/')).json" | Out-String | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not load checked-in workload model baseline.' }
    $baselineWorkload = @($baseline.resources | Where-Object name -eq 'health-model')[0].properties.template | ConvertTo-Json -Depth 100 -Compress
    $actualWorkload = $workloadModel[0].properties.template | ConvertTo-Json -Depth 100 -Compress
    Assert-True ($actualWorkload -ceq $baselineWorkload) 'Compiled existing workload Health Model must remain exactly unchanged.'
  }
}
$bootstrap = Get-CustomerSqlBootstrap -CustomerClientId '11111111-2222-3333-4444-555555555555' -WorkerClientId '66666666-7777-8888-9999-aaaaaaaaaaaa'
foreach ($required in @('nvarchar(64)','nvarchar(128)','decimal(10,2)','uniqueidentifier','CreatedUtc datetime2','CompletedUtc datetime2 NULL',"'Pending'","'Queued'","'Completed'","'Failed'",'ALTER TABLE dbo.Orders DROP CONSTRAINT CK_Orders_Status','WITH SID=0x','TYPE=E','GRANT SELECT ON OBJECT::dbo.Products','GRANT SELECT, INSERT, UPDATE ON OBJECT::dbo.Orders','GRANT SELECT, UPDATE ON OBJECT::dbo.Orders')) {
  Assert-True ($bootstrap.Contains($required)) "Bootstrap schema/grant mismatch: $required"
}
Assert-True ($bootstrap -notmatch 'db_owner|db_datawriter|FROM EXTERNAL PROVIDER' -and $bootstrap -match 'IF DATABASE_PRINCIPAL_ID' -and $bootstrap -match 'MERGE dbo.Products') 'Bootstrap must be idempotent and use explicit SID users/object grants without Graph.'
Assert-True ($bootstrap -match '0x11111111222233334444555555555555' -and $bootstrap -match '0x66666666777788889999AAAAAAAAAAAA') 'SQL SID conversion must preserve GUID byte order.'
Assert-Throws { Get-CustomerSqlBootstrap -CustomerClientId ([guid]::Empty) -WorkerClientId ([guid]::NewGuid()) } 'Empty identity must be rejected.'

# Fake all Azure and SQL calls; exercise bounded writes, stale outputs and cleanup.
& {
  $sub = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  $tenant = [guid]'11111111-aaaa-bbbb-cccc-dddddddddddd'
  $base = "/subscriptions/$sub/resourceGroups/test-rg/providers"
  $context = @{
    enabled = $true; sqlServerName = 'sql-test'; sqlServerId = "$base/Microsoft.Sql/servers/sql-test"
    sqlDatabaseName = 'customer-orders'; sqlDatabaseId = "$base/Microsoft.Sql/servers/sql-test/databases/customer-orders"
    workerName = 'func-test-orders'; workerId = "$base/Microsoft.Web/sites/func-test-orders"
    serviceBusNamespace = 'sb-test.servicebus.windows.net'; serviceBusNamespaceId = "$base/Microsoft.ServiceBus/namespaces/sb-test"
    queueName = 'orders'; customerIdentityClientId = '11111111-2222-3333-4444-555555555555'
    workerIdentityClientId = '66666666-7777-8888-9999-aaaaaaaaaaaa'
  }
  $fixture = @{ Calls = [Collections.Generic.List[string]]::new(); Enabled = $true; SqlFails = $false; SqlCalls = 0; PublishCalls = 0; BadProducts = $false }
  function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    $fixture.Calls.Add($command)
    if ($command -like 'account show*') { return @{id=$sub.ToString();tenantId=$tenant.ToString()} | ConvertTo-Json }
    if ($command -like 'deployment group show*') {
      return @{parameters=@{enableCustomerDependencies=@{value=$fixture.Enabled}};outputs=@{
        customerDependencies=@{value=$context};customerWebAppName=@{value='app-test-customer'};webAppName=@{value='app-test'}
      }} | ConvertTo-Json -Depth 8
    }
    if ($command -like 'account get-access-token*') { return 'in-memory-test-token' }
    if ($command -like 'webapp show*') { return @{host='app-test-customer.azurewebsites.net';state='Running'} | ConvertTo-Json }
    if ($command -like 'servicebus queue show*') { return @{status='Active';maxDeliveryCount=5;requiresDuplicateDetection=$true} | ConvertTo-Json }
    if ($command -like 'functionapp function list*') { return '[{"name":"OrdersProcessor"}]' }
    if ($command -like 'functionapp deployment source config-zip*') { return }
    if ($command -like 'sql server firewall-rule*' -or $command -like 'webapp config appsettings set*' -or $command -like 'functionapp config appsettings set*') { return }
    if ($command -like 'webapp restart*' -or $command -like 'functionapp restart*') { return }
    throw "Unexpected Azure command: $command"
  }
  function Invoke-Sqlcmd {
    param($ConnectionString,$AccessToken,$Query,$QueryTimeout,[switch]$AbortOnError)
    $fixture.SqlCalls++
    Assert-True ($AccessToken -eq 'in-memory-test-token' -and $Query -match 'TYPE=E' -and $QueryTimeout -eq 60) 'SQL bootstrap lost token/grant/time bound.'
    if ($fixture.SqlFails) { throw 'Simulated SQL failure' }
  }
  function Invoke-RestMethod {
    param($Uri, $TimeoutSec)
    Assert-True ($Uri -eq 'https://app-test-customer.azurewebsites.net/api/customer/products' -and $TimeoutSec -eq 20) 'Readiness must query only the dedicated customer catalogue with a bounded timeout.'
    if ($fixture.BadProducts) { return @{ enabled = $false } }
    return @('monitoring-starter','agent-operations','sre-command') | ForEach-Object { @{id=$_} }
  }
  function dotnet {
    $fixture.PublishCalls++
    Assert-True ($args[0] -eq 'publish' -and $args[1] -like '*customer-processor\CustomerProcessor.csproj') 'Lifecycle must publish the approved isolated processor project.'
    $output = $args[[array]::IndexOf($args, '--output') + 1]
    '{}' | Set-Content (Join-Path $output 'host.json')
    '[]' | Set-Content (Join-Path $output 'functions.metadata')
    $global:LASTEXITCODE = 0
  }
  $common = @{ SubscriptionId=$sub;TenantId=$tenant;ResourceGroup='test-rg';DeploymentName='test-deployment';Confirm=$false }
  & (Join-Path $root 'scripts\bootstrap-customer-sql.ps1') @common -ConfirmTarget $context.sqlDatabaseId -ApproveTemporaryFirewall -OperatorIpv4 '203.0.113.7'
  Assert-True ($fixture.SqlCalls -eq 1 -and @($fixture.Calls | Where-Object {$_ -like 'sql server firewall-rule delete*'}).Count -eq 1) 'Bootstrap must clean its exact temporary firewall rule.'
  $fixture.SqlFails = $true
  Assert-Throws { & (Join-Path $root 'scripts\bootstrap-customer-sql.ps1') @common -ConfirmTarget $context.sqlDatabaseId -ApproveTemporaryFirewall -OperatorIpv4 '203.0.113.7' } 'SQL failure must propagate.'
  Assert-True (@($fixture.Calls | Where-Object {$_ -like 'sql server firewall-rule delete*'}).Count -eq 2) 'SQL failure must still delete its firewall rule.'
  Assert-Throws { & (Join-Path $root 'scripts\deploy-customer-dependencies.ps1') @common -ConfirmTarget $context.workerId } 'Lifecycle must fail before publication if SQL bootstrap fails.'
  Assert-True ($fixture.PublishCalls -eq 0) 'SQL bootstrap failure must not publish the worker.'
  $fixture.SqlFails = $false
  $sqlBeforeWhatIf = $fixture.SqlCalls
  $writesBeforeWhatIf = @($fixture.Calls | Where-Object { $_ -match 'firewall-rule (create|delete)|appsettings set|deployment source config-zip' }).Count
  & (Join-Path $root 'scripts\deploy-customer-dependencies.ps1') @common -ConfirmTarget $context.workerId -WhatIf
  Assert-True ($fixture.SqlCalls -eq $sqlBeforeWhatIf -and $fixture.PublishCalls -eq 0 -and
    @($fixture.Calls | Where-Object { $_ -match 'firewall-rule (create|delete)|appsettings set|deployment source config-zip' }).Count -eq $writesBeforeWhatIf) 'WhatIf lifecycle must perform only read-only target checks.'
  & (Join-Path $root 'scripts\deploy-customer-dependencies.ps1') @common -ConfirmTarget $context.workerId
  Assert-True ($fixture.PublishCalls -eq 1 -and @($fixture.Calls | Where-Object { $_ -match 'deployment source config-zip.*--build-remote false' }).Count -eq 1) 'Lifecycle must upload exactly one prebuilt worker ZIP after SQL bootstrap.'
  $fixture.BadProducts = $true
  $readOnly = @{SubscriptionId=$sub;TenantId=$tenant;ResourceGroup='test-rg';DeploymentName='test-deployment'}
  Assert-Throws { & (Join-Path $root 'scripts\test-customer-dependencies.ps1') @readOnly } 'Readiness must reject a disabled/noncatalogue response.'
  Assert-Throws { & (Join-Path $root 'scripts\bootstrap-customer-sql.ps1') @common -ConfirmTarget $context.sqlDatabaseId -ApproveTemporaryFirewall -OperatorIpv4 '0.0.0.0' } 'Blanket firewall must be rejected.'
  Assert-Throws { & (Join-Path $root 'scripts\set-customer-dependency-fault.ps1') @common -Fault SqlDelay -SqlDelaySeconds 6 -ConfirmTarget "$base/Microsoft.Web/sites/app-test-customer" } 'SQL fault must reject delay above 5 seconds.'
  Assert-Throws { & (Join-Path $root 'scripts\set-customer-dependency-fault.ps1') @common -Fault WorkerFailure -ConfirmTarget "$base/Microsoft.Web/sites/app-test" } 'Faults must reject Control Center target.'
  & (Join-Path $root 'scripts\set-customer-dependency-fault.ps1') @common -Fault Recover -ConfirmTarget "$base/Microsoft.Web/sites/app-test-customer"
  Assert-True (@($fixture.Calls | Where-Object {$_ -match 'CustomerDependencies__SqlDelaySeconds=0'}).Count -eq 2 -and @($fixture.Calls | Where-Object {$_ -match 'CustomerDependencies__FailProcessing=false'}).Count -eq 1) 'Recovery must reset both customer slots and worker fault settings.'
  $fixture.Enabled = $false
  Assert-Throws { & (Join-Path $root 'scripts\set-customer-dependency-fault.ps1') @common -Fault Recover -ConfirmTarget "$base/Microsoft.Web/sites/app-test-customer" } 'Disabled deployment must reject stale dependency output authorization.'
  Assert-True (@($fixture.Calls | Where-Object {$_ -match 'restart.*--name (app-test-customer|func-test-orders)( |$)'}).Count -eq 3) 'Recovery must restart both exact customer slots and the worker to apply environment changes.'
  Assert-True (@($fixture.Calls | Where-Object {$_ -match 'account set|login|stop|delete.*database|0.0.0.0'}).Count -eq 0) 'Dependency lifecycle must not change auth context or stop/delete arbitrary resources.'
}
Write-Output 'PASS: default-off infrastructure/security contracts, SID/schema/bootstrap, SQL-first worker ZIP lifecycle, WhatIf/no-writes, readiness, exact fault recovery and firewall cleanup (mocked; no Azure calls).'
