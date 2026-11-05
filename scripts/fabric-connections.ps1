function Ensure-FabricWorkspaceIdentity {
  param([Parameter(Mandatory)] [string] $WorkspaceId)
  $uri = "$fabricApi/workspaces/$WorkspaceId"
  $workspaceDetails = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:fabricHeaders
  if (-not $workspaceDetails.workspaceIdentity.servicePrincipalId) {
    New-FabricItem -Path "workspaces/$WorkspaceId/provisionIdentity" -Body @{} | Out-Null
    $workspaceDetails = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:fabricHeaders
  }
  if (-not $workspaceDetails.workspaceIdentity.servicePrincipalId) {
    throw 'Fabric workspace identity is not ready after provisioning. Verify workspace-admin permissions and rerun.'
  }
  return $workspaceDetails.workspaceIdentity
}

function Grant-FabricSourceRole {
  param(
    [Parameter(Mandatory)] [string] $PrincipalId,
    [Parameter(Mandatory)] [string] $Scope,
    [Parameter(Mandatory)] [string] $RoleId
  )
  $assignments = @(az role assignment list --subscription $SubscriptionId --assignee-object-id $PrincipalId `
    --scope $Scope --include-inherited --output json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw "Cannot inspect source RBAC at '$Scope'." }
  if (@($assignments | Where-Object { ($_.roleDefinitionId -split '/')[-1] -eq $RoleId }).Count) { return }
  az role assignment create --subscription $SubscriptionId --assignee-object-id $PrincipalId `
    --assignee-principal-type ServicePrincipal --role $RoleId --scope $Scope --output none
  if ($LASTEXITCODE -ne 0) { throw "Cannot grant workspace identity role '$RoleId' at '$Scope'. Source-scoped role assignment write permission is required." }
}

function New-FabricKeylessConnection {
  param([Parameter(Mandatory)] [hashtable] $Body)
  for ($attempt = 0; $attempt -lt 6; $attempt++) {
    try {
      return Invoke-RestMethod -Method Post -Uri "$fabricApi/connections" -Headers $script:fabricHeaders `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 12)
    } catch {
      $status = [int]$_.Exception.Response.StatusCode
      $authorizationFailure = $status -in @(400, 401, 403) -and
        $_.ErrorDetails.Message -match '(?i)credential|authorization|permission|access.denied'
      if (-not $authorizationFailure -or $attempt -eq 5) { throw }
      Write-Warning "Fabric connection authorization is not ready (attempt $($attempt + 1)/6). Waiting 20 seconds for identity/RBAC propagation."
      Start-Sleep -Seconds 20
    }
  }
}

function Ensure-FabricMonitorConnection {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $SourceResourceId,
    [Parameter(Mandatory)] [guid] $SourceCustomerId,
    [string] $ConnectionId = ''
  )
  $customerId = $SourceCustomerId.ToString()
  $matches = @(Get-FabricApiCollection -Path connections | Where-Object {
    $_.connectionDetails.type -eq 'AzureMonitorMirroredCatalog' -and
    ($_.connectionDetails.path -split ';')[0] -eq $customerId
  })
  if ($ConnectionId) {
    $matches = @($matches | Where-Object id -eq $ConnectionId)
    if ($matches.Count -ne 1) { throw 'The mirror connection ID must target the discovered Log Analytics customer GUID and be accessible to this user.' }
  }
  if ($matches.Count -gt 1) { throw 'Multiple mirror connections target this workspace; configure its explicit connection ID.' }
  if ($matches.Count) { return $matches[0] }

  $identity = Ensure-FabricWorkspaceIdentity -WorkspaceId $WorkspaceId
  $roleName = "Azure Monitor Lab Fabric Mirror $customerId"
  $roleScope = ($SourceResourceId -split '/providers/')[0]
  $roles = @(az role definition list --subscription $SubscriptionId --name $roleName --output json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the source-scoped mirroring role.' }
  $actions = @('Microsoft.Authorization/roleAssignments/write', 'Microsoft.OperationalInsights/workspaces/query/read', 'Microsoft.OperationalInsights/workspaces/read')
  if ($roles.Count -gt 1) { throw 'Ambiguous source-scoped mirroring role.' }
  if ($roles.Count) {
    $role = $roles[0]
    if (($role.assignableScopes -join ',') -ine $roleScope -or
        (($role.permissions.actions | Sort-Object) -join ',') -cne (($actions | Sort-Object) -join ',') -or
        @($role.permissions).Count -ne 1 -or $role.permissions.dataActions -or $role.permissions.notActions -or
        $role.permissions.notDataActions -or $role.roleType -ne 'CustomRole') {
      throw "Existing role '$roleName' does not match the expected source-scoped permissions; refusing reuse."
    }
  } else {
    $definition = @{
      Name = $roleName
      IsCustom = $true
      Description = 'Fabric Azure Monitor mirror connection: query/read and role-assignment write on this Log Analytics workspace only.'
      Actions = $actions; NotActions = @(); DataActions = @(); NotDataActions = @()
      AssignableScopes = @($roleScope)
    }
    $role = az role definition create --subscription $SubscriptionId `
      --role-definition ($definition | ConvertTo-Json -Depth 6 -Compress) --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $role.name) { throw 'Cannot create the source-scoped mirror role. Custom-role administration permission is required.' }
  }
  Write-Warning "Mirroring grants workspace identity query/read and roleAssignments/write at '$SourceResourceId'. Fabric access does not inherit Azure Monitor table/row restrictions."
  Grant-FabricSourceRole -PrincipalId $identity.servicePrincipalId -Scope $SourceResourceId -RoleId $role.name
  return New-FabricKeylessConnection -Body @{
    connectivityType = 'ShareableCloud'
    displayName = "amlab-mirror-$customerId"
    connectionDetails = @{
      type = 'AzureMonitorMirroredCatalog'
      creationMethod = 'AzureMonitorMirroredCatalog.Contents'
      parameters = @(
        @{ dataType = 'Text'; name = 'workspaceId'; value = $customerId }
        @{ dataType = 'Text'; name = 'catalogEndpoint'; value = 'https://api.loganalytics.io/iceberg' }
      )
    }
    privacyLevel = 'Organizational'
    credentialDetails = @{
      connectionEncryption = 'NotEncrypted'
      credentials = @{ credentialType = 'WorkspaceIdentity' }
      skipTestConnection = $false
    }
  }

}

function Remove-FabricMonitorAccess {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $SourceResourceId,
    [Parameter(Mandatory)] [guid] $SourceCustomerId
  )
  $customerId = $SourceCustomerId.ToString()
  $connections = @(Get-FabricApiCollection -Path connections | Where-Object {
    $_.displayName -eq "amlab-mirror-$customerId" -and
    $_.connectionDetails.type -eq 'AzureMonitorMirroredCatalog' -and
    ($_.connectionDetails.path -split ';')[0] -eq $customerId
  })
  foreach ($connection in $connections) {
    Invoke-RestMethod -Method Delete -Uri "$fabricApi/connections/$($connection.id)" -Headers $script:fabricHeaders | Out-Null
  }
  $roles = @(az role definition list --subscription $SubscriptionId `
    --name "Azure Monitor Lab Fabric Mirror $customerId" --output json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect generated mirroring roles during teardown.' }
  if (-not $roles.Count) { return }
  if ($roles.Count -ne 1 -or $roles[0].roleType -ne 'CustomRole' -or
      ($roles[0].assignableScopes -join ',') -ine ($SourceResourceId -split '/providers/')[0]) {
    throw 'Unexpected mirror role definition during teardown; refusing to delete it.'
  }
  $workspaceDetails = Invoke-RestMethod -Method Get -Uri "$fabricApi/workspaces/$WorkspaceId" -Headers $script:fabricHeaders
  if ($workspaceDetails.workspaceIdentity.servicePrincipalId) {
    az role assignment delete --subscription $SubscriptionId --assignee-object-id $workspaceDetails.workspaceIdentity.servicePrincipalId `
      --role $roles[0].name --scope $SourceResourceId
    if ($LASTEXITCODE -ne 0) { throw 'Cannot remove the source-LAW-scoped mirroring assignment.' }
  }
  $remaining = @(az role assignment list --subscription $SubscriptionId --role $roles[0].name --all --output json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Cannot verify whether a generated mirror role is still in use.' }
  if ($remaining.Count) {
    Write-Warning "Mirroring role '$($roles[0].roleName)' remains assigned elsewhere; its definition was preserved."
    return
  }
  az role definition delete --subscription $SubscriptionId --name $roles[0].name
  if ($LASTEXITCODE -ne 0) { throw 'Cannot remove the unused generated mirroring role definition.' }
}
