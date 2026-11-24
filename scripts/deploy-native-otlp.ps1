[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $TenantId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $VmName,
  [Parameter(Mandatory)] [string] $DcrId,
  [Parameter(Mandatory)] [string] $DcrImmutableId,
  [Parameter(Mandatory)] [string] $DceEndpoint,
  [switch] $Enable
)
$ErrorActionPreference = 'Stop'
if (-not $Enable) { throw 'Native OTLP Collector installation is default-off. Pass -Enable only for the explicit native OTLP opt-in.' }
. (Join-Path $PSScriptRoot 'telemetry-ingestion-helpers.ps1')
$subscription = [guid]::Empty
$tenant = [guid]::Empty
if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty -or
    -not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or
    $ResourceGroup -notmatch '^[a-zA-Z0-9_.()-]{1,90}$' -or
    $VmName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$') {
  throw 'Invalid native OTLP target subscription, tenant, resource group, or VM.'
}
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$vmId = "$rgId/providers/Microsoft.Compute/virtualMachines/$VmName"
if ($DcrId -notmatch ('^' + [regex]::Escape("$rgId/providers/Microsoft.Insights/dataCollectionRules/") + '[a-zA-Z0-9-]+$') -or
    $DcrImmutableId -notmatch '^dcr-[a-zA-Z0-9-]+$') {
  throw 'Native OTLP DCR must be an exact resource in the lab group with a deployed immutable ID.'
}
$endpointUri = $null
if (-not [Uri]::TryCreate($DceEndpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
    $endpointUri.Scheme -ne 'https' -or $endpointUri.UserInfo -or
    $endpointUri.Query -or $endpointUri.Fragment -or $endpointUri.AbsolutePath -ne '/' -or
    -not $endpointUri.IsDefaultPort -or $endpointUri.Host -notmatch '^[a-zA-Z0-9.-]+\.ingest\.monitor\.azure\.com$') {
  throw 'Native OTLP DCE must have a credential-free HTTPS logs ingestion account endpoint.'
}
$targetPath = Join-Path $PSScriptRoot '..\.azure-target.json'
if (-not (Test-Path -LiteralPath $targetPath)) { throw '.azure-target.json is mandatory for native OTLP bootstrap.' }
$target = Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json
if ($target.expectedSubscriptionId -ine $SubscriptionId -or $target.expectedTenantId -ine $TenantId -or
    @($target.forbiddenSubscriptionIds) -contains $SubscriptionId) { throw 'Native OTLP target is not allowed by .azure-target.json.' }
$account = Assert-TelemetryIngestionTarget -SubscriptionId $SubscriptionId
if ($account.tenantId -ine $TenantId) { throw 'Azure account tenant does not match the native OTLP target.' }

function Read-Az([string[]] $Cli, [string] $What) {
  $json = & az @Cli
  if ($LASTEXITCODE -ne 0 -or -not ($json -join '').Trim()) { throw "$What failed or returned no data." }
  $json | ConvertFrom-Json -NoEnumerate
}

$vm = Read-Az @('vm','show','--subscription',$SubscriptionId,'-g',$ResourceGroup,'-n',$VmName,'-o','json') 'Reading the native OTLP VM'
if ($vm.id -ine $vmId -or -not $vm.location -or $vm.storageProfile.osDisk.osType -ne 'Linux' -or
    $vm.storageProfile.imageReference.publisher -ine 'Canonical' -or
    $vm.storageProfile.imageReference.offer -notmatch 'ubuntu.*22|jammy' -or
    $vm.storageProfile.imageReference.sku -notmatch '22_04|22\.04' -or
    $vm.identity.type -notmatch 'SystemAssigned' -or -not $vm.identity.principalId) {
  throw 'Native OTLP requires the exact lab Ubuntu 22.04 VM with a system-assigned identity.'
}
$instance = (Read-Az @('vm','get-instance-view','--subscription',$SubscriptionId,'-g',$ResourceGroup,'-n',$VmName,'-o','json') 'Native OTLP VM status').instanceView
if (@($instance.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1 -or
    @($instance.vmAgent.statuses | Where-Object code -EQ 'ProvisioningState/succeeded').Count -ne 1) {
  throw 'Native OTLP VM or VM agent is not ready.'
}
$dcr = Read-Az @('resource','show','--ids',$DcrId,'--api-version','2024-03-11','--subscription',$SubscriptionId,'-o','json') 'Native OTLP DCR'
if ($dcr.id -ine $DcrId -or $dcr.location -ine $vm.location -or
    $dcr.properties.immutableId -cne $DcrImmutableId -or
    $dcr.properties.provisioningState -ne 'Succeeded' -or
    @($dcr.properties.directDataSources.otelLogs | Where-Object { $_.streams -contains 'Microsoft-OTel-Logs' }).Count -ne 1 -or
    @($dcr.properties.dataFlows | Where-Object { $_.streams -contains 'Microsoft-OTel-Logs' -and $_.destinations -contains 'nativeLogs' }).Count -ne 1) {
  throw 'Native OTLP DCR identity, direct OTel logs source, or destination is not ready.'
}
$dceId = [string]$dcr.properties.dataCollectionEndpointId
if ($dceId -notmatch ('^' + [regex]::Escape("$rgId/providers/Microsoft.Insights/dataCollectionEndpoints/") + '[a-zA-Z0-9-]+$')) {
  throw 'Native OTLP DCR is not bound to the lab DCE.'
}
$dce = Read-Az @('resource','show','--ids',$dceId,'--api-version','2023-03-11','--subscription',$SubscriptionId,'-o','json') 'Native OTLP DCE'
if ($dce.id -ine $dceId -or $dce.location -ine $vm.location -or
    -not $dce.properties.logsIngestion.endpoint -or
    $dce.properties.logsIngestion.endpoint.TrimEnd('/') -ine $DceEndpoint.TrimEnd('/')) {
  throw 'Native OTLP DCE endpoint differs from the deployed output.'
}
$endpoint = "$($DceEndpoint.TrimEnd('/'))/datacollectionRules/$DcrImmutableId/streams/Microsoft-OTLP-Logs/otlp/v1/logs"
$asset = Join-Path $PSScriptRoot '..\workloads\telemetry-ingestion\otel\install-collector.sh'
$collectorConfig = Join-Path $PSScriptRoot '..\workloads\telemetry-ingestion\otel\collector.yaml'
if (-not (Test-Path -LiteralPath $asset) -or -not (Test-Path -LiteralPath $collectorConfig)) { throw 'Native OTLP Collector assets are missing.' }
$config = Get-Content -LiteralPath $collectorConfig -Raw
if ($config -notmatch 'endpoint: 127\.0\.0\.1:4318' -or
    $config -notmatch 'logs_endpoint: \$\{env:AZURE_MONITOR_OTLP_LOGS_ENDPOINT\}' -or
    $config -notmatch 'managed_identity: \{\}') { throw 'Native OTLP Collector config is not the approved loopback/managed-identity profile.' }
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($config)).TrimEnd('=').Replace('+','-').Replace('/','_')
function Invoke-Collector([string] $Mode) {
  $responseJson = & az vm run-command invoke --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name $VmName --command-id RunShellScript --scripts "@$asset" `
    --parameters $Mode $vmId $endpoint $encoded -o json
  if ($LASTEXITCODE -ne 0) { throw "Native OTLP VM $Mode failed; no success was inferred from the command output." }
  $response = $responseJson | ConvertFrom-Json -NoEnumerate
  $marker = if ($Mode -eq 'preflight') { 'OTLP_COLLECTOR_PREFLIGHT_OK' } else { 'OTLP_COLLECTOR_INSTALL_OK' }
  if (@($response.value | Where-Object { $_.code -notmatch '/succeeded$' }).Count -ne 0 -or
      @($response.value | Where-Object { $_.message -match "(?m)^$marker`r?$" }).Count -ne 1 -or
      @($response.value | Where-Object { $_.message -match '(?m)^OTLP_COLLECTOR_DENIED\r?$' }).Count -ne 0) {
    throw "Native OTLP VM $Mode did not return its exact success marker."
  }
}
Invoke-Collector preflight
$roles = @(Read-Az @('role','assignment','list','--subscription',$SubscriptionId,'--scope',$DcrId,
  '--assignee-object-id',$vm.identity.principalId,'-o','json') 'Native OTLP publisher grants')
$publisherRole = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"
if (@($roles | Where-Object { $_.scope -ieq $DcrId -and $_.roleDefinitionId -ieq $publisherRole }).Count -eq 0) {
  $null = & az role assignment create --subscription $SubscriptionId --scope $DcrId `
    --assignee-object-id $vm.identity.principalId --assignee-principal-type ServicePrincipal `
    --role $publisherRole -o none
  if ($LASTEXITCODE -ne 0) { throw 'Native OTLP VM identity could not receive the publisher role on its exact DCR.' }
}
Invoke-Collector install
Write-Output ([pscustomobject]@{
  Collector = 'http://127.0.0.1:4318/v1/logs (on lab Linux VM only)'
  NativeDcrId = $DcrId
  LiveIngestion = 'NOT VERIFIED: run a bounded OTLP fixture through an approved loopback port forward and query exact OTelLogs IDs'
})
