<#
.SYNOPSIS
  Post-deploy steps: push sample app to App Service + apply AKS workloads.

.PARAMETER AppInsightsConnectionString
  Optional pre-resolved connection string. The Cloud Shell wrapper supplies this
  through the core ARM CLI surface to avoid installing the App Insights extension.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $WebAppName,
  [string] $CustomerWebAppName,
  [Parameter(Mandatory)] [string] $AksName,
  [Parameter(Mandatory)] [string] $WebAppHost,
  [string] $CentralLawName,
  [string] $AppInsightsConnectionString,
  [switch] $BundleSreMcp,
  [string] $SreTenantId,
  [string] $SreModelEndpoint,
  [string] $SreModelDeployment,
  [guid[]] $ConsoleOperatorObjectIds,
  [guid] $SubscriptionId,
  [guid] $TenantId
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
$tempDirectory = [System.IO.Path]::GetTempPath()

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if ($SubscriptionId -ne [guid]::Empty) {
  if ($TenantId -eq [guid]::Empty) { throw 'An expected tenant is required with an explicit subscription.' }
  az account set --subscription $SubscriptionId --only-show-errors
  $active = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $active.id -ne $SubscriptionId.ToString() -or $active.tenantId -ne $TenantId.ToString()) { throw 'Post-deployment subscription or tenant mismatch.' }
} elseif (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting post-deploy."
  }
} else {
  throw 'Pass the expected subscription and tenant or provide the lab target configuration before deployment.'
}

$customerWebAppHost = $null
if ($CustomerWebAppName) {
  if ($CustomerWebAppName -cne "$WebAppName-customer") { throw 'The customer Web App must use the dedicated name derived from the Control Center.' }
  $customerWebApp = az webapp show --subscription $active.id --resource-group $ResourceGroup --name $CustomerWebAppName `
    --query '{state:state,usageState:usageState,defaultHostName:defaultHostName}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $customerWebApp.defaultHostName) { throw 'Could not verify the dedicated customer Web App before publication.' }
  if ($customerWebApp.state -eq 'QuotaExceeded' -or $customerWebApp.usageState -eq 'Exceeded') {
    throw "Customer Web App '$CustomerWebAppName' is quota-blocked. Resolve App Service quota before retrying."
  }
  $customerWebAppHost = $customerWebApp.defaultHostName
}

Write-Step 'Replacing the auto-mitigation Logic App resource-group grant with VM-scoped access'
& (Join-Path $PSScriptRoot 'cleanup-legacy-rbac.ps1') `
  -SubscriptionId $active.id `
  -ResourceGroup $ResourceGroup `
  -AutoMitigation

$webAppState = az webapp show --subscription $active.id --resource-group $ResourceGroup --name $WebAppName `
  --query '{state:state,usageState:usageState}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $webAppState.state) { throw 'Could not verify the Web App state before publication.' }
if ($webAppState.state -eq 'QuotaExceeded' -or $webAppState.usageState -eq 'Exceeded') {
  throw "App Service '$WebAppName' is quota-blocked (state: $($webAppState.state), usageState: $($webAppState.usageState)). Resolve its App Service plan quota before retrying. The lab uses Basic B1 by default and Standard S1 when the slot scenario is enabled. No Web App changes were made."
}

# 1. Build + zip-deploy the bundled .NET 8 minimal API (workloads/webapp/AmlabHello)
#    so App Insights gets requests/dependencies/failures from a real app.
$deploymentId = [guid]::NewGuid().ToString('N')
$pub = Join-Path $tempDirectory "amlab-pub-$([guid]::NewGuid().ToString('N'))"
$csproj = Join-Path $PSScriptRoot '..' 'workloads' 'webapp' 'AmlabHello.csproj'
$previousWorkloadIntegrityCheck = $env:DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK
$env:DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK = '1'
try {
  dotnet publish $csproj -c Release -o $pub --nologo --verbosity quiet "-p:InformationalVersion=$deploymentId" '-p:IncludeSourceRevisionInInformationalVersion=false'
  $publishExitCode = $LASTEXITCODE
} finally {
  if ($null -eq $previousWorkloadIntegrityCheck) {
    Remove-Item Env:DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK -ErrorAction SilentlyContinue
  } else {
    $env:DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK = $previousWorkloadIntegrityCheck
  }
}
if ($publishExitCode -ne 0) {
  throw "AmlabHello publish failed with exit code $publishExitCode. Confirm that the .NET 8 or later SDK is available."
}
if (-not (Test-Path (Join-Path $pub 'AmlabHello.dll'))) {
  throw "AmlabHello publish completed without producing '$pub/AmlabHello.dll'."
}
$consoleAccountJson = az account show --query '{id:id,tenantId:tenantId}' --output json
if ($LASTEXITCODE -ne 0 -or -not $consoleAccountJson) { throw 'Unable to resolve the deployment subscription and tenant.' }
$consoleAccount = $consoleAccountJson | ConvertFrom-Json
if ($consoleAccount.id -ne $active.id -or $consoleAccount.tenantId -ne $active.tenantId) { throw 'The Azure account changed during deployment.' }
if ($SreTenantId -and $SreTenantId -ne $consoleAccount.tenantId) { throw 'SRE tenant must match the deployment tenant.' }
& (Join-Path $PSScriptRoot 'prepare-webapp-package.ps1') `
  -PublishDirectory $pub -ResourceGroup $ResourceGroup -SubscriptionId $consoleAccount.id -TenantId $consoleAccount.tenantId `
  -WebAppName $WebAppName -CustomerWebAppName $CustomerWebAppName `
  -CentralLawName $CentralLawName -BundleSreMcp:$BundleSreMcp `
  -SreModelEndpoint $SreModelEndpoint -SreModelDeployment $SreModelDeployment
& (Join-Path $PSScriptRoot 'initialize-webapp-console.ps1') -SubscriptionId $consoleAccount.id -TenantId $consoleAccount.tenantId `
  -ResourceGroup $ResourceGroup -WebAppName $WebAppName -CustomerWebAppName $CustomerWebAppName `
  -ConsoleConfigPath (Join-Path $pub 'lab-console.json') -AllowedUserObjectIds $ConsoleOperatorObjectIds
$zip = "$pub.zip"
Write-Step 'Compressing the Web App package (including the bundled MCP runtime)'
Compress-Archive -Path (Join-Path $pub '*') -DestinationPath $zip -Force
Write-Step "Publishing AmlabHello (workloads/webapp) to the Control Center and customer app"
$publicationTargets = @(@{ Name = $WebAppName; Host = $WebAppHost; Description = 'Control Center' })
if ($CustomerWebAppName) {
  $publicationTargets += @{ Name = $CustomerWebAppName; Host = $customerWebAppHost; Description = 'customer Web App' }
}
foreach ($target in $publicationTargets) {
  Write-Step "Disabling Kudu build and setting startup command for $($target.Description)"
  az webapp config appsettings set `
    --subscription $active.id --resource-group $ResourceGroup --name $target.Name `
    --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw "Could not configure prebuilt deployment for $($target.Description)." }
  az webapp config set `
    --subscription $active.id --resource-group $ResourceGroup --name $target.Name `
    --startup-file 'dotnet AmlabHello.dll' --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw "Could not configure the startup command for $($target.Description)." }
  Start-Sleep -Seconds 30

  Write-Step "Uploading Web App package to $($target.Name) ($([Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)) MiB)"
  $deployOutput = ''
  $deployExitCode = 1
  $scmRestartRetries = 0
  $zipDeployRetries = 0
  $publicationVerified = $false
  $scmHost = "$($target.Name).scm.azurewebsites.net"
  do {
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
      $PSNativeCommandUseErrorActionPreference = $false
      $deployOutput = & az webapp deploy `
        --subscription $active.id --resource-group $ResourceGroup --name $target.Name `
        --src-path $zip --type zip --restart true --async true --track-status false --output none 2>&1 | Out-String
      $deployExitCode = $LASTEXITCODE
    } finally {
      $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
    $statusDnsFailure = $deployOutput -match [regex]::Escape($scmHost) -and
      $deployOutput -match '/api/deployments/latest' -and
      $deployOutput -match 'NameResolutionError|getaddrinfo failed|Failed to resolve'
    if ($deployExitCode -ne 0 -and $statusDnsFailure) {
      Write-Warning "Azure CLI could not resolve '$scmHost' while checking deployment status. Verifying the expected application version without uploading again."
      try {
        & (Join-Path $PSScriptRoot 'wait-webapp-publication.ps1') -WebAppHost $target.Host -DeploymentId $deploymentId
        $publicationVerified = $true
      } catch {
        throw "The expected application version '$deploymentId' could not be verified after a DNS failure querying deployment status at '$scmHost'. The upload outcome is unknown. No additional ZIP upload was submitted. Package retained at '$zip'. Check DNS and App Service deployment status before retrying. Azure CLI exit code: $deployExitCode. Details:`n$deployOutput"
      }
      break
    }
  $scmRestarted = $deployOutput -match 'SCM container restart|management operation and a deployment operation in quick succession'
  $zipDeploymentFailed = $deployOutput -match 'Zip deployment failed|Status Code: 502|Deployment Failed.*OneDeploy'
  if ($deployExitCode -ne 0 -and $scmRestarted -and $scmRestartRetries -lt 2) {
    $scmRestartRetries++
    Write-Host "   SCM restarted during ZIP deployment. Waiting 60 seconds before retry $scmRestartRetries/2..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
  } elseif ($deployExitCode -ne 0 -and $zipDeploymentFailed -and $zipDeployRetries -lt 2) {
    $zipDeployRetries++
    Write-Host "   OneDeploy failed after upload. Waiting 60 seconds before retry $zipDeployRetries/2..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
  } else {
    break
  }
} while ($true)

if ($deployExitCode -ne 0 -and -not $publicationVerified) {
  throw "App Service ZIP upload failed for $($target.Description). Exit code: $deployExitCode. Details:`n$deployOutput"
}

if (-not $publicationVerified) {
  & (Join-Path $PSScriptRoot 'wait-webapp-publication.ps1') -WebAppHost $target.Host -DeploymentId $deploymentId
}
}
Write-Step 'Preparing the opt-in broken deployment slot when provisioned'
if ($CustomerWebAppName) {
& (Join-Path $PSScriptRoot 'prepare-broken-slot.ps1') -SubscriptionId $active.id -ResourceGroup $ResourceGroup `
  -WebAppName $CustomerWebAppName -ArchivePath $zip -DeploymentId $deploymentId
} else {
Write-Host 'No dedicated customer Web App was provisioned; skipping broken-slot publication.'
}
Write-Step 'Cleaning up local Web App package files'
Remove-Item -Recurse -Force $pub
Remove-Item -Force $zip

# 2. Get AKS credentials and apply the workload + k6 load generator
Write-Step "Getting AKS credentials"
az aks get-credentials --subscription $active.id --resource-group $ResourceGroup --name $AksName --overwrite-existing --output none
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain the lab Kubernetes credentials.' }

Write-Step "Applying frontend deployment + service"
$frontendYaml = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '01-frontend.yaml'
kubectl apply -f $frontendYaml
if ($LASTEXITCODE -ne 0) { throw 'The demo frontend could not be deployed.' }

Write-Step "Substituting App Service URL into the k6 CronJob and applying"
$loadgenTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '02-loadgen.yaml'
$loadgenRendered = Join-Path $tempDirectory "amlab-loadgen-$([guid]::NewGuid().ToString('N')).yaml"
$webAppUrl = "https://$WebAppHost"
(Get-Content -Raw $loadgenTemplate).Replace('__APP_SERVICE_URL__', "'$webAppUrl'") | Set-Content -Encoding UTF8 $loadgenRendered
kubectl apply -f $loadgenRendered
if ($LASTEXITCODE -ne 0) { throw 'The demo load generator could not be deployed.' }
Remove-Item $loadgenRendered -Force

# FEATURE 4 — Apply the OpenTelemetry distributed-tracing demo (AKS → App Service).
if ([string]::IsNullOrWhiteSpace($AppInsightsConnectionString)) {
  Write-Step "Looking up App Insights connection string for the OTel caller"
  $appiId = az resource list --subscription $active.id -g $ResourceGroup --resource-type Microsoft.Insights/components --query '[0].id' -o tsv
  $AppInsightsConnectionString = az resource show --subscription $active.id --ids $appiId --api-version 2020-02-02 --query properties.ConnectionString -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $AppInsightsConnectionString) { throw 'Application Insights configuration could not be resolved.' }
}

Write-Step "Rendering and applying OTel caller deployment"
$otelTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '04-otel-caller.yaml'
$otelRendered = Join-Path $tempDirectory "amlab-otel-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $otelTemplate).Replace('__APP_SERVICE_URL__', $webAppUrl).Replace('__APPI_CONN_STR__', $AppInsightsConnectionString) | Set-Content -Encoding UTF8 $otelRendered
kubectl apply -f $otelRendered
if ($LASTEXITCODE -ne 0) { throw 'The OpenTelemetry caller could not be deployed.' }
Remove-Item $otelRendered -Force

# NEW — Node.js auto-instrumentation via @azure/monitor-opentelemetry (GA distro).
Write-Step "Rendering and applying Node.js OTel deployment"
$nodeTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '05-nodeapp-otel.yaml'
$nodeRendered = Join-Path $tempDirectory "amlab-nodeapp-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $nodeTemplate).Replace('__APP_SERVICE_URL__', $webAppUrl).Replace('__APPI_CONN_STR__', $AppInsightsConnectionString) | Set-Content -Encoding UTF8 $nodeRendered
kubectl apply -f $nodeRendered
if ($LASTEXITCODE -ne 0) { throw 'The instrumented Node workload could not be deployed.' }
Remove-Item $nodeRendered -Force

# 3. Wait for the LoadBalancer IP and print it
Write-Step "Waiting up to 3 minutes for the AKS LoadBalancer IP..."
$externalIp = $null
for ($i = 0; $i -lt 18; $i++) {
  $externalIp = kubectl get svc hello-frontend -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
  if ($externalIp) { break }
  Start-Sleep -Seconds 10
}

if ($externalIp) {
  Write-Host "`nAKS frontend exposed at: http://$externalIp" -ForegroundColor Green
} else {
  Write-Host "`nLoadBalancer IP not yet assigned. Check with: kubectl get svc -n demo" -ForegroundColor Yellow
}

Write-Host "`nApp Service URL : https://$WebAppHost" -ForegroundColor Green
Write-Host "Trigger an immediate first load-test run with:" -ForegroundColor Yellow
Write-Host "  kubectl create job --from=cronjob/loadgen loadgen-now -n demo" -ForegroundColor Yellow

# 4. Assign Monitoring Metrics Publisher role on the custom-logs DCR
#    so send-custom-logs.ps1 can ingest data via the Logs Ingestion API.
Write-Step "Assigning 'Monitoring Metrics Publisher' role for custom log ingestion"
$logOperators = @($ConsoleOperatorObjectIds | Where-Object { $null -ne $_ })
if (-not $logOperators.Count) {
  $currentUser = az rest --method get --url 'https://graph.microsoft.com/v1.0/me?$select=id' --subscription $active.id --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $currentUser.id) { throw 'Specify console operator IDs for a noninteractive deployment.' }
  $logOperators = @([guid]$currentUser.id)
}
$dcrInfo = az resource list --subscription $active.id -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Custom-log access discovery failed.' }
$customLogsDcr = @($dcrInfo | Where-Object { $_.name -like '*customlogs*' })
if ($customLogsDcr.Count -ne 1) { throw 'The console custom-log rule was not uniquely resolved.' }
foreach ($operatorId in $logOperators) {
  $existing = @(az role assignment list --scope $customLogsDcr[0].id --role 'Monitoring Metrics Publisher' --subscription $active.id -o json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not inspect custom-log operator access.' }
  if (-not @($existing | Where-Object { $_.principalId -eq $operatorId.ToString() -and $_.scope -ieq $customLogsDcr[0].id }).Count) {
    az role assignment create --assignee-object-id $operatorId --assignee-principal-type User --role 'Monitoring Metrics Publisher' `
      --scope $customLogsDcr[0].id --subscription $active.id --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Custom-log operator access could not be assigned.' }
  }
}
Write-Host '  Custom-log operator access configured. Data-plane RBAC propagation can take up to 30 minutes.' -ForegroundColor Green

# 5. Create the hourly Perf -> Perf_Hourly_CL summary rule (scenario 21 prereq).
#    Bicep created the destination table; the rule itself is REST-only.
Write-Step "Creating summary rule rule-perf-hourly (scenario 21 prereq)"
$summaryRuleScript = Join-Path $PSScriptRoot 'create-summary-rule.ps1'
if (Test-Path $summaryRuleScript) {
  try {
    & $summaryRuleScript -ResourceGroup $ResourceGroup -WorkspaceName $CentralLawName
  } catch {
    Write-Host "  Summary rule provisioning failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Continuing — re-run scripts/create-summary-rule.ps1 manually." -ForegroundColor Yellow
  }
} else {
  Write-Host "  create-summary-rule.ps1 not found — skipping." -ForegroundColor Yellow
}

# 6. Post a release annotation on App Insights so the deploy is visible on charts.
Write-Step "Posting Application Insights release annotation"
$releaseScript = Join-Path $PSScriptRoot 'send-release-annotation.ps1'
if (Test-Path $releaseScript) {
  & $releaseScript -ResourceGroup $ResourceGroup -Name "deploy-$(Get-Date -Format yyyyMMdd-HHmmss)" -Category 'Deployment'
} else {
  Write-Host "  send-release-annotation.ps1 not found — skipping." -ForegroundColor Yellow
}
