<#
.SYNOPSIS
  Submit an ARM resource deletion, returning false only when already absent.
.DESCRIPTION
  Called by cleanup helpers after their subscription and tenant guardrails.
  Other Azure errors remain fatal and include the resource ID and CLI details.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [ValidatePattern('^/[^?#]+$')] [string] $ResourceId,
  [Parameter(Mandatory)] [ValidatePattern('^[0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?$')] [string] $ApiVersion
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$resourcePath = ($ResourceId.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
$deleteOutput = az rest --method delete --subscription $SubscriptionId `
  --url "https://management.azure.com${resourcePath}?api-version=$ApiVersion" --only-show-errors 2>&1 | Out-String
$deleteExitCode = $LASTEXITCODE
if ($deleteExitCode -eq 0) { return $true }

$errorCode = ''
if ($deleteOutput -match '(?ms)^\s*ERROR:\s*[^\{\r\n]*(?<body>\{.*\})\)\s*$') {
  try { $errorCode = ($Matches.body | ConvertFrom-Json).error.code } catch { }
} elseif ($deleteOutput -match '(?m)^\s*ERROR:\s*\((?<code>[A-Za-z0-9]+)\)') {
  $errorCode = $Matches.code
} elseif ($deleteOutput -match '(?m)^\s*ERROR:\s*Not Found\s*$') {
  $errorCode = 'NotFound'
}
if ($errorCode -in @('ResourceNotFound', 'ParentResourceNotFound', 'ResourceGroupNotFound', 'NotFound')) { return $false }

throw "ARM resource deletion failed for '$ResourceId' (Azure CLI exit code $deleteExitCode). Details:`n$deleteOutput"