[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $WebAppName,
  [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $CustomerWebAppName = '',
  [Parameter(Mandatory)] [string] $ConsoleConfigPath,
  [guid[]] $AllowedUserObjectIds
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path $PSScriptRoot -Parent
$tokens = @{}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('amlab-console-bootstrap-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$phase = 'account verification'

function Invoke-ConsoleApi([string] $Method, [string] $Uri, [object] $Body = $null) {
  $address = [Uri]$Uri
  if ($address.Scheme -ne 'https' -or -not $tokens.ContainsKey($address.Host)) { throw 'Unexpected console setup API.' }
  $arguments = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $($tokens[$address.Host])" }; TimeoutSec = 60; Verbose = $false; Debug = $false }
  if ($null -ne $Body) { $arguments.Body = $Body | ConvertTo-Json -Depth 25 -Compress; $arguments.ContentType = 'application/json' }
  try { Invoke-RestMethod @arguments }
  catch {
    $statusCode = [int]$_.Exception.Response.StatusCode
    if ($address.Host -eq 'graph.microsoft.com' -and $statusCode -eq 401) {
      throw "Microsoft Graph rejected the cached Azure CLI session. Run 'az logout', then 'az login --tenant $TenantId', select subscription $SubscriptionId, and retry the deployment."
    }
    throw "Console setup API failed (HTTP $statusCode). Protected response details were suppressed."
  }
}

function Grant-ConsoleRole([string] $PrincipalId, [string] $Scope, [string] $Name) {
  $definitions = @(az role definition list --name $Name --subscription $SubscriptionId --query '[].id' --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0 -or $definitions.Count -ne 1) { throw "Could not resolve role $Name." }
  $existing = @(az role assignment list --scope $Scope --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not inspect console role assignments.' }
  if (-not @($existing | Where-Object { $_.principalId -eq $PrincipalId -and $_.scope -ieq $Scope -and $_.roleDefinitionId -ieq $definitions[0] }).Count) {
    $null = az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal --role $definitions[0] `
      --scope $Scope --subscription $SubscriptionId --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'A required console role assignment failed.' }
  }
}

function Invoke-ConsoleDeployment([string] $Name, [string] $Template, [string[]] $TemplateParameters) {
  $arguments = @('--subscription', $SubscriptionId.ToString(), '--resource-group', $ResourceGroup, '--name', $Name, '--template-file', $Template, '--parameters') + $TemplateParameters
  $preview = az deployment group what-if @arguments --result-format ResourceIdOnly --no-pretty-print --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $preview -or $preview.status -eq 'Failed') { throw 'Console deployment preview failed.' }
  if (@($preview.changes | Where-Object { $_.changeType -eq 'Delete' }).Count) { throw 'Console deployment would delete a resource. No deployment was submitted.' }
  Write-Host "Deployment preview passed: $Name. No resource deletions."
  $outputs = az deployment group create @arguments --query properties.outputs --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw "Console deployment failed: $Name." }
  return $outputs
}

try {
  az account set --subscription $SubscriptionId --only-show-errors
  $account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) { throw 'Subscription or tenant mismatch.' }
  foreach ($hostName in @('management.azure.com', 'graph.microsoft.com')) {
    $tokens[$hostName] = az account get-access-token --subscription $SubscriptionId --resource "https://$hostName/" --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $tokens[$hostName]) { throw 'Required setup authentication is unavailable.' }
  }
  $null = Invoke-ConsoleApi GET 'https://graph.microsoft.com/v1.0/me?$select=id'
  $config = Get-Content -LiteralPath $ConsoleConfigPath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $config.LabConsole -or $config.LabConsole.ResourceGroup -ne $ResourceGroup) { throw 'Generated console configuration does not match this deployment.' }
  $resourceBase = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
  $webId = "$resourceBase/providers/Microsoft.Web/sites/$WebAppName"
  $web = Invoke-ConsoleApi GET "https://management.azure.com${webId}?api-version=2024-11-01"
  if (-not $web.identity.principalId) { throw 'The console Web App has no managed identity.' }
  $settingsResponse = Invoke-ConsoleApi POST "https://management.azure.com$webId/config/appsettings/list?api-version=2024-11-01"
  $settings = @{}
  foreach ($property in $settingsResponse.properties.PSObject.Properties) { $settings[$property.Name] = $property.Value }
  $slotScenarioEnabled = $settings['LabConsole__SlotScenarioEnabled'] -ieq 'true'
  if ($slotScenarioEnabled -and (-not $CustomerWebAppName -or $CustomerWebAppName -cne "$WebAppName-customer")) {
    throw 'The enabled slot scenario requires its exact dedicated customer Web App name.'
  }
  $settings['LabConsole__Operations__Enabled'] = 'false'
  $settings['LabConsole__Health__Enabled'] = 'false'
  $null = Invoke-ConsoleApi PUT "https://management.azure.com$webId/config/appsettings?api-version=2024-11-01" @{ properties = $settings }
  if (-not $AllowedUserObjectIds) {
    $existingOperators = @($settings.Keys | Where-Object { $_ -like 'LabConsole__AllowedPrincipalIds__*' } | ForEach-Object {
      $operatorId = [guid]::Empty
      if ([guid]::TryParse($settings[$_], [ref]$operatorId) -and $operatorId -ne [guid]::Empty) { $operatorId }
    })
    if ($existingOperators.Count) { $AllowedUserObjectIds = $existingOperators }
    else { $AllowedUserObjectIds = @([guid](Invoke-ConsoleApi GET 'https://graph.microsoft.com/v1.0/me?$select=id').id) }
  }
  $phase = 'operator sign-in'
  & (Join-Path $PSScriptRoot 'setup-webapp-agent-access.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup `
    -WebAppName $WebAppName -AllowedUserObjectIds $AllowedUserObjectIds -AuthenticationOnly

  $phase = 'runner platform provisioning'
  foreach ($provider in @('Microsoft.App', 'Microsoft.ContainerRegistry')) {
    az provider register --namespace $provider --subscription $SubscriptionId --wait --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw 'A console resource provider could not be registered.' }
  }
  if (-not $config.LabConsole.Health.CentralWorkspaceResourceId) { throw 'The lab central health workspace was not found.' }
  $tagInventory = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Runner tag discovery failed. No runner deployment was submitted.' }
  $existingResourceTags = @{}
  foreach ($resource in @($tagInventory | Where-Object { $_.type -in @('Microsoft.ContainerRegistry/registries', 'Microsoft.App/managedEnvironments', 'Microsoft.ManagedIdentity/userAssignedIdentities', 'Microsoft.App/jobs') })) {
    if (-not $resource.id.StartsWith("$resourceBase/providers/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Runner tag discovery returned a resource outside the lab.' }
    $existingResourceTags[$resource.name] = $resource.tags ?? @{}
  }
  $vmInventory = @(az vm list --subscription $SubscriptionId --resource-group $ResourceGroup --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'CPU target discovery failed. No runner deployment was submitted.' }
  $cpuVms = @($vmInventory | Where-Object { $_.tags.purpose -ceq 'azure-monitor-lab' })
  $cpuVmNames = @()
  if ($cpuVms.Count -eq 2 -and @($cpuVms | Where-Object { $_.storageProfile.osDisk.osType -eq 'Linux' }).Count -eq 1 -and
    @($cpuVms | Where-Object { $_.storageProfile.osDisk.osType -eq 'Windows' }).Count -eq 1) {
    foreach ($vm in $cpuVms) {
      if ($vm.id -ine "$resourceBase/providers/Microsoft.Compute/virtualMachines/$($vm.name)") { throw 'A CPU target is outside the selected lab. No guest execution access was granted.' }
    }
    $cpuVmNames = @($cpuVms.name)
  }
  $tagParametersPath = Join-Path $temporary 'runner-tags.parameters.json'
  $tagParameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
      tags = @{ value = $web.tags ?? @{} }
      existingResourceTags = @{ value = $existingResourceTags }
    }
  }
  $tagParameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tagParametersPath -Encoding utf8
  $platformParametersPath = Join-Path $temporary 'runner-platform.parameters.json'
  $tagParameters.parameters.cpuVmNames = @{ value = $cpuVmNames }
  $tagParameters.parameters.enableSlotFailureScenario = @{ value = $slotScenarioEnabled }
  $tagParameters.parameters.customerWebAppName = @{ value = $CustomerWebAppName }
  $tagParameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $platformParametersPath -Encoding utf8
  $platform = Invoke-ConsoleDeployment 'lab-console-platform' (Join-Path $root 'infra/modules/lab-console-platform.json') @(
    "webAppName=$WebAppName", "customerWebAppName=$CustomerWebAppName", "centralLawId=$($config.LabConsole.Health.CentralWorkspaceResourceId)", "location=$($web.location)", "@$platformParametersPath"
  )
  if ($LASTEXITCODE -ne 0 -or -not $platform.registryName.value -or -not $platform.environmentId.value -or -not $platform.runnerIdentityId.value) { throw 'The workload template did not provision the console runner platform.' }
  foreach ($id in @($platform.registryId.value, $platform.environmentId.value, $platform.runnerIdentityId.value)) {
    if (-not $id.StartsWith("$resourceBase/providers/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Runner platform scope does not match the lab.' }
  }
  $identity = az identity show --ids $platform.runnerIdentityId.value --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $identity.clientId -or -not $identity.principalId) { throw 'Runner identity is unavailable.' }
  $environment = az resource show --ids $platform.environmentId.value --subscription $SubscriptionId --api-version 2025-07-01 --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $environment.location) { throw 'Runner environment is unavailable.' }

  $phase = 'runner AcrPull role propagation'
  $acrPullConfirmed = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $roleNames = az role assignment list --scope $platform.registryId.value --assignee-object-id $identity.principalId `
      --subscription $SubscriptionId --query "[?roleDefinitionName=='AcrPull'].roleDefinitionName" --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the console runner AcrPull assignment.' }
    if (@($roleNames | Where-Object { $_ -eq 'AcrPull' }).Count -gt 0) {
      $acrPullConfirmed = $true
      break
    }
    if ($attempt -lt 5) {
      Write-Host "Waiting for runner AcrPull RBAC propagation (attempt $attempt/5, waiting 60s)..."
      Start-Sleep -Seconds 60
    }
  }
  if (-not $acrPullConfirmed) { throw 'The runner identity AcrPull assignment was not visible on its registry after five attempts.' }

  $phase = 'runner image build'
  $build = Join-Path $temporary 'build'
  $null = New-Item -ItemType Directory -Path (Join-Path $build 'scripts') -Force
  $null = New-Item -ItemType Directory -Path (Join-Path $build 'workloads/k8s') -Force
  $null = New-Item -ItemType Directory -Path (Join-Path $build 'workloads/webapp/scripts') -Force
  $files = @('scripts/invoke-lab-operation.ps1', 'scripts/slot-health.ps1', 'scripts/start-the-lab.ps1', 'scripts/stop-the-lab.ps1', 'scripts/break-the-lab.ps1', 'scripts/restore-the-lab.ps1',
    'scripts/start-ramp.ps1', 'scripts/simulate-high-cpu.ps1', 'scripts/send-custom-logs.ps1', 'scripts/send-release-annotation.ps1', 'scripts/generate-usage-traffic.ps1',
    'scripts/trigger-broken-slot.ps1',
    'workloads/k8s/02-loadgen.yaml', 'workloads/k8s/03-loadgen-ramp.yaml', 'workloads/webapp/package.json', 'workloads/webapp/package-lock.json',
    'workloads/webapp/scripts/generate-usage-traffic.mjs')
  foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $build $file) }
  Copy-Item -LiteralPath (Join-Path $root 'workloads/operations/Dockerfile') -Destination (Join-Path $build 'Dockerfile')
  $hashes = @(Get-ChildItem $build -File -Recurse | Sort-Object FullName | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash })
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashes -join '|'))).ToLowerInvariant()
  $imageTag = "lab-operations:$($hash.Substring(0, 20))"
  az acr build --registry $platform.registryName.value --subscription $SubscriptionId --resource-group $ResourceGroup --image $imageTag `
    --file (Join-Path $build 'Dockerfile') --no-logs $build --only-show-errors --output none
  if ($LASTEXITCODE -ne 0) { throw 'The cloud runner image build failed. No Docker installation or manual image publication is required; check ACR Tasks availability.' }
  $digest = az acr repository show --name $platform.registryName.value --image $imageTag --subscription $SubscriptionId --query digest --output tsv --only-show-errors
  $server = az acr show --name $platform.registryName.value --resource-group $ResourceGroup --subscription $SubscriptionId --query loginServer --output tsv --only-show-errors
  if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[a-f0-9]{64}$' -or $server -notmatch '^[a-z0-9.-]+\.azurecr\.io$') { throw 'The built runner image digest could not be verified.' }
  $image = "$server/lab-operations@$digest"

  $phase = 'runner job provisioning'
  $job = Invoke-ConsoleDeployment 'lab-console-job' (Join-Path $root 'infra/modules/lab-console-job.json') @(
    "name=$($platform.jobName.value)", "location=$($environment.location)", "webAppName=$WebAppName", "customerWebAppName=$CustomerWebAppName", "environmentId=$($platform.environmentId.value)",
    "registryServer=$server", "runnerIdentityId=$($identity.id)", "runnerClientId=$($identity.clientId)", "image=$image", "@$tagParametersPath"
  )
  if ($LASTEXITCODE -ne 0 -or -not $job.jobId.value) { throw 'Runner job deployment failed.' }
  $inventory = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Console resource discovery failed.' }
  $customDcrs = @($inventory | Where-Object { $_.type -ieq 'Microsoft.Insights/dataCollectionRules' -and $_.name -like '*customlogs*' })
  if ($customDcrs.Count -eq 0) {
    $centralId = $config.LabConsole.Health.CentralWorkspaceResourceId
    $law = Invoke-ConsoleApi GET "https://management.azure.com${centralId}?api-version=2023-09-01"
    if ($law.name -notmatch '^law-([a-zA-Z0-9]{3,8})-central-') { throw 'The lab naming prefix for custom-log setup could not be resolved.' }
    $prefix = $Matches[1]
    $null = Invoke-ConsoleDeployment 'custom-logs' (Join-Path $root 'infra/modules/custom-logs.json') @(
      "namePrefix=$prefix", "location=$($law.location)", "centralLawId=$centralId", "centralLawName=$($law.name)"
    )
    if ($LASTEXITCODE -ne 0) { throw 'Custom-log ingestion prerequisites could not be provisioned.' }
    $inventory = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup --output json --only-show-errors | ConvertFrom-Json)
    $customDcrs = @($inventory | Where-Object { $_.type -ieq 'Microsoft.Insights/dataCollectionRules' -and $_.name -like '*customlogs*' })
  }
  if ($customDcrs.Count -ne 1) { throw 'Exactly one custom-log ingestion rule is required for the console.' }
  foreach ($dcr in @($inventory | Where-Object { $_.type -ieq 'Microsoft.Insights/dataCollectionRules' -and $_.name -like '*customlogs*' })) {
    Grant-ConsoleRole $identity.principalId $dcr.id 'Monitoring Metrics Publisher'
  }

  $phase = 'health and optional agent access'
  foreach ($workspaceId in @($config.LabConsole.Health.CentralWorkspaceResourceId, $config.LabConsole.Health.AppInsightsWorkspaceResourceId) | Where-Object { $_ } | Select-Object -Unique) {
    if (-not $workspaceId.StartsWith("$resourceBase/providers/Microsoft.OperationalInsights/workspaces/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Health workspace is outside the selected lab.' }
    Grant-ConsoleRole $web.identity.principalId $workspaceId 'Log Analytics Reader'
  }
  if (-not $config.LabConsole.Health.CentralWorkspaceResourceId) { throw 'The lab central health workspace was not found.' }
  $sreAgents = @($inventory | Where-Object { $_.type -ieq 'Microsoft.App/agents' })
  $observabilityAgents = @($inventory | Where-Object { $_.type -ieq 'Microsoft.Monitor/observabilityAgents' })
  $projects = @($inventory | Where-Object { $_.type -ieq 'Microsoft.CognitiveServices/accounts/projects' })
  if ($projects.Count -gt 1 -or $sreAgents.Count -gt 1 -or $observabilityAgents.Count -gt 1) { throw 'Multiple optional agent targets were found. Deployment cannot select an arbitrary target.' }
  if ($projects.Count -eq 1) {
    $phase = 'optional demo agent provisioning'
    if (-not $projects[0].id.StartsWith("$resourceBase/providers/Microsoft.CognitiveServices/accounts/", [StringComparison]::OrdinalIgnoreCase)) { throw 'The Foundry project is outside the selected lab.' }
    Grant-ConsoleRole $web.identity.principalId $projects[0].id 'Foundry User'
    $accountId = $projects[0].id.Substring(0, $projects[0].id.LastIndexOf('/projects/', [StringComparison]::OrdinalIgnoreCase))
    $deployments = @(az cognitiveservices account deployment list --name ($accountId.Split('/')[-1]) --resource-group $ResourceGroup --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json)
    $preferred = @($deployments | Where-Object { $_.properties.model.name -eq 'gpt-5-mini' })
    if ($LASTEXITCODE -ne 0 -or $preferred.Count -ne 1) { throw 'The console model deployment was not uniquely resolved.' }
    $projectName = $projects[0].id.Split('/')[-1]
    $config.LabConsole.Foundry.ProjectEndpoint = "https://$($accountId.Split('/')[-1]).services.ai.azure.com/api/projects/$projectName"
    $components = @($inventory | Where-Object { $_.type -ieq 'Microsoft.Insights/components' })
    if ($components.Count -ne 1) { throw 'The lab Application Insights component was not uniquely resolved.' }
    $component = Invoke-ConsoleApi GET "https://management.azure.com$($components[0].id)?api-version=2020-02-02"
    & (Join-Path $PSScriptRoot 'setup-ai.ps1') -ResourceGroup $ResourceGroup -NamePrefix ($projectName -replace '-ai-proj$', '') `
      -SubscriptionId $SubscriptionId -TenantId $TenantId -ProjectEndpoint $config.LabConsole.Foundry.ProjectEndpoint `
      -AppInsightsConnectionString $component.properties.ConnectionString -ChatDeployment $preferred[0].name -SkipTraffic
  }
  if ($sreAgents.Count -eq 1 -and $projects.Count -eq 1) {
    & (Join-Path $PSScriptRoot 'setup-webapp-agent-access.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -WebAppName $WebAppName `
      -SreAgentName $sreAgents[0].name -FoundryAccountName ($accountId.Split('/')[-1]) -FoundryProjectName ($projects[0].id.Split('/')[-1]) `
      -ModelDeployment $preferred[0].name -AllowedUserObjectIds $AllowedUserObjectIds
  }

  $phase = 'console enablement'
  $settingsResponse = Invoke-ConsoleApi POST "https://management.azure.com$webId/config/appsettings/list?api-version=2024-11-01"
  $settings = @{}
  foreach ($property in $settingsResponse.properties.PSObject.Properties) { $settings[$property.Name] = $property.Value }
  $config.LabConsole.Operations = @{ Enabled = $true; JobResourceId = $job.jobId.value; Image = $image; TenantId = $TenantId.ToString(); JournalPath = '/home/data/lab-operations/journal.json' }
  $config.LabConsole.Health.Enabled = $true
  $config.LabConsole.Health.TenantId = $TenantId.ToString()
  foreach ($section in @('Operations', 'Health')) {
    foreach ($key in $config.LabConsole[$section].Keys) { $settings["LabConsole__${section}__$key"] = [string]$config.LabConsole[$section][$key] }
  }
  $settings['LabConsole__Foundry__Enabled'] = [string]($projects.Count -eq 1)
  $settings['LabConsole__Sre__Enabled'] = [string]($projects.Count -eq 1 -and $sreAgents.Count -eq 1)
  if ($observabilityAgents.Count -eq 1) {
    $settings['LabConsole__Links__ObservabilityAgent'] = "https://portal.azure.com/#resource$($observabilityAgents[0].id)"
  } else {
    $settings.Remove('LabConsole__Links__ObservabilityAgent')
  }
  $settings['LabConsole__ResourceGroup'] = $ResourceGroup
  $settings['LabConsole__AppService'] = $WebAppName
  if ($projects.Count -eq 1 -and $config.LabConsole.Foundry.ProjectEndpoint) { $settings['LabConsole__Foundry__ProjectEndpoint'] = $config.LabConsole.Foundry.ProjectEndpoint }
  $null = Invoke-ConsoleApi PUT "https://management.azure.com$webId/config/appsettings?api-version=2024-11-01" @{ properties = $settings }
  $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ConsoleConfigPath -Encoding utf8
  Write-Host 'Console infrastructure, sign-in, health, and available optional integrations configured. No lab action was executed.'
} catch {
  throw "Lab console deployment did not complete during $phase. $($_.Exception.Message) Deployment is not ready; no manual enablement is expected after a successful deployment."
} finally {
  $tokens.Clear()
  $settingsResponse = $null
  $settings = $null
  if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}