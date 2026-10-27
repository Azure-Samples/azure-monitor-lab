<#
.SYNOPSIS
  Run Microsoft Fabric setup from Azure Cloud Shell.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab',
  [bool] $SeedSampleData = $true,
  [bool] $EnableMirroring = $false,
  [string] $MirrorConnectionId = '',
  [string[]] $MirrorScope = @(),
  [string[]] $MirrorTables = @('AzureActivity', 'ContainerLogV2', 'AppServiceHTTPLogs', 'Perf'),
  [ValidateRange(1, 900)] [int] $VerificationTimeoutSeconds = 180,
  [bool] $EnableAutoSuspend = $false,
  [ValidateRange(0, 23)] [int] $AutoSuspendHourUtc = 20,
  [ValidateRange(0, 59)] [int] $AutoSuspendMinuteUtc = 0,
  [ValidateRange(5, 120)] [int] $MaxOperationMinutes = 30,
  [switch] $SkipEventstreamConnection
)

$ErrorActionPreference = 'Stop'
$setupParameters = @{
  SubscriptionId = $SubscriptionId
  ResourceGroup = $ResourceGroup
  NamePrefix = $NamePrefix
  WorkspaceName = $WorkspaceName
  MaxOperationMinutes = $MaxOperationMinutes
}
if ($SkipEventstreamConnection) {
  $setupParameters.SkipEventstreamConnection = $true
}
foreach ($parameter in @('SeedSampleData', 'EnableMirroring', 'MirrorConnectionId', 'MirrorScope',
    'MirrorTables', 'VerificationTimeoutSeconds', 'EnableAutoSuspend', 'AutoSuspendHourUtc', 'AutoSuspendMinuteUtc')) {
  if ($PSBoundParameters.ContainsKey($parameter)) { $setupParameters[$parameter] = $PSBoundParameters[$parameter] }
}

& (Join-Path $PSScriptRoot 'setup-fabric.ps1') @setupParameters