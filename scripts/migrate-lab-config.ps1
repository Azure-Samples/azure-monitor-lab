<#
.SYNOPSIS
  Reorganize a flat or grouped lab config without changing its setting values.
.DESCRIPTION
  Optional: existing flat configs remain supported. Creates a gitignored .bak
  backup before replacing the config. Does not deploy or regenerate other files.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'lab.config.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$path = (Resolve-Path -LiteralPath $ConfigPath).Path
$configuration = Read-LabConfig -Path $path
$json = ConvertTo-GroupedLabConfig -Configuration $configuration | ConvertTo-Json -Depth 100
$backup = "$path.bak"
if ($PSCmdlet.ShouldProcess($path, 'Back up and reorganize lab configuration')) {
  if (Test-Path -LiteralPath $backup) {
    throw "Backup already exists at '$backup'. Move it to a safe location before migrating again."
  }
  Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
  Set-Content -LiteralPath $path -Value $json -Encoding utf8 -ErrorAction Stop
  Write-Host 'Configuration reorganized; setting values preserved. Keep the backup private.'
}
