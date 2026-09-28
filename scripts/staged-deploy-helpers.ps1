<#
.SYNOPSIS
  Load the account guard and stage deployment helper into the current session.

.DESCRIPTION
  Dot-source this file from the repository root after the Bicep guide's input
  bootstrap. Loading it replaces old function definitions without changing the
  bootstrap variables or making Azure calls.

.EXAMPLE
  . ./scripts/staged-deploy-helpers.ps1
#>

function Assert-LabAccount {
  az account set --subscription $sub
  if ($LASTEXITCODE -ne 0) { throw 'Could not select the lab subscription.' }
  $account = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $account.id -ne $sub.ToString() -or $account.tenantId -ne $tenant.ToString()) {
    throw 'Subscription or tenant mismatch. Stop before deploying.'
  }
}

function Invoke-LabStage {
  param(
    [ValidateSet('00-foundation', '10-workloads', '20-alerting', '30-security-posture', '40-optional-advanced', '41-sentinel-content', '50-ai', '60-sre-agent', '70-observability-agent')]
    [string] $Stage,
    [hashtable] $Overrides = @{}
  )
  $schema = Get-Content "./infra/stages/$Stage.json" -Raw | ConvertFrom-Json -AsHashtable
  $parameters = @{}
  foreach ($name in $schema.parameters.Keys) {
    if ($sourceParameters.ContainsKey($name)) { $parameters[$name] = $sourceParameters[$name] }
  }
  foreach ($name in $Overrides.Keys) {
    if (-not $schema.parameters.ContainsKey($name)) { throw "Unknown parameter '$name' for $Stage." }
    if ($schema.parameters[$name].type -like 'secure*') { throw 'Supply secure inputs through the private parameters file, not Overrides.' }
    $parameters[$name] = @{ value = $Overrides[$name] }
  }
  foreach ($name in $schema.parameters.Keys) {
    if (-not $parameters.ContainsKey($name) -and -not $schema.parameters[$name].ContainsKey('defaultValue')) {
      throw "Missing required parameter '$name' for $Stage."
    }
  }
  $parameterFile = New-TemporaryFile
  try {
    if (-not $IsWindows) {
      [IO.File]::SetUnixFileMode($parameterFile.FullName, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
      ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterFile.FullName
    $deploymentArguments = @('--subscription', $sub.ToString(), '--resource-group', $rg,
      '--name', "stage-$Stage", '--template-file', "infra/stages/$Stage.bicep",
      '--parameters', "@$($parameterFile.FullName)", '--mode', 'Incremental')
    Assert-LabAccount
    az deployment group what-if @deploymentArguments
    if ($LASTEXITCODE -ne 0) { throw "Preview failed for $Stage." }
    if ((Read-Host 'Deploy this stage? Type yes to continue') -ne 'yes') { throw 'Stage deployment cancelled.' }
    Assert-LabAccount
    az deployment group create @deploymentArguments --output none
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed for $Stage." }
  } finally {
    Remove-Item -LiteralPath $parameterFile.FullName -Force
  }
}