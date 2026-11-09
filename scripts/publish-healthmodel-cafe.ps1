[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $WebAppName
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$appDir = Join-Path $PSScriptRoot '..\workloads\cafe'
$zip = Join-Path ([IO.Path]::GetTempPath()) "lab-cafe-$([guid]::NewGuid()).zip"
try {
  $files = @('server.js', 'package.json', 'package-lock.json') | ForEach-Object { Join-Path $appDir $_ }
  Compress-Archive -LiteralPath $files -DestinationPath $zip
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $output = az webapp deployment source config-zip --subscription $SubscriptionId -g $ResourceGroup `
      -n $WebAppName --src $zip --timeout 1200 -o none 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 2 -or $output -notmatch 'SCM container restart|management operation and a deployment operation in quick succession') {
      throw "Café publication failed. Azure details:`n$output"
    }
    Write-Warning "SCM restarted during Café publication. Waiting 60 seconds before retry $($attempt + 1)/2."
    Start-Sleep -Seconds 60
  }
} finally {
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
}
