[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $PublishDirectory,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $TenantId,
  [string] $WebAppName,
  [string] $CustomerWebAppName,
  [string] $CentralLawName,
  [switch] $BundleSreMcp,
  [string] $SreModelEndpoint,
  [string] $SreModelDeployment
)

$ErrorActionPreference = 'Stop'
foreach ($requiredFile in @('AmlabHello.dll', 'wwwroot/index.html')) {
  if (-not (Test-Path -LiteralPath (Join-Path $PublishDirectory $requiredFile))) {
    throw "Published web console is incomplete: $requiredFile is missing."
  }
}
$configPath = Join-Path $PublishDirectory 'lab-console.json'
& (Join-Path $PSScriptRoot 'write-webapp-console-config.ps1') `
  -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -TenantId $TenantId `
  -WebAppName $WebAppName -CustomerWebAppName $CustomerWebAppName `
  -CentralLawName $CentralLawName -OutputPath $configPath `
  -SreModelEndpoint $SreModelEndpoint -SreModelDeployment $SreModelDeployment
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
if ($config.LabConsole.Sre.AgentName -or $BundleSreMcp) {
  & (Join-Path $PSScriptRoot 'install-sre-mcp.ps1') -Destination (Join-Path $PublishDirectory 'mcp') -Platform linux-x64
  $config.LabConsole.Sre.McpExecutable = 'mcp/azmcp'
  Write-Host 'SRE MCP runtime included. The deployment bootstrap configures authenticated access next.'
}
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
Write-Host "Lab console package prepared in $PublishDirectory"