function Get-LabWebAppMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup,
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]{2,60}$')] [string] $WebAppName
  )

  $metadata = az resource show --resource-group $ResourceGroup --name $WebAppName `
    --resource-type Microsoft.Web/sites --api-version 2023-12-01 `
    --query '{name:name,state:properties.state,defaultHostName:properties.defaultHostName}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $metadata.name -or -not $metadata.state -or -not $metadata.defaultHostName) {
    throw 'Could not read the configured Web App metadata.'
  }
  return $metadata
}

function Get-LabWebAppHealthStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9.-]+\.azurewebsites\.net$')] [string] $HostName,
    [ValidateSet('/healthz')] [string] $Path = '/healthz'
  )

  $response = Invoke-WebRequest -Uri "https://$HostName$Path" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
  return [int]$response.StatusCode
}

function Wait-LabWebAppHealthStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9.-]+\.azurewebsites\.net$')] [string] $HostName,
    [Parameter(Mandatory)] [ValidateSet(200, 503)] [int] $ExpectedStatusCode,
    [ValidateRange(1, 60)] [int] $MaxAttempts = 30,
    [ValidateRange(1, 30)] [int] $DelaySeconds = 10
  )

  $lastStatusCode = $null
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $lastStatusCode = Get-LabWebAppHealthStatus -HostName $HostName
      $lastError = $null
      if ($lastStatusCode -eq $ExpectedStatusCode) { return }
    } catch {
      $lastError = $_.Exception.Message
    }
    if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
  }

  $details = if ($lastError) { "Last probe failed: $lastError" } else { "Last HTTP status: $lastStatusCode." }
  throw "Web App '$HostName' did not reach expected HTTP $ExpectedStatusCode after $MaxAttempts attempts. $details"
}
