[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workbookPath = Join-Path $source 'infra/modules/ai-finops-workbook.json'
$workbook = Get-Content -LiteralPath $workbookPath -Raw | ConvertFrom-Json
$ptuItem = @($workbook.items | Where-Object name -eq 'ptu-breakeven')

if ($ptuItem.Count -ne 1) {
  throw 'The AI FinOps workbook must contain exactly one PTU break-even query.'
}

$query = $ptuItem[0].content.query
if ($query -notmatch '\|\s*extend\s+price_per_token=.*?\|\s*extend\s+breakeven_tokens_day=') {
  throw 'The PTU query must calculate price_per_token before using it in a later extend operator.'
}

$parameters = @($workbook.items | Where-Object name -eq 'ptu-parameters')[0].content.parameters
$expectedDefaults = @{
  PTU_Count = '15'
  PTU_HourlyUSD = '1.0'
  InputPerMillionUSD = '0.25'
  OutputPerMillionUSD = '2.00'
}
foreach ($name in $expectedDefaults.Keys) {
  $parameter = @($parameters | Where-Object name -eq $name)
  if ($parameter.Count -ne 1 -or $parameter[0].value -ne $expectedDefaults[$name]) {
    throw "The $name parameter must have its illustrative out-of-box default."
  }
  if ($parameter[0].label -notmatch 'illustrative') {
    throw "The $name parameter must label its default as illustrative."
  }
}

$header = @($workbook.items | Where-Object name -eq 'hdr-ptu')[0].content.json
if ($header -notmatch 'illustrative assumptions' -or $header -notmatch 'not current Azure prices') {
  throw 'The PTU section must warn that its populated defaults are illustrative rather than current prices.'
}

Write-Output 'PASS: the AI FinOps PTU query and illustrative out-of-box defaults are valid and clearly labeled.'
