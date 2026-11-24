$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $root 'scripts\deploy-azure-monitor-pipeline.ps1'
$asset = Join-Path $root 'workloads\telemetry-ingestion\edge\install-k3s-arc.sh'
$template = Get-Content -Raw (Join-Path $root 'workloads\telemetry-ingestion\edge\syslog-pipeline.arm.json') | ConvertFrom-Json
$global:edgeTemplate = $template
$deployText = Get-Content -Raw (Join-Path $root 'scripts\deploy.ps1')
if ($deployText -notmatch '(?s)if \(\$enableAzureMonitorPipeline\).*?deploy-azure-monitor-pipeline\.ps1.*?-CentralLawId \$outputs\.centralLawId\.value -Enable') {
  throw 'One-shot pipeline opt-in must pass -Enable to the guarded installer.'
}
if ($deployText -notmatch '-EnableCombined:\(\$enableAzureMonitorPipeline -and \$enableTelemetryIngestion\)' -or
    $deployText -notmatch '\$enableTelemetryIngestion = \$labCfg\.stageToggles\.enableStageTelemetryIngestion -eq \$true') {
  throw 'Combined opt-in must require both independent stage toggles.'
}
$associationNames = @($template.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRuleAssociations' | ForEach-Object name)
if ($associationNames.Count -ne 4 -or
    $associationNames -cnotcontains "[format('{0}-settings-assoc', parameters('namePrefix'))]" -or
    $associationNames -cnotcontains "[format('{0}-flow-assoc', parameters('namePrefix'))]" -or
    $associationNames -cnotcontains "[format('{0}-operational-assoc', parameters('namePrefix'))]" -or
    $associationNames -cnotcontains "[format('{0}-diagnostic-assoc', parameters('namePrefix'))]") {
  throw 'Offline association fixtures no longer match the deployed ARM template.'
}
if ($template.parameters.enableCombined.defaultValue -ne $false -or
    @($template.resources | Where-Object { $_.condition -eq "[parameters('enableCombined')]" }).Count -ne 6) {
  throw 'Combined template resources must be explicitly conditioned and default off.'
}
$dcrResources = @($template.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')
if ($dcrResources.Count -ne 4) { throw 'Expected independent settings, Syslog, Operational, and Diagnostic DCRs.' }
$roles = @($template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
if ($roles.Count -ne 3 -or
    @($roles | Where-Object { $_.scope -notin @("[variables('flowId')]","[variables('operationalId')]","[variables('diagnosticId')]") }).Count -ne 0 -or
    @($roles | Where-Object { $_.scope -ne "[variables('flowId')]" -and $_.condition -ne "[parameters('enableCombined')]" }).Count) {
  throw 'Every conditional dataflow needs its own scoped publisher assignment.'
}
$original = @($dcrResources | Where-Object name -eq "[variables('flowName')]")
if ($original.Count -ne 1 -or $original[0].properties.dataFlows[0].streams[0] -cne 'Microsoft-Syslog-FullyFormed' -or
    $original[0].properties.dataFlows[0].PSObject.Properties.Name -contains 'outputStream') {
  throw 'Original Syslog-to-Syslog flow changed.'
}
foreach ($spec in @(@('operational',50),@('diagnostic',60))) {
  $suffix = $spec[0]; $limit = $spec[1]
  $dcr = @($dcrResources | Where-Object name -eq "[variables('$($suffix)Name')]")
  if ($dcr.Count -ne 1 -or $dcr[0].condition -cne "[parameters('enableCombined')]" -or
      $dcr[0].properties.references.pipelineSettingsEndpointRouting[0].name -cne 'syslog-tcp-6514' -or
      $dcr[0].properties.dataSources.syslog[0].streams[0] -cne 'Microsoft-Syslog-FullyFormed' -or
      $dcr[0].properties.dataFlows[0].outputStream -cne "Custom-TelemetryIngestion$($suffix.Substring(0,1).ToUpperInvariant())$($suffix.Substring(1))_CL" -or
      $dcr[0].properties.dataFlows[0].transformKql -notmatch "EventId\)\) <= $limit" -or
      $dcr[0].properties.dataFlows[0].transformKql -notmatch 'SyntheticUser = "\[REDACTED\]"' -or
      $dcr[0].properties.dataFlows[0].transformKql -notmatch 'NormalizedSeverity = case' -or
      $dcr[0].properties.transformations[0].processors[0].configuration.expression -notmatch 'EdgeDropFlag') {
    throw "Combined $suffix dataflow does not preserve exact fixture/schema/filter contract."
  }
}
$target = Get-Content -Raw (Join-Path $root '.azure-target.json') | ConvertFrom-Json
$script:sub = $target.expectedSubscriptionId
$script:tenant = $target.expectedTenantId
$script:rg = 'rg-offline-edge'
$script:vm = 'linux-offline'
$script:prefix = 'offline'
$script:region = 'northeurope'
$script:rgId = "/subscriptions/$sub/resourceGroups/$rg"
$script:vmId = "$rgId/providers/Microsoft.Compute/virtualMachines/$vm"
$global:edgeFixtureVmId = $vmId
$script:clusterId = "$rgId/providers/Microsoft.Kubernetes/connectedClusters/$prefix-edge"
$script:extId = "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/azure-monitor-pipeline"
$script:lawId = "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-offline"
$script:parameters = @{
  SubscriptionId = $sub; TenantId = $tenant; ResourceGroup = $rg
  VmName = $vm; NamePrefix = $prefix; Location = $region; CentralLawId = $lawId
}
function Assert-Fails {
  param([scriptblock] $Action, [string] $Match)
  $failed = $false
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Match) { throw "Unexpected failure: $($_.Exception.Message) at $($_.ScriptStackTrace)" }
    $failed = $true
  }
  if (-not $failed) { throw "Expected failure matching $Match" }
}
foreach ($file in @($scriptPath, $asset)) {
  if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file" }
}
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw "Bootstrap PowerShell syntax: $($errors[0])" }
$text = Get-Content -Raw $asset
if ($text -notmatch 'v1\.33\.3%2Bk3s1' -or
    $text -notmatch 'f03cad6610cf5b2903d8a9ac3d6716690e53dab461b09c07b0c913a262166abc' -or
    $text -match 'curl\s+[^`n]*\|\s*(bash|sh)') { throw 'Remote K3s version/checksum/install policy mismatch.' }

$global:edgeCalls = [Collections.Generic.List[string]]::new()
$global:edgeExisting = $false
$global:edgeFailure = ''
$global:edgeForeignVm = $false
$global:edgeForeignOwner = $false
$global:edgePartialDcr = $false
$global:edgeMissingTable = ''
$global:edgeWrongPlan = ''
$global:edgeWrongSchema = ''
$global:edgeForeignTableType = ''
$global:edgeForeignDcr = ''
$global:edgeRemoteModes = [Collections.Generic.List[string]]::new()
function global:az {
  $parts = @($args | ForEach-Object { [string]$_ })
  $key = ($parts -join ' ')
  $global:edgeCalls.Add($key)
  $global:LASTEXITCODE = 0
  $response = $null
  switch -Regex ($key) {
    '^account show ' { $response = @{ id = $sub; tenantId = $tenant }; break }
    '^vm show ' {
      $response = @{ id = $global:edgeFixtureVmId
        location = $region
        storageProfile = @{ osDisk = @{ osType = 'Linux' }; imageReference = @{
          publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2'
        } }
        identity = @{ type = 'SystemAssigned'; principalId = 'c0d91a85-3d9b-4005-a3dd-ae75b109ca34' }
        hardwareProfile = @{ vmSize = 'Standard_D4s_v5' }
      }; break
    }
    '^vm list-skus ' { $response = @(@{ name = 'Standard_D4s_v5'; resourceType = 'virtualMachines'
      restrictions = @(); capabilities = @(@{name='vCPUs';value='4'},@{name='MemoryGB';value='16'}) }); break }
    '^vm get-instance-view ' { $response = @{ instanceView = @{
      statuses = @(@{code='PowerState/running'},@{code='ProvisioningState/succeeded'})
      vmAgent = @{ statuses = $(if ($global:edgeFailure -eq 'agent') { @(@{code='ProvisioningState/unavailable'}) } else {
        @(@{code='ProvisioningState/succeeded'})
      }) } } }; break }
    '^resource show .*OperationalInsights/workspaces/' {
      if ($key -match '/tables/(TelemetryIngestionOperational_CL|TelemetryIngestionDiagnostic_CL)') {
        $tableName = $Matches[1]
        if ($global:edgeMissingTable -eq $tableName) { $global:LASTEXITCODE = 1; return }
        $columns = @('TimeGenerated','RunId','EventId','SampleSetId','Severity','NormalizedSeverity','Workload','Message','SyntheticUser') |
          ForEach-Object { @{name=$_;type=$(if ($_ -eq 'TimeGenerated') {'datetime'} else {'string'})} }
        if ($global:edgeWrongSchema -eq $tableName) { $columns[0].type = 'string' }
        $response = @{ id="$lawId/tables/$tableName"
          properties=@{plan=$(if ($global:edgeWrongPlan -eq $tableName) {'Auxiliary'} else {'Analytics'})
            schema=@{name=$tableName;columns=$columns}} }
        if ($global:edgeForeignTableType -eq $tableName) { $response.type = 'Microsoft.OperationalInsights/workspaces' }
      } else {
        $response = @{ id = $lawId; location = $region; type = 'Microsoft.OperationalInsights/workspaces' }
      }
      break
    }
    '^provider show ' {
      $ns = $parts[[array]::IndexOf($parts,'--namespace')+1]
      $type = switch ($ns) {
        'Microsoft.Kubernetes' { 'connectedClusters' }
        'Microsoft.KubernetesConfiguration' { 'extensions' }
        'Microsoft.Insights' { 'dataCollectionRules' }
        default { 'unused' }
      }
      $response = @{ registrationState = $(if ($global:edgeFailure -eq 'provider' -and $ns -eq 'Microsoft.Kubernetes') { 'NotRegistered' } else { 'Registered' })
        resourceTypes = @(@{ resourceType = $type; locations = @('North Europe') },
          @{resourceType='dataCollectionRuleAssociations';locations=@('North Europe')}) }; break
    }
    '^extension show --name k8s-extension ' { $response = @{name='k8s-extension'}; break }
    '^k8s-extension extension-types list-by-location ' {
      $train = $parts[[array]::IndexOf($parts,'--release-train')+1]
      $name = if ($train -eq 'preview') { 'microsoft.monitor.pipeline' } elseif ($train -eq 'stable') { 'microsoft.certmanagement' } else { throw "Unexpected train: $train" }
      $response = @(@{name=$name;properties=@{supportedClusterTypes=@('connectedClusters')}}); break
    }
    '^k8s-extension extension-types show-version-by-location ' { $response = @{properties=@{version='0.1.7'}}; break }
    '^rest ' { $response = @{ value = @(@{ actions = @($(if ($global:edgeFailure -eq 'permission') {
      'Microsoft.Compute/virtualMachines/runCommand/action'
    } else { '*' })); notActions = @() }) }; break }
    '^role assignment list ' {
      $response = if ($global:edgeFailure -eq 'role') { @() } else { @(@{roleDefinitionName='Kubernetes Cluster - Azure Arc Onboarding'}) }
      break
    }
    '^resource list .*Microsoft.Kubernetes/connectedClusters' {
      $response = if ($global:edgeExisting) { @(@{ id=$clusterId; name="$prefix-edge"; location=$region
        tags=@{'azure-monitor-lab-edge-vm'=$(if ($global:edgeForeignOwner) { 'another-vm' } else { $vmId })}
        properties=@{provisioningState='Succeeded';connectivityStatus='Connected'} }) } else { @() }
      break
    }
    '^resource list .*Microsoft.KubernetesConfiguration/extensions' {
      $response = if ($global:edgeExisting) { @(
        @{id="$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/azure-cert-management";name='azure-cert-management'
          properties=@{extensionType='microsoft.certmanagement';provisioningState='Succeeded';releaseTrain='stable';autoUpgradeMinorVersion=$true}},
        @{id=$extId;name='azure-monitor-pipeline';identity=@{type='SystemAssigned'}
          properties=@{extensionType='microsoft.monitor.pipeline';provisioningState='Succeeded';version='0.1.7';releaseTrain='preview';autoUpgradeMinorVersion=$false}}
      ) } else { @() }
      break
    }
    '^resource list .*Microsoft.Insights/dataCollectionRules' {
      $response = if ($global:edgeExisting -or $global:edgePartialDcr) { @(
        @{id="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-settings";name="$prefix-settings"
          kind='PipelineSettings';properties=@{provisioningState='Succeeded'}},
        @{id="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-syslog";name="$prefix-syslog"
          properties=@{provisioningState='Succeeded';destinations=@{logAnalytics=@(@{workspaceResourceId=$lawId})}
            dataSources=@{syslog=@(@{allowedFormats=@('syslogRfc5424')})}
            transformations=@(@{processors=@(@{configuration=@{expression='source | where EdgeDropFlag != "true"'}})})}}
      ) + $(if ($global:edgeExisting) { @('operational','diagnostic') | ForEach-Object {
        $suffix = $_
        $templateDcr = @($global:edgeTemplate.resources | Where-Object name -eq "[variables('$($suffix)Name')]")[0]
        @{id="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-$suffix";name="$prefix-$suffix"
          properties=@{provisioningState='Succeeded';destinations=@{logAnalytics=@(@{workspaceResourceId=$lawId})}
            dataSources=@{syslog=@(@{allowedFormats=@('syslogRfc5424');endpointRouting=@('syslog-tcp-6514')})}
            references=@{pipelineSettingsEndpointRouting=@(@{pipelineSettingsResourceId="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-settings"})}
            dataFlows=@(@{outputStream=$(if ($global:edgeForeignDcr -eq $suffix) {'Custom-Foreign_CL'} else {"Custom-TelemetryIngestion$($suffix.Substring(0,1).ToUpperInvariant())$($suffix.Substring(1))_CL"})
              transformKql=$templateDcr.properties.dataFlows[0].transformKql})
            transformations=@(@{processors=@(@{configuration=@{
              expression=$templateDcr.properties.transformations[0].processors[0].configuration.expression}})})}}
      }} else {@()}) } else { @() }
      break
    }
    '^resource list .*Microsoft.Insights/dataCollectionRuleAssociations' {
      $response = if ($global:edgeExisting) { @(@('settings','flow','operational','diagnostic') | ForEach-Object {
        $dcrSuffix = if ($_ -eq 'flow') { 'syslog' } else { $_ }
        @{id="$clusterId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$prefix-$_-assoc";name="$prefix-$_-assoc"
          properties=@{ dataCollectionRuleId="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-$dcrSuffix"
            scopeToResourceId=$extId }}
      }) } else { @() }
      break
    }
    '^vm run-command invoke ' {
      $start = [array]::IndexOf($parts,'--parameters')
      $mode = $parts[$start+1]
      if ($parts[$start+2] -ne $sub -or $parts[$start+3] -ne $tenant -or
          $parts[$start+4] -ne $rg -or $parts[$start+5] -ne "$prefix-edge" -or
          $parts[$start+6] -ne $region -or $parts[$start+7] -ne $vmId -or
          $parts[$start+8] -notin @('true','false') -or $parts[$start+9] -ne '-o') {
        throw 'Remote Run Command positional arguments do not match the installer contract.'
      }
      $global:edgeRemoteModes.Add($mode)
      $marker = if ($global:edgeFailure -eq $mode) { 'PIPELINE_DENIED' } elseif ($mode -eq 'preflight') { 'PIPELINE_PREFLIGHT_OK' } else { 'PIPELINE_INSTALL_OK' }
      $response = @{value=@(@{code='ComponentStatus/StdOut/succeeded';message="[stdout]`n$marker`n"})}
      if ($global:edgeFailure -eq 'native' -and $mode -eq 'install') { $global:LASTEXITCODE = 1 }
      break
    }
    '^resource show .*Microsoft.Kubernetes/connectedClusters/' {
      if ($key -match 'dataCollectionRuleAssociations') {
        $suffix = if ($key -match 'settings-assoc') { 'settings' } elseif ($key -match 'operational-assoc') {
          'operational'
        } elseif ($key -match 'diagnostic-assoc') { 'diagnostic' } else { 'flow' }
        $dcrSuffix = if ($suffix -eq 'flow') { 'syslog' } else { $suffix }
        $response = @{ id="$clusterId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$prefix-$suffix-assoc"
          properties=@{ dataCollectionRuleId="$rgId/providers/Microsoft.Insights/dataCollectionRules/$prefix-$dcrSuffix"
            scopeToResourceId=$extId } }
      } elseif ($key -match 'KubernetesConfiguration/extensions') {
        $isPipeline = $key -match 'azure-monitor-pipeline'
        $response = @{ id=$(if ($isPipeline) { $extId } else { "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/azure-cert-management" })
          identity=@{type='SystemAssigned';principalId='00000000-0000-4000-8000-000000000001'}
          properties=@{extensionType=$(if ($isPipeline) { 'microsoft.monitor.pipeline' } else { 'microsoft.certmanagement' })
            version='0.1.7';provisioningState='Succeeded';installState='Installed'
            releaseTrain=$(if ($isPipeline) { 'preview' } else { 'stable' })
            autoUpgradeMinorVersion=(-not $isPipeline)} }
      } else {
        $response = @{id=$clusterId;tags=@{'azure-monitor-lab-edge-vm'=$vmId};properties=@{provisioningState='Succeeded';connectivityStatus='Connected'}}
      }
      break
    }
    '^resource show .*Microsoft.Insights/dataCollectionRules/' {
      $id = $parts[[array]::IndexOf($parts,'--ids')+1]
      $suffix = if ($id -match '-operational$') { 'Operational' } elseif ($id -match '-diagnostic$') { 'Diagnostic' } else { '' }
      $response = @{id=$id;properties=@{provisioningState='Succeeded'
        destinations=@{logAnalytics=@(@{workspaceResourceId=$lawId})}
        dataFlows=@(@{outputStream="Custom-TelemetryIngestion${suffix}_CL"
          transformKql='source | project SyntheticUser = "[REDACTED]"'})}}; break
    }
    '^deployment group create ' {
      if ($global:edgeFailure -eq 'extensions' -and $key -match 'edge-extensions') { $global:LASTEXITCODE = 1; return }
      $response = @{properties=@{provisioningState='Succeeded'}}; break
    }
    default { throw "Unexpected Azure command in offline test: $key" }
  }
  ConvertTo-Json -InputObject $response -Depth 16 -Compress
}
try {
  Assert-Fails { & $scriptPath @parameters } 'default-off'
  if ($global:edgeCalls.Count) { throw 'Default-off attempted an Azure call.' }
  Assert-Fails { & $scriptPath @parameters -Enable -VmName 'other-vm' } 'VM identity|exact ID'
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Wrong VM entered a mutable stage.'
  }
  $global:edgeCalls.Clear()
  $global:edgeFailure = 'agent'
  Assert-Fails { & $scriptPath @parameters -Enable } 'VM Agent ready'
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Unready VM agent entered a mutable stage.'
  }
  $global:edgeFailure = ''
  $global:edgeFailure = 'provider'
  Assert-Fails { & $scriptPath @parameters -Enable } 'not registered'
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Provider denial entered a mutable stage.'
  }
  $global:edgeFailure = 'role'
  Assert-Fails { & $scriptPath @parameters -Enable } 'Arc Onboarding'
  $global:edgeFailure = 'permission'
  Assert-Fails { & $scriptPath @parameters -Enable } 'runCommands/write'
  $global:edgeFailure = ''
  Assert-Fails { & $scriptPath @parameters -Enable -EnableCombined } 'requires both stageToggles'
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Combined prerequisite denial entered a mutable stage.'
  }
  $combined = @{ StageTelemetryIngestionEnabled = $true; StageAzureMonitorPipelineEnabled = $true; EnableCombined = $true }
  foreach ($tableName in @('TelemetryIngestionOperational_CL','TelemetryIngestionDiagnostic_CL')) {
    $global:edgeMissingTable = $tableName
    Assert-Fails { & $scriptPath @parameters -Enable @combined } 'Stage90 table'
    $global:edgeMissingTable = ''
    $global:edgeWrongPlan = $tableName
    Assert-Fails { & $scriptPath @parameters -Enable @combined } 'not Analytics'
    $global:edgeWrongPlan = ''
    $global:edgeWrongSchema = $tableName
    Assert-Fails { & $scriptPath @parameters -Enable @combined } 'wrong schema'
    $global:edgeWrongSchema = ''
    $global:edgeForeignTableType = $tableName
    Assert-Fails { & $scriptPath @parameters -Enable @combined } 'wrong schema'
    $global:edgeForeignTableType = ''
  }
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Bad Stage90 table entered a mutable stage.'
  }
  $global:edgeExisting = $true
  $global:edgeForeignDcr = 'diagnostic'
  Assert-Fails { & $scriptPath @parameters -Enable @combined } 'foreign or unverified'
  $global:edgeForeignDcr = ''
  $global:edgeExisting = $false
  $global:edgeExisting = $true
  $global:edgeForeignOwner = $true
  $global:edgeCalls.Clear()
  Assert-Fails { & $scriptPath @parameters -Enable } 'foreign or unhealthy'
  if (@($global:edgeCalls | Where-Object { $_ -match '^vm run-command|^deployment group create' }).Count) {
    throw 'Foreign Arc cluster entered a mutable stage.'
  }
  $global:edgeForeignOwner = $false
  $global:edgeExisting = $false
  $global:edgePartialDcr = $true
  Assert-Fails { & $scriptPath @parameters -Enable } 'partially deployed'
  $global:edgePartialDcr = $false
  $global:edgeFailure = 'preflight'
  Assert-Fails { & $scriptPath @parameters -Enable } 'success marker'
  if (@($global:edgeRemoteModes | Where-Object { $_ -eq 'install' }).Count) { throw 'Install ran after failed remote preflight.' }
  $global:edgeFailure = 'install'
  Assert-Fails { & $scriptPath @parameters -Enable } 'success marker'
  if (@($global:edgeCalls | Where-Object { $_ -match '^deployment group create' }).Count) { throw 'Deployment ran after failed installation.' }
  $global:edgeFailure = 'native'
  Assert-Fails { & $scriptPath @parameters -Enable } 'Remote install failed'
  $global:edgeFailure = 'extensions'
  Assert-Fails { & $scriptPath @parameters -Enable } 'extension deployment failed'
  if (@($global:edgeCalls | Where-Object { $_ -match '^deployment group create .*edge-syslog' }).Count) {
    throw 'Syslog deployment ran after failed extensions.'
  }
  $global:edgeFailure = ''
  $global:edgeCalls.Clear()
  $result = & $scriptPath @parameters -Enable
  if ($result.LiveIngestion -notmatch 'NOT VERIFIED' -or
      @($global:edgeCalls | Where-Object { $_ -match '^deployment group create ' }).Count -ne 2) {
    throw 'Fresh bootstrap did not finish in accepted/not-live-verified state.'
  }
  $global:edgeCalls.Clear()
  $result = & $scriptPath @parameters -Enable @combined
  if (-not $result.Combined -or
      @($global:edgeCalls | Where-Object { $_ -match '^deployment group create .*enableCombined=true' }).Count -ne 1 -or
      @($global:edgeCalls | Where-Object { $_ -match '^resource show .*dataCollectionRuleAssociations/.*-(operational|diagnostic)-assoc' }).Count -ne 2) {
    throw 'Combined deployment did not route and verify both custom-table DCRs.'
  }
  $global:edgeCalls.Clear()
  $global:edgeExisting = $true
  $result = & $scriptPath @parameters -Enable
  if ($result.LiveIngestion -notmatch 'NOT VERIFIED' -or
      @($global:edgeCalls | Where-Object { $_ -match 'vm run-command invoke .*--parameters (preflight|install) .* true -o json' }).Count -ne 2) {
    throw 'Repeated run did not preserve the owned Arc connection.'
  }
  Write-Output 'PASS: offline opt-ins, exact ARM names/streams, Stage90 schema/plan, foreign resources, remote failures and reruns.'
} finally {
  Remove-Item function:\az -ErrorAction SilentlyContinue
}
