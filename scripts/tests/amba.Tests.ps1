[CmdletBinding()]
param([string] $RepoRoot = (Join-Path $PSScriptRoot '../..'))

$ErrorActionPreference = 'Stop'

foreach ($path in @('infra/main.json', 'infra/stages/20-alerting.json')) {
  $template = Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw | ConvertFrom-Json -AsHashtable
  $amba = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'amba' })
  if ($amba.Count -ne 1) { throw "$path must contain exactly one AMBA module." }

  $alert = @($amba[0].properties.template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/metricAlerts' -and $_.name -eq 'amba-webapp-4xx-rate' })
  if ($alert.Count -ne 1) { throw "$path AMBA module must contain exactly one Web App 4xx metric alert." }

  $criterion = @($alert[0].properties.criteria.allOf | Where-Object { $_.metricName -eq 'Http4xx' })
  if ($criterion.Count -ne 1 -or $criterion[0].metricNamespace -cne 'Microsoft.Web/sites' -or $criterion[0].skipMetricValidation -ne $true) {
    throw "$path Web App Http4xx alert must skip initial metric validation while metric definitions propagate."
  }

  Write-Host "PASS: $path AMBA Web App Http4xx alert tolerates initial metric-definition propagation."
}