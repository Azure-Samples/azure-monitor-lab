[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $WebAppName,
  [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $CustomerWebAppName = '',
  [string] $CentralLawName,
  [string] $SreModelEndpoint,
  [string] $SreModelDeployment,
  [guid[]] $ConsoleOperatorObjectIds
)

$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroup/$WebAppName", 'Provision console runner and sign-in access, then publish the lab Web App')) { return }
az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not select the deployment subscription.' }
$account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
  throw 'Subscription or tenant mismatch. No Web App changes were made.'
}
$web = az webapp show --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName `
  --query '{kind:kind,host:defaultHostName}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $web.host -or $web.kind -notmatch 'linux') { throw 'The target must be an existing Linux Web App.' }
$publicationTargets = @(@{ Name = $WebAppName; Host = $web.host; Description = 'Control Center' })
if ($CustomerWebAppName) {
  if ($CustomerWebAppName -cne "$WebAppName-customer") { throw 'The customer Web App must use the dedicated name derived from the Control Center.' }
  $customerWeb = az webapp show --subscription $SubscriptionId --resource-group $ResourceGroup --name $CustomerWebAppName `
    --query '{kind:kind,host:defaultHostName}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $customerWeb.host -or $customerWeb.kind -notmatch 'linux') {
    throw 'The customer target must be an existing Linux Web App.'
  }
  $publicationTargets += @{ Name = $CustomerWebAppName; Host = $customerWeb.host; Description = 'customer Web App' }
}
$runtime = az webapp config show --subscription $SubscriptionId --resource-group $ResourceGroup --name $WebAppName `
  --query linuxFxVersion --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or $runtime -ne 'DOTNETCORE|8.0') { throw 'The target must already use the .NET8 Linux runtime.' }
$publish = Join-Path ([IO.Path]::GetTempPath()) "amlab-webapp-$([guid]::NewGuid().ToString('N'))"
$archive = "$publish.zip"
$deploymentId = [guid]::NewGuid().ToString('N')
try {
  dotnet publish (Join-Path $PSScriptRoot '../workloads/webapp/AmlabHello.csproj') -c Release -o $publish --nologo "-p:InformationalVersion=$deploymentId" '-p:IncludeSourceRevisionInInformationalVersion=false'
  if ($LASTEXITCODE -ne 0) { throw 'Web App publish failed. Nothing was deployed.' }
  & (Join-Path $PSScriptRoot 'prepare-webapp-package.ps1') -PublishDirectory $publish -ResourceGroup $ResourceGroup `
    -SubscriptionId $SubscriptionId -TenantId $TenantId -CentralLawName $CentralLawName `
    -CustomerWebAppName $CustomerWebAppName -SreModelEndpoint $SreModelEndpoint -SreModelDeployment $SreModelDeployment
  & (Join-Path $PSScriptRoot 'initialize-webapp-console.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId `
    -ResourceGroup $ResourceGroup -WebAppName $WebAppName -CustomerWebAppName $CustomerWebAppName `
    -ConsoleConfigPath (Join-Path $publish 'lab-console.json') -AllowedUserObjectIds $ConsoleOperatorObjectIds
  Write-Host '==> Compressing the Web App package (including the bundled MCP runtime)' -ForegroundColor Cyan
  Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $archive
  foreach ($target in $publicationTargets) {
    az webapp config appsettings set --subscription $SubscriptionId --resource-group $ResourceGroup --name $target.Name `
      --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not configure prebuilt ZIP deployment for $($target.Description)." }
    az webapp config set --subscription $SubscriptionId --resource-group $ResourceGroup --name $target.Name `
      --startup-file 'dotnet AmlabHello.dll' --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not configure the Web App startup command for $($target.Description)." }
    Write-Host "==> Uploading Web App package to $($target.Name) ($([Math]::Round((Get-Item -LiteralPath $archive).Length / 1MB, 1)) MiB)" -ForegroundColor Cyan
    az webapp deploy --subscription $SubscriptionId --resource-group $ResourceGroup --name $target.Name `
      --src-path $archive --type zip --restart true --async true --track-status false --output none --only-show-errors
    $deployExitCode = $LASTEXITCODE
    if ($deployExitCode -ne 0) {
      Write-Warning "Azure CLI returned exit code $deployExitCode for the ZIP upload. Verifying the expected application version before deciding whether it failed; no retry will be submitted."
    }
    try {
      & (Join-Path $PSScriptRoot 'wait-webapp-publication.ps1') -WebAppHost $target.Host -DeploymentId $deploymentId
    } catch {
      if ($deployExitCode -ne 0) {
        throw "The expected application version '$deploymentId' was not verified on $($target.Description) after Azure CLI returned exit code $deployExitCode. No additional ZIP upload was submitted. $($_.Exception.Message)"
      }
      throw
    }
  }
  if ($CustomerWebAppName) {
    & (Join-Path $PSScriptRoot 'prepare-broken-slot.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
      -WebAppName $CustomerWebAppName -ArchivePath $archive -DeploymentId $deploymentId
  }
  Write-Host "Web App code deployment completed: https://$($web.host)"
  if ($CustomerWebAppName) { Write-Host "Customer Web App code deployment completed: https://$($customerWeb.host)" }
  Write-Host 'Web App and its console runner/access configuration are ready. No AKS workloads or lab actions were applied.'
} finally {
  Remove-Item -LiteralPath $publish -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}