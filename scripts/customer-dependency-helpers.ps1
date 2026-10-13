function Get-CustomerDependencyContext {
  param(
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][guid] $TenantId,
    [Parameter(Mandatory)][string] $ResourceGroup,
    [Parameter(Mandatory)][string] $DeploymentName
  )
  $account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
    throw 'Customer dependency operation requires the already-selected expected subscription and tenant. No account selection was changed.'
  }
  $outputs = az deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $DeploymentName `
    --query '{outputs:properties.outputs,parameters:properties.parameters}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to resolve the specified lab deployment.'
  }
  $deployment = $outputs
  $outputs = $deployment.outputs
  if ($deployment.parameters.enableCustomerDependencies.value -ne $true) {
    throw 'Customer dependencies are disabled in the specified deployment; stale module outputs must not authorize writes.'
  }
  $context = $outputs.customerDependencies.value
  if (-not $context) {
    $moduleOutput = az deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name customer-dependencies `
      --query properties.outputs.customerDependencies.value --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0) { $context = $moduleOutput }
  }
  if (-not $context.enabled) {
    throw 'Customer dependencies are not enabled in this deployment.'
  }
  $customerName = $outputs.customerWebAppName.value
  $controlName = $outputs.webAppName.value
  if (-not $controlName) { $controlName = $customerName -replace '-customer$', '' }
  if (-not $customerName -or $customerName -cne "$controlName-customer") { throw 'Expected dedicated customer app output is missing.' }
  $base = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers"
  foreach ($item in @(
    @{ Id = $context.sqlServerId; Expected = "$base/Microsoft.Sql/servers/$($context.sqlServerName)" },
    @{ Id = $context.sqlDatabaseId; Expected = "$base/Microsoft.Sql/servers/$($context.sqlServerName)/databases/customer-orders" },
    @{ Id = $context.workerId; Expected = "$base/Microsoft.Web/sites/$($context.workerName)" },
    @{ Id = $context.serviceBusNamespaceId; Expected = "$base/Microsoft.ServiceBus/namespaces/$($context.serviceBusNamespace -replace '\.servicebus\.windows\.net$','')" }
  )) {
    if ($item.Id -ine $item.Expected) { throw "Unexpected customer dependency resource ID: $($item.Id)" }
  }
  if ($context.queueName -cne 'orders' -or $context.sqlDatabaseName -cne 'customer-orders') { throw 'Unexpected database or queue target.' }
  $context | Add-Member -NotePropertyName CustomerWebAppName -NotePropertyValue $customerName -Force
  $context | Add-Member -NotePropertyName CustomerWebAppId -NotePropertyValue "$base/Microsoft.Web/sites/$customerName" -Force
  return $context
}

function Get-CustomerSqlBootstrap {
  param([Parameter(Mandatory)][guid] $CustomerClientId, [Parameter(Mandatory)][guid] $WorkerClientId)
  if ($CustomerClientId -eq [guid]::Empty -or $WorkerClientId -eq [guid]::Empty -or $CustomerClientId -eq $WorkerClientId) {
    throw 'Distinct nonzero customer and worker managed identity client IDs are required.'
  }
  # SQL external principal SIDs use the application/client ID, not object ID.
  $customerSid = '0x' + [Convert]::ToHexString($CustomerClientId.ToByteArray())
  $workerSid = '0x' + [Convert]::ToHexString($WorkerClientId.ToByteArray())
  return @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID(N'dbo.Products', N'U') IS NULL
  CREATE TABLE dbo.Products (Id nvarchar(64) NOT NULL PRIMARY KEY, Name nvarchar(128) NOT NULL, Price decimal(10,2) NOT NULL);
IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
  CREATE TABLE dbo.Orders (Id uniqueidentifier NOT NULL PRIMARY KEY, ProductId nvarchar(64) NOT NULL REFERENCES dbo.Products(Id),
    Status nvarchar(32) NOT NULL CONSTRAINT CK_Orders_Status CHECK (Status IN (N'Pending',N'Queued',N'Completed',N'Failed')),
    CreatedUtc datetime2 NOT NULL, CompletedUtc datetime2 NULL);
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'dbo.Orders') AND name=N'CK_Orders_Status'
    AND definition NOT LIKE N'%Failed%')
BEGIN
  ALTER TABLE dbo.Orders DROP CONSTRAINT CK_Orders_Status;
  ALTER TABLE dbo.Orders ADD CONSTRAINT CK_Orders_Status CHECK (Status IN (N'Pending',N'Queued',N'Completed',N'Failed'));
END;
MERGE dbo.Products WITH (HOLDLOCK) AS target
USING (VALUES (N'monitoring-starter',N'Monitoring Starter',CAST(49 AS decimal(10,2))),
  (N'agent-operations',N'Agent Operations',CAST(89 AS decimal(10,2))),
  (N'sre-command',N'SRE Command',CAST(129 AS decimal(10,2)))) AS source(Id,Name,Price)
ON target.Id=source.Id
WHEN NOT MATCHED THEN INSERT(Id,Name,Price) VALUES(source.Id,source.Name,source.Price);
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'customer_runtime' AND (sid <> $customerSid OR type <> 'E'))
  THROW 50001, 'Existing customer_runtime identity differs; do not replace an unknown principal.', 1;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'orders_processor' AND (sid <> $workerSid OR type <> 'E'))
  THROW 50002, 'Existing orders_processor identity differs; do not replace an unknown principal.', 1;
IF DATABASE_PRINCIPAL_ID(N'customer_runtime') IS NULL CREATE USER [customer_runtime] WITH SID=$customerSid, TYPE=E;
IF DATABASE_PRINCIPAL_ID(N'orders_processor') IS NULL CREATE USER [orders_processor] WITH SID=$workerSid, TYPE=E;
GRANT SELECT ON OBJECT::dbo.Products TO [customer_runtime];
GRANT SELECT, INSERT, UPDATE ON OBJECT::dbo.Orders TO [customer_runtime];
GRANT SELECT, UPDATE ON OBJECT::dbo.Orders TO [orders_processor];
COMMIT;
"@
}
