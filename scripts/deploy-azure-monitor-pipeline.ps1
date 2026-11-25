[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $TenantId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $VmName,
  [Parameter(Mandatory)] [string] $NamePrefix,
  [Parameter(Mandatory)] [string] $Location,
  [Parameter(Mandatory)] [string] $CentralLawId,
  [switch] $Enable,
  [switch] $EnableCombined,
  [switch] $StageTelemetryIngestionEnabled,
  [switch] $StageAzureMonitorPipelineEnabled
)
$ErrorActionPreference = 'Stop'
if (-not $Enable) { throw 'Azure Monitor pipeline bootstrap is default-off. Pass -Enable only after approving VM changes and preview costs.' }
if ($EnableCombined -and (-not $StageTelemetryIngestionEnabled -or -not $StageAzureMonitorPipelineEnabled)) {
  throw 'Combined Syslog routing requires both stageToggles.enableStageTelemetryIngestion and enableStageAzureMonitorPipeline.'
}

. (Join-Path $PSScriptRoot 'telemetry-ingestion-helpers.ps1')
foreach ($guidText in @($SubscriptionId, $TenantId)) {
  $parsed = [guid]::Empty
  if (-not [guid]::TryParseExact($guidText, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
    throw 'SubscriptionId and TenantId must be nonempty GUIDs.'
  }
}
if ($ResourceGroup -notmatch '^[\w.()-]{1,90}$' -or
    $VmName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$' -or
    $NamePrefix -notmatch '^[a-z][a-z0-9-]{0,32}$' -or
    $Location -notmatch '^[a-z0-9]+$') { throw 'Invalid resource group, VM, prefix, or location.' }
$clusterName = "$NamePrefix-edge"
if ($clusterName.Length -gt 63) { throw 'Arc cluster name exceeds 63 characters.' }
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$vmId = "$rgId/providers/Microsoft.Compute/virtualMachines/$VmName"
$clusterId = "$rgId/providers/Microsoft.Kubernetes/connectedClusters/$clusterName"
$extensionId = "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/azure-monitor-pipeline"
$associationNames = @{
  settings = "pipelineSettings-$NamePrefix-settings-assoc"
  syslog = "$NamePrefix-flow-assoc"
  operational = "$NamePrefix-operational-assoc"
  diagnostic = "$NamePrefix-diagnostic-assoc"
}
$lawPattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId) +
  '/resourceGroups/' + [regex]::Escape($ResourceGroup) +
  '/providers/Microsoft\.OperationalInsights/workspaces/[a-zA-Z0-9-]+$'
if ($CentralLawId -notmatch $lawPattern) { throw 'CentralLawId must be a workspace in this subscription and resource group.' }
$targetPath = Join-Path $PSScriptRoot '..\.azure-target.json'
if (-not (Test-Path -LiteralPath $targetPath)) { throw '.azure-target.json is mandatory for VM bootstrap.' }
$target = Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json
if ($target.expectedSubscriptionId -ine $SubscriptionId -or $target.expectedTenantId -ine $TenantId -or
    @($target.forbiddenSubscriptionIds) -contains $SubscriptionId) { throw 'Selected target is not allowed by .azure-target.json.' }
$account = Assert-TelemetryIngestionTarget -SubscriptionId $SubscriptionId
if ($account.tenantId -ine $TenantId) { throw 'Azure account tenant does not match TenantId.' }

function Read-Az {
  param([string[]] $Cli, [string] $What)
  $value = & az @Cli
  if ($LASTEXITCODE -ne 0) { throw "$What failed. No later stage was attempted." }
  if (-not ($value -join '').Trim()) { throw "$What returned no data." }
  $value | ConvertFrom-Json
}
function Assert-Permission {
  param([object] $Permissions, [string] $Action)
  $matched = $false
  foreach ($item in @($Permissions)) {
    foreach ($pattern in @($item.actions)) {
      if ($Action -like $pattern) {
        $excluded = @($item.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if (-not $excluded) { $matched = $true }
      }
    }
  }
  if (-not $matched) { throw "Required ARM permission could not be proven: $Action" }
}
function Assert-Provider {
  param([string] $Namespace, [string] $Type)
  $provider = Read-Az @('provider','show','--namespace',$Namespace,'--subscription',$SubscriptionId,'-o','json') "Provider $Namespace"
  if ($provider.registrationState -ne 'Registered') {
    Write-Host "Registering $Namespace for the Azure Monitor pipeline opt-in..."
    & az provider register --namespace $Namespace --subscription $SubscriptionId --wait --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Registration of $Namespace failed; check subscription provider-registration permissions." }
    $provider = Read-Az @('provider','show','--namespace',$Namespace,'--subscription',$SubscriptionId,'-o','json') "Provider $Namespace after registration"
    if ($provider.registrationState -ne 'Registered') { throw "$Namespace is not registered after the registration request." }
  }
  if ($Type) {
    $resource = @($provider.resourceTypes | Where-Object resourceType -EQ $Type)
    if ($resource.Count -ne 1 -or
        @($resource[0].locations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '').ToLowerInvariant() -eq $Location }).Count -eq 0) {
      throw "$Namespace/$Type is not advertised in $Location."
    }
  }
}
function Assert-Extension {
  param([object[]] $Existing, [string] $Name, [string] $Type)
  $item = @($Existing | Where-Object { $_.name -ieq $Name -or $_.id -ieq "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/$Name" })
  if ($item.Count -gt 1) { throw "Ambiguous extension $Name." }
  if ($item.Count -eq 1 -and ($item[0].id -ine "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/$Name" -or
      $item[0].properties.extensionType -ine $Type -or
      $item[0].properties.provisioningState -ne 'Succeeded' -or
      ($Type -eq 'microsoft.certmanagement' -and
        ($item[0].properties.releaseTrain -ne 'stable' -or $item[0].properties.autoUpgradeMinorVersion -ne $true)) -or
      ($Type -eq 'microsoft.monitor.pipeline' -and
        ($item[0].properties.version -ne '0.1.7' -or $item[0].identity.type -ne 'SystemAssigned' -or
          $item[0].properties.releaseTrain -ne 'preview' -or $item[0].properties.autoUpgradeMinorVersion -ne $false)))) {
    throw "Existing extension $Name is foreign, failed, or not pinned; refusing to overwrite it (ID=$($item[0].id), type=$($item[0].properties.extensionType), state=$($item[0].properties.provisioningState))."
  }
}
function Invoke-Remote {
  param([string] $Mode, [bool] $ArcAlreadyOwned)
  $scriptFile = Join-Path $PSScriptRoot '..\workloads\telemetry-ingestion\edge\install-k3s-arc.sh'
  if (-not (Test-Path -LiteralPath $scriptFile)) { throw 'Remote install asset is missing.' }
  $result = & az vm run-command invoke --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name $VmName --command-id RunShellScript --scripts "@$scriptFile" `
    --parameters $Mode $SubscriptionId $TenantId $ResourceGroup $clusterName $Location `
    $vmId $ArcAlreadyOwned.ToString().ToLowerInvariant() -o json
  if ($LASTEXITCODE -ne 0) { throw "Remote $Mode failed; inspect VM Run Command status without printing its payload." }
  $response = $result | ConvertFrom-Json -NoEnumerate
  $messages = @($response.value | ForEach-Object message)
  $marker = if ($Mode -eq 'preflight') { 'PIPELINE_PREFLIGHT_OK' } else { 'PIPELINE_INSTALL_OK' }
  $denials = @($messages | Where-Object { $_ -match '(?m)^PIPELINE_DENIED(?::[a-z-]+)?\r?$' })
  $reasonPattern = if ($Mode -eq 'preflight') {
    '(?m)^PIPELINE_DENIED:(arguments|inputs|host|os|cpu|memory|disk|commands|ama|ports|ownership|k3s|checksum)\r?$'
  } else {
    '(?m)^PIPELINE_DENIED:(packages|connectedk8s|helm|k3s-download|k3s-network|k3s-service|k3s-config|k3s-ready|ama|identity-login|identity-account|identity-tenant|arc-connect)\r?$'
  }
  if ($denials.Count -eq 1 -and
      @($response.value | Where-Object { $_.code -notmatch '/succeeded$' }).Count -eq 0 -and
      @($messages | Where-Object { $_ -match "(?m)^$marker`r?$" }).Count -eq 0 -and
      $denials[0] -match $reasonPattern) {
    throw "Remote $Mode denied: $($Matches[1]). No later stage was attempted."
  }
  if (@($response.value | Where-Object { $_.code -notmatch '/succeeded$' }).Count -ne 0 -or
      @($messages | Where-Object { $_ -match "(?m)^$marker`r?$" }).Count -ne 1 -or
      $denials.Count -ne 0) {
    throw "Remote $Mode did not return its exact success marker; no later stage was attempted."
  }
}

# All cloud reads and permission/availability checks precede the first Run Command.
$vm = Read-Az @('vm','show','--subscription',$SubscriptionId,'-g',$ResourceGroup,'-n',$VmName,'-o','json') 'Reading the selected VM'
if ($vm.id -ine $vmId -or $vm.location -ine $Location -or
    $vm.storageProfile.osDisk.osType -ne 'Linux' -or
    $vm.storageProfile.imageReference.publisher -ine 'Canonical' -or
    $vm.storageProfile.imageReference.offer -notmatch 'ubuntu.*22|jammy' -or
    $vm.storageProfile.imageReference.sku -notmatch '22_04|22\.04' -or
    $vm.identity.type -notmatch 'SystemAssigned' -or -not $vm.identity.principalId) {
  throw 'VM identity, exact ID, Ubuntu 22.04 image, location, or system-assigned identity could not be verified.'
}
$size = $vm.hardwareProfile.vmSize
$skus = @(Read-Az @('vm','list-skus','--subscription',$SubscriptionId,'--location',$Location,
  '--size',$size,'--all','-o','json') 'VM SKU capability')
$sku = @($skus | Where-Object { $_.name -eq $size -and $_.resourceType -eq 'virtualMachines' -and -not $_.restrictions })
if ($sku.Count -ne 1) { throw 'VM SKU is restricted or its capacity could not be verified; resize manually before retrying.' }
$caps = @{}
foreach ($cap in $sku[0].capabilities) { $caps[$cap.name] = $cap.value }
if ([int]$caps.vCPUs -lt 4 -or [double]$caps.MemoryGB -lt 16) {
  throw 'Selected VM SKU requires at least 4 vCPU and 16 GiB; no automatic resize is performed.'
}
$instance = (Read-Az @('vm','get-instance-view','--subscription',$SubscriptionId,'-g',$ResourceGroup,'-n',$VmName,'-o','json') 'VM instance view').instanceView
if (@($instance.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1 -or
    @($instance.statuses | Where-Object code -EQ 'ProvisioningState/succeeded').Count -ne 1 -or
    @($instance.vmAgent.statuses | Where-Object code -EQ 'ProvisioningState/succeeded').Count -ne 1) {
  throw 'VM is not running, provisioned, and VM Agent ready.'
}
$law = Read-Az @('resource','show','--ids',$CentralLawId,'--subscription',$SubscriptionId,'-o','json') 'Central workspace'
if ($law.id -ine $CentralLawId -or $law.location -ine $Location -or
    $law.type -ine 'Microsoft.OperationalInsights/workspaces') { throw 'Central workspace ID, type, or location mismatch.' }
if ($EnableCombined) {
  $requiredColumns = [ordered]@{
    TimeGenerated = 'datetime'; RunId = 'string'; EventId = 'string'
    SampleSetId = 'string'; Severity = 'string'; NormalizedSeverity = 'string'
    Workload = 'string'; Message = 'string'; SyntheticUser = 'string'
  }
  foreach ($tableName in @('TelemetryIngestionOperational_CL','TelemetryIngestionDiagnostic_CL')) {
    $tableId = "$CentralLawId/tables/$tableName"
    $table = Read-Az @('resource','show','--ids',$tableId,'--subscription',$SubscriptionId,'-o','json') "Stage90 table $tableName"
    $columns = @($table.properties.schema.columns)
    if ($table.id -ine $tableId -or
        ($table.type -and $table.type -ine 'Microsoft.OperationalInsights/workspaces/tables') -or
        $table.properties.plan -ine 'Analytics' -or $table.properties.schema.name -cne $tableName -or
        $columns.Count -ne $requiredColumns.Count) {
      throw "Stage90 table $tableName is absent, not Analytics, or has the wrong schema."
    }
    foreach ($column in $columns) {
      if (-not $requiredColumns.Contains([string]$column.name) -or
          $requiredColumns[[string]$column.name] -cne [string]$column.type) {
        throw "Stage90 table $tableName has the wrong schema."
      }
    }
  }
}
Assert-Provider Microsoft.Kubernetes connectedClusters
Assert-Provider Microsoft.KubernetesConfiguration extensions
Assert-Provider Microsoft.ExtendedLocation ''
Assert-Provider Microsoft.Insights dataCollectionRules
Assert-Provider Microsoft.Insights dataCollectionRuleAssociations
$extensionTypesFeature = Read-Az @('feature','show','--namespace','Microsoft.KubernetesConfiguration',
  '--name','ExtensionTypes','--subscription',$SubscriptionId,'-o','json') 'Arc extension catalog preview feature'
if ($extensionTypesFeature.properties.state -ne 'Registered') {
  throw "Microsoft.KubernetesConfiguration/ExtensionTypes preview feature is $($extensionTypesFeature.properties.state), so the Arc extension catalog is unavailable. An authorized operator must register it with: az feature registration create --namespace Microsoft.KubernetesConfiguration --name ExtensionTypes --subscription $SubscriptionId. Wait until 'az feature show' reports Registered, then retry."
}
$localExtensions = @(Read-Az @('extension','list','-o','json') 'Locally installed Azure CLI extensions')
if (@($localExtensions | Where-Object name -EQ 'k8s-extension').Count -eq 0) {
  Write-Host 'Installing the k8s-extension Azure CLI extension for the pipeline opt-in...'
  & az extension add --name k8s-extension --yes --only-show-errors --output none
  if ($LASTEXITCODE -ne 0) { throw 'Installation of the k8s-extension Azure CLI extension failed; no VM changes were attempted.' }
}
$installedExtension = Read-Az @('extension','show','--name','k8s-extension','-o','json') 'Locally installed k8s-extension CLI'
if ($installedExtension.name -ne 'k8s-extension') {
  throw 'The installed k8s-extension Azure CLI extension could not be verified.'
}
$extensionTrains = @{ 'microsoft.certmanagement' = 'stable'; 'microsoft.monitor.pipeline' = 'preview' }
foreach ($type in $extensionTrains.Keys) {
  $catalog = @(Read-Az @('k8s-extension','extension-types','list-by-location','--subscription',$SubscriptionId,
    '--location',$Location,'--cluster-type','connectedClusters','--release-train',$extensionTrains[$type],'-o','json') "Regional $($extensionTrains[$type]) Arc extension catalog")
  if (@($catalog | Where-Object { $_.name -ieq $type -and $_.properties.supportedClusterTypes -contains 'connectedClusters' }).Count -eq 0) {
    throw "Extension $type is not advertised for connectedClusters in $Location on the $($extensionTrains[$type]) train."
  }
}
$versions = @(Read-Az @('k8s-extension','extension-types','list-versions-by-location','--subscription',$SubscriptionId,
  '--location',$Location,'--extension-type','microsoft.monitor.pipeline','--cluster-type','connectedClusters',
  '--release-train','preview','-o','json') 'Pipeline preview versions')
if (@($versions | Where-Object { $_.name -eq '0.1.7' -and $_.properties.version -eq '0.1.7' }).Count -ne 1) {
  throw 'Pipeline extension 0.1.7 is not available for connectedClusters on the preview train in the selected region.'
}
$permissions = Read-Az @('rest','--method','get','--url',"https://management.azure.com$rgId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01",'-o','json') 'Caller permissions'
foreach ($action in @('Microsoft.Compute/virtualMachines/runCommands/write',
    'Microsoft.Resources/deployments/write','Microsoft.Kubernetes/connectedClusters/write',
    'Microsoft.KubernetesConfiguration/extensions/write','Microsoft.Insights/dataCollectionRules/write',
    'Microsoft.Insights/dataCollectionRuleAssociations/write','Microsoft.Authorization/roleAssignments/write')) {
  Assert-Permission $permissions.value $action
}
$roles = @(Read-Az @('role','assignment','list','--subscription',$SubscriptionId,'--assignee-object-id',
  $vm.identity.principalId,'--scope',$rgId,'--include-inherited','-o','json') 'VM identity role assignments')
if (@($roles | Where-Object { $_.roleDefinitionName -in @('Owner','Contributor','Kubernetes Cluster - Azure Arc Onboarding') }).Count -eq 0) {
  throw "VM system identity needs Kubernetes Cluster - Azure Arc Onboarding at the resource group (or inherited) scope. An authorized operator can grant it with: az role assignment create --subscription $SubscriptionId --assignee-object-id $($vm.identity.principalId) --assignee-principal-type ServicePrincipal --role 'Kubernetes Cluster - Azure Arc Onboarding' --scope $rgId. No VM changes were attempted."
}
$clusters = @(Read-Az @('resource','list','--subscription',$SubscriptionId,'-g',$ResourceGroup,
  '--resource-type','Microsoft.Kubernetes/connectedClusters','-o','json') 'Existing Arc clusters')
$owned = @($clusters | Where-Object { $_.name -ieq $clusterName -or $_.id -ieq $clusterId })
if ($owned.Count -gt 1) { throw 'Ambiguous Arc cluster name.' }
$arcExists = $owned.Count -eq 1
if ($arcExists) {
  $existingArc = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$clusterId,'-o','json') 'Existing Arc cluster'
  if ($owned[0].id -ine $clusterId -or $existingArc.id -ine $clusterId -or
      $existingArc.tags.'monitor-lab-edge-vm' -ine $vmId -or
      $existingArc.location -ine $Location -or $existingArc.properties.provisioningState -ne 'Succeeded' -or
      $existingArc.properties.connectivityStatus -ne 'Connected') {
    throw 'Existing Arc cluster is foreign or unhealthy; refusing to connect or overwrite it.'
  }
}
$extensions = @()
if ($arcExists) {
  $extensions = @((Read-Az @('rest','--method','get','--url',
    "https://management.azure.com$clusterId/providers/Microsoft.KubernetesConfiguration/extensions?api-version=2023-05-01",
    '-o','json') 'Existing Arc extensions').value)
  Assert-Extension $extensions 'azure-cert-management' 'microsoft.certmanagement'
  Assert-Extension $extensions 'azure-monitor-pipeline' 'microsoft.monitor.pipeline'
}
$existingDcrs = @(Read-Az @('resource','list','--subscription',$SubscriptionId,'-g',$ResourceGroup,
  '--resource-type','Microsoft.Insights/dataCollectionRules','-o','json') 'Existing pipeline DCRs')
$existingAssociations = @()
if ($arcExists) {
  $existingAssociations = @((Read-Az @('rest','--method','get','--url',
    "https://management.azure.com$clusterId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2025-05-11",
    '-o','json') 'Existing pipeline associations').value)
}
$edgeRoot = Join-Path $PSScriptRoot '..\workloads\telemetry-ingestion\edge'
$bicep = Join-Path $edgeRoot 'arc-pipeline-extensions.bicep'
$syslog = Join-Path $edgeRoot 'syslog-pipeline.arm.json'
foreach ($file in @($bicep, $syslog)) { if (-not (Test-Path -LiteralPath $file)) { throw "Missing deployment asset: $file" } }
$template = Get-Content -LiteralPath $syslog -Raw | ConvertFrom-Json
if (@($template.parameters.PSObject.Properties.Name | Where-Object { $_ -notin @(
  'connectedClusterName','extensionName','workspaceResourceId','location','namePrefix','bypassFilter','enableCombined') }).Count -ne 0) {
  throw 'Syslog template parameters differ from the approved RFC5424 route.'
}
if ($template.parameters.enableCombined.defaultValue -ne $false) { throw 'Combined route must default off in the ARM template.' }
foreach ($suffix in @('settings','syslog') + $(if ($EnableCombined) { @('operational','diagnostic') } else { @() })) {
  $dcrId = "$rgId/providers/Microsoft.Insights/dataCollectionRules/$NamePrefix-$suffix"
  $associationName = $associationNames[$suffix]
  $assocId = "$clusterId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$associationName"
  $dcr = @($existingDcrs | Where-Object { $_.id -ieq $dcrId -or $_.name -ieq "$NamePrefix-$suffix" })
  $assoc = @($existingAssociations | Where-Object { $_.id -ieq $assocId -or $_.name -ieq $associationName })
  if ($dcr.Count -gt 1 -or $assoc.Count -gt 1 -or $assoc.Count -gt $dcr.Count) {
    throw "Existing $suffix resources are ambiguous or partially deployed; inspect manually before retrying."
  }
  if ($dcr.Count -eq 1) {
    $listedId = $dcr[0].id
    $dcr = @(Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$dcrId,'-o','json') "Existing $suffix DCR")
    if ($listedId -ine $dcrId) {
      throw "Existing $suffix DCR is foreign or unverified; refusing to overwrite it."
    }
  }
  if ($dcr.Count -eq 1 -and (-not $arcExists -or $dcr[0].id -ine $dcrId -or
      $dcr[0].properties.provisioningState -ne 'Succeeded' -or
      $(if ($suffix -eq 'settings') {
          $endpoints = @($dcr[0].properties.pipelineSettings.endpoints)
          $dcr[0].kind -ne 'PipelineSettings' -or $endpoints.Count -ne 1 -or
          $endpoints[0].name -ne 'syslog-tcp-6514' -or $endpoints[0].type -ne 'syslog' -or
          $endpoints[0].networkingConfig.endpoint -ne '0.0.0.0:6514' -or
          $endpoints[0].networkingConfig.transportProtocol -ne 'tcp'
        }
        elseif ($suffix -eq 'syslog') { $dcr[0].properties.destinations.logAnalytics[0].workspaceResourceId -ine $CentralLawId -or
          $dcr[0].properties.dataSources.syslog[0].allowedFormats -notcontains 'syslogRfc5424' -or
          $dcr[0].properties.transformations[0].processors[0].configuration.expression -notmatch 'EdgeDropFlag' }
        else {
          $expectedStream = "Custom-TelemetryIngestion$(if ($suffix -eq 'operational') { 'Operational' } else { 'Diagnostic' })_CL"
          $expected = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and
            $_.name -ceq "[variables('$($suffix)Name')]" })
          $flow = @($dcr[0].properties.dataFlows)
          $source = @($dcr[0].properties.dataSources.syslog)
          $expected.Count -ne 1 -or $dcr[0].kind -eq 'PipelineSettings' -or
          @($dcr[0].properties.destinations.logAnalytics).Count -ne 1 -or
          $dcr[0].properties.destinations.logAnalytics[0].workspaceResourceId -ine $CentralLawId -or
          $source.Count -ne 1 -or $source[0].allowedFormats -notcontains 'syslogRfc5424' -or
          $source[0].endpointRouting -notcontains 'syslog-tcp-6514' -or
          $dcr[0].properties.references.pipelineSettingsEndpointRouting[0].pipelineSettingsResourceId -ine "$rgId/providers/Microsoft.Insights/dataCollectionRules/$NamePrefix-settings" -or
          $flow.Count -ne 1 -or $flow[0].outputStream -cne $expectedStream -or
          $flow[0].transformKql -cne $expected[0].properties.dataFlows[0].transformKql -or
          $dcr[0].properties.transformations[0].processors[0].configuration.expression -cne $expected[0].properties.transformations[0].processors[0].configuration.expression
        }))) {
    throw "Existing $suffix DCR or association is foreign or unverified; refusing to overwrite it."
  }
  if ($assoc.Count -eq 1 -and ($assoc[0].id -ine $assocId -or
      $assoc[0].properties.dataCollectionRuleId -ine $dcrId -or
      $assoc[0].properties.scopeToResourceId -ine $extensionId)) {
    throw "Existing $suffix association is foreign or unverified; refusing to overwrite it."
  }
}

Invoke-Remote preflight $arcExists
Invoke-Remote install $arcExists
$arc = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$clusterId,'-o','json') 'Connected Arc cluster'
if ($arc.id -ine $clusterId -or $arc.tags.'monitor-lab-edge-vm' -ine $vmId -or
    $arc.properties.provisioningState -ne 'Succeeded' -or $arc.properties.connectivityStatus -ne 'Connected') {
  throw 'Arc did not report Connected with the expected VM ownership tag; extensions were not deployed.'
}

$extDeploy = Read-Az @('deployment','group','create','--subscription',$SubscriptionId,'--resource-group',$ResourceGroup,
  '--name',"$NamePrefix-edge-extensions",'--template-file',$bicep,'--parameters',"connectedClusterName=$clusterName",
  '-o','json') 'Arc extension deployment'
if ($extDeploy.properties.provisioningState -ne 'Succeeded') { throw 'Extension deployment did not succeed.' }
foreach ($spec in @(@('azure-cert-management','microsoft.certmanagement'),@('azure-monitor-pipeline','microsoft.monitor.pipeline'))) {
  $id = "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/$($spec[0])"
  $ext = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$id,'-o','json') "Extension $($spec[0])"
  Assert-Extension @($ext) $spec[0] $spec[1]
  if (-not $ext.properties.currentVersion -or
      ($spec[0] -eq 'azure-monitor-pipeline' -and $ext.properties.currentVersion -ne '0.1.7')) {
    throw "Extension $($spec[0]) has no verified installed version; Syslog resources were not deployed."
  }
}
$pipeline = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$extensionId,'-o','json') 'Pipeline extension'
if (-not $pipeline.identity.principalId -or $pipeline.properties.currentVersion -ne '0.1.7' -or
    $pipeline.properties.provisioningState -ne 'Succeeded') {
  throw 'Pipeline identity or install readiness is not proven; Syslog resources were not deployed.'
}
$sysDeploy = Read-Az @('deployment','group','create','--subscription',$SubscriptionId,'--resource-group',$ResourceGroup,
  '--name',"$NamePrefix-edge-syslog",'--template-file',$syslog,'--parameters',
  "connectedClusterName=$clusterName","extensionName=azure-monitor-pipeline",
  "workspaceResourceId=$CentralLawId","location=$Location","namePrefix=$NamePrefix","bypassFilter=false",
  "enableCombined=$($EnableCombined.ToString().ToLowerInvariant())",
  '-o','json') 'Syslog pipeline deployment'
if ($sysDeploy.properties.provisioningState -ne 'Succeeded') { throw 'Syslog deployment did not succeed.' }
foreach ($suffix in @('settings','syslog') + $(if ($EnableCombined) { @('operational','diagnostic') } else { @() })) {
  $id = "$rgId/providers/Microsoft.Insights/dataCollectionRules/$NamePrefix-$suffix"
  $dcr = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$id,'-o','json') "Pipeline $suffix DCR"
  if ($dcr.id -ine $id -or $dcr.properties.provisioningState -ne 'Succeeded') { throw "$suffix DCR not ready." }
  if ($suffix -in @('operational','diagnostic')) {
    $stream = "Custom-TelemetryIngestion$(if ($suffix -eq 'operational') { 'Operational' } else { 'Diagnostic' })_CL"
    if ($dcr.properties.destinations.logAnalytics[0].workspaceResourceId -ine $CentralLawId -or
        $dcr.properties.dataFlows[0].outputStream -cne $stream -or
        $dcr.properties.dataFlows[0].transformKql -notmatch 'SyntheticUser\s*=\s*"\[REDACTED\]"') {
      throw "$suffix DCR did not resolve to the expected Stage90 stream, workspace, and redaction."
    }
  }
  $associationId = "$clusterId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($associationNames[$suffix])"
  $association = Read-Az @('resource','show','--subscription',$SubscriptionId,'--ids',$associationId,'-o','json') "$suffix association"
  if ($association.id -ine $associationId -or $association.properties.dataCollectionRuleId -ine $id -or
      $association.properties.scopeToResourceId -ine $extensionId) { throw "$suffix association ID or scope mismatch." }
}
Write-Output ([pscustomobject]@{
  ArcClusterId = $clusterId
  PipelineExtensionId = $extensionId
  Configuration = 'Accepted by ARM; DCR and association IDs verified'
  Combined = [bool]$EnableCombined
  LiveIngestion = 'NOT VERIFIED: query Syslog for unique RunId/EventId and inspect on-host receiver/export counters'
})
