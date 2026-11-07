function Get-LabConfigGroups {
  [ordered]@{
    basicConfiguration = @(
      'subscriptionId', 'subscriptionName', 'tenantId', 'resourceGroup',
      'location', 'appServiceLocation', 'observabilityAgentLocation',
      'alertEmail', 'fabricAdminEmail', 'vmAdminUsername', 'vmAdminPassword'
    )
    naming = @('namePrefix')
    compute = @(
      'vmSize', 'vmssSize', 'aksNodeVmSize', 'aksNodeCount',
      'deployWindowsVm', 'deployLinuxVm', '_computeSizingDocs'
    )
    monitoring = @(
      'dailyCapGb', 'enableVmOtelMetrics', '_enableVmOtelMetricsDocs',
      'enableLawReplication', 'lawReplicationLocation', '_lawReplicationLocationDocs',
      'siemWebhookUrl'
    )
    access = @('grafanaAdminObjectId', '_grafanaAdminObjectIdDocs')
    customerApplicationServices = @(
      'slotAppServicePlanSku', 'sqlEntraAdminObjectId', 'sqlEntraAdminName',
      'sqlEntraAdminType', '_customerDependenciesDocs'
    )
    observabilityAgent = @(
      'enableObservabilityAgentAutomaticInvestigation', 'observabilityAgentInstructions'
    )
    safety = @('forbiddenSubscriptionIds')
    fabric = @('fabricAutomation', '_fabricAutomationDocs')
    stageToggles = @()
    other = @()
  }
}

function ConvertTo-FlatLabConfig {
  param([Parameter(Mandatory)] [AllowNull()] [object] $Configuration)

  if ($Configuration -isnot [System.Management.Automation.PSCustomObject]) {
    throw 'Lab configuration must be a JSON object.'
  }
  $flat = [ordered]@{}
  function Add-ConfigProperty($Name, $Value, $Source) {
    if ($flat.Contains($Name)) {
      throw "Duplicate lab configuration key '$Name' at '$Source'. Keep each setting in one place."
    }
    $flat[$Name] = $Value
  }

  $groups = Get-LabConfigGroups
  foreach ($property in $Configuration.PSObject.Properties) {
    if ($property.Name -eq 'basicConfiguration') {
      if ($property.Value -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'basicConfiguration must be a JSON object.'
      }
      foreach ($setting in $property.Value.PSObject.Properties) {
        Add-ConfigProperty $setting.Name $setting.Value "basicConfiguration.$($setting.Name)"
      }
    } elseif ($property.Name -eq 'advancedConfiguration') {
      if ($property.Value -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'advancedConfiguration must be a JSON object.'
      }
      foreach ($group in $property.Value.PSObject.Properties) {
        $groupName = if ($group.Name -eq 'customerDependencies') { 'customerApplicationServices' } else { $group.Name }
        if ($groupName -eq 'basicConfiguration' -or -not $groups.Contains($groupName)) {
          throw "Unknown advancedConfiguration group '$($group.Name)'. See lab.config.json.example."
        }
        if ($group.Value -isnot [System.Management.Automation.PSCustomObject]) {
          throw "advancedConfiguration.$($group.Name) must be a JSON object."
        }
        # These are existing structured settings, not grouping containers.
        if ($group.Name -eq 'stageToggles') {
          Add-ConfigProperty $group.Name $group.Value "advancedConfiguration.$($group.Name)"
        } else {
          foreach ($setting in $group.Value.PSObject.Properties) {
            Add-ConfigProperty $setting.Name $setting.Value "advancedConfiguration.$($group.Name).$($setting.Name)"
          }
        }
      }
    } else {
      Add-ConfigProperty $property.Name $property.Value $property.Name
    }
  }
  [pscustomobject]$flat
}

function Read-LabConfig {
  param([Parameter(Mandatory)] [string] $Path)

  $configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
    ConvertFrom-Json -NoEnumerate -ErrorAction Stop
  ConvertTo-FlatLabConfig -Configuration $configuration
}

function ConvertTo-GroupedLabConfig {
  param([Parameter(Mandatory)] [object] $Configuration)

  $flat = ConvertTo-FlatLabConfig -Configuration $Configuration
  $remaining = [ordered]@{}
  foreach ($property in $flat.PSObject.Properties) {
    $remaining[$property.Name] = $property.Value
  }
  $result = [ordered]@{}
  foreach ($name in @('$schema', 'title', 'description')) {
    if ($remaining.Contains($name)) {
      $result[$name] = $remaining[$name]
      $remaining.Remove($name)
    }
  }
  $advanced = [ordered]@{}
  $groups = Get-LabConfigGroups
  foreach ($group in $groups.Keys) {
    if ($group -eq 'other') { continue }
    if ($group -eq 'stageToggles') {
      if ($remaining.Contains($group)) {
        $advanced[$group] = $remaining[$group]
        $remaining.Remove($group)
      }
      continue
    }
    $settings = [ordered]@{}
    foreach ($name in $groups[$group]) {
      if ($remaining.Contains($name)) {
        $settings[$name] = $remaining[$name]
        $remaining.Remove($name)
      }
    }
    if ($group -eq 'basicConfiguration') {
      $result[$group] = [pscustomobject]$settings
    } elseif ($settings.Count -gt 0) {
      $advanced[$group] = [pscustomobject]$settings
    }
  }
  if ($remaining.Count -gt 0) { $advanced['other'] = [pscustomobject]$remaining }
  $result['advancedConfiguration'] = [pscustomobject]$advanced
  [pscustomobject]$result
}
