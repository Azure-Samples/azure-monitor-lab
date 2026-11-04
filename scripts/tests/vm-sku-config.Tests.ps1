$ErrorActionPreference = 'Stop'
$repoRoot = Join-Path $PSScriptRoot '..\..'
$root = Join-Path $PSScriptRoot "vm-sku-config-fixture-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts'), (Join-Path $root 'infra'), (Join-Path $root 'terraform') -Force
$helper = Join-Path $root 'scripts\sync-config.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\sync-config.ps1') -Destination $helper
$configPath = Join-Path $root 'lab.config.json'
$config = @{
  subscriptionId = [guid]::NewGuid().ToString()
  tenantId = [guid]::NewGuid().ToString()
  alertEmail = 'operator@example.com'
  vmAdminPassword = [guid]::NewGuid().ToString()
  resourceGroup = 'test-rg'
  location = 'northeurope'
  appServiceLocation = 'uksouth'
  namePrefix = 'test'
  vmSize = 'Standard_EC2as_v5'
  aksNodeVmSize = 'Standard_EC2as_v5'
  vmssSize = 'Standard_EC2as_v5'
}

try {
  $config | ConvertTo-Json | Set-Content -LiteralPath $configPath
  & $helper -ConfigPath $configPath

  $bicep = Get-Content -LiteralPath (Join-Path $root 'infra\main.parameters.json') -Raw | ConvertFrom-Json
  foreach ($name in @('vmSize', 'aksNodeVmSize', 'vmssSize')) {
    if ($bicep.parameters.$name.value -ne 'Standard_EC2as_v5') {
      throw "Bicep parameter '$name' did not preserve the configured SKU."
    }
    if ($bicep.parameters.appServiceLocation.value -ne 'uksouth') {
      throw 'Bicep appServiceLocation did not preserve the configured region.'
    }
  }

  $terraform = Get-Content -LiteralPath (Join-Path $root 'terraform\stages.tfvars') -Raw
  foreach ($name in @('vm_size', 'aks_node_vm_size', 'vmss_size')) {
    if ($terraform -notmatch "(?m)^$name\s*=\s*`"Standard_EC2as_v5`"\r?$") {
      throw "Terraform variable '$name' did not preserve the configured SKU."
    }
    if ($terraform -notmatch '(?m)^app_service_location\s*=\s*"uksouth"\r?$') {
      throw 'Terraform app_service_location did not preserve the configured region.'
    }
  }

  $example = Get-Content -LiteralPath (Join-Path $repoRoot 'lab.config.json.example') -Raw | ConvertFrom-Json
  $template = Get-Content -LiteralPath (Join-Path $repoRoot 'infra\main.parameters.json.template') -Raw | ConvertFrom-Json
  foreach ($name in @('vmSize', 'aksNodeVmSize', 'vmssSize')) {
    if ([string]::IsNullOrWhiteSpace($example.$name) -or [string]::IsNullOrWhiteSpace($template.parameters.$name.value)) {
      throw "Example inputs must expose '$name'."
    }
    if ([string]::IsNullOrWhiteSpace($example.appServiceLocation) -or [string]::IsNullOrWhiteSpace($template.parameters.appServiceLocation.value)) {
      throw 'Example inputs must expose appServiceLocation.'
    }
  }

  $ui = Get-Content -LiteralPath (Join-Path $repoRoot 'infra\createUiDefinition.json') -Raw | ConvertFrom-Json
  $vmssControl = @($ui.parameters.steps | Where-Object name -eq 'workloads').elements | Where-Object name -eq 'vmssSize'
  if ($null -eq $vmssControl -or $ui.parameters.outputs.vmssSize -ne "[steps('workloads').vmssSize]") {
    throw 'Portal deployment must expose and output vmssSize.'
  }
  $appServiceLocationControl = @($ui.parameters.steps | Where-Object name -eq 'workloads').elements | Where-Object name -eq 'appServiceLocation'
  if ($null -eq $appServiceLocationControl -or $ui.parameters.outputs.appServiceLocation -ne "[steps('workloads').appServiceLocation]") {
    throw 'Portal deployment must expose and output appServiceLocation.'
  }

  $deploy = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\deploy.ps1') -Raw
  foreach ($argument in @('-VmSize $pfVmSize', '-AksNodeVmSize $pfAksNodeVmSize', '-VmssSize $pfVmssSize')) {
    if (-not $deploy.Contains($argument)) { throw "Deployment pre-flight is missing '$argument'." }
  }
  if (-not $deploy.Contains('-AppServiceLocation $pfAppServiceLocation')) {
    throw 'Deployment pre-flight is missing the configured App Service region.'
  }

  foreach ($moduleName in @('vm-linux.bicep', 'vm-windows.bicep', 'vmss.bicep')) {
    $module = Get-Content -LiteralPath (Join-Path $repoRoot "infra\modules\$moduleName") -Raw
    foreach ($required in @("securityType: 'ConfidentialVM'", "securityEncryptionType: 'VMGuestStateOnly'", 'secureBootEnabled: true', 'vTpmEnabled: true')) {
      if (-not $module.Contains($required)) {
        throw "$moduleName must configure '$required' for ECasv5 and ECadsv5 SKUs."
      }
    }
  }

  foreach ($moduleName in @('vm-linux.bicep', 'vm-windows.bicep')) {
    $module = Get-Content -LiteralPath (Join-Path $repoRoot "infra\modules\$moduleName") -Raw
    $publicIp = [regex]::Match($module, "(?s)resource pip .*?^}", [System.Text.RegularExpressions.RegexOptions]::Multiline).Value
    if ($publicIp -match '(?m)^\s*tags:') {
      throw "$moduleName must not add tags while creating a public IP because Azure treats that as BYOIP in affected subscriptions."
    }
  }

  Write-Host 'PASS: VM, AKS, and VMSS SKU configuration flows through generated inputs and deployment surfaces.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
